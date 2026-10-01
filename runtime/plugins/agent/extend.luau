-- Lets an agent extend Kern: it reads how plugins are written, tries a
-- plugin until its types and tests pass, then asks to install it. You see
-- the code and the check results before anything loads.
--
-- In the review:  a  install and load it    r  reject it

local kern = require("@kern")
local registry = require("./registry")

local M = {}

local user_dirs = kern.fs.dirs()
local cache = user_dirs.cache or (kern.fs.cwd() .. "/.kern-cache")
local config = user_dirs.config or (kern.fs.cwd() .. "/.kern-config")

--- Where tried plugins are staged and where installed ones go. Tests point
--- these somewhere temporary.
M.dirs = {
	staging = cache .. "/staging",
	plugins = config .. "/plugins",
}

type Staged = { files: { [string]: string }, report: string, passed: boolean }

-- The latest try of each plugin, by name.
local staged: { [string]: Staged } = {}
local tries = 0

local GUIDE = [[
# Writing a Kern plugin

A plugin is a folder with plugin.toml (`name = "my-plugin"`, optionally
`requires = ["core"]` to use `require("@core")`), an init.luau, and tests in
test/*.luau. It's Luau, not Lua 5.1: types (`local x: number`), `if a then b
else c` expressions, string interpolation with backticks, `+=`, and
`for k, v in t do` without pairs(). Everything comes from `require("@kern")`.

- Commands: `kern.command({ name = "words-like-this", doc = "...", run = function(ctx) ... end })`.
  `ctx.buffer` and `ctx.view` are where the command runs.
- Keys: `kern.keymap.bind("normal", { ["g x"] = "command-name" })`.
- Edits: `ctx.buffer:edit(function(e) e:replace(from, to, "text") end)`; positions are 0-based bytes.
- Agents: `require("@agent").tool({ name, description, input, run })` offers a tool over MCP.
- Waiting (kern.sleep, kern.fs.grep, kern.signal) works in commands and event handlers.

Tests:

    local test = require("@kern/test")
    test("what it does", function(t)
        t:buffer("hello |world")   -- | is the cursor, ^ a selection's anchor
        t:run("command-name")
        t:expect("hello world|")
    end)

Keep it small and say what each command does in its doc. The API's types
follow; they're exactly what luau-analyze checks against.
]]

local function read_types(): string
	local core = kern.plugin.dirs().core
	local types = if core then kern.fs.read(core .. "/../../types/kern/init.luau") else nil
	return types or "(Kern's type definitions weren't found)"
end

-- Plugin names are plain words with dashes; file paths stay inside the
-- plugin's folder.
local function check_files(name: string, files: { [string]: string })
	if not string.match(name, "^[a-z][a-z0-9%-]*$") then
		error("plugin names are lowercase words with dashes, e.g. jump-to-cargo", 0)
	end
	for path in files do
		if string.find(path, "..", 1, true) or string.sub(path, 1, 1) == "/" then
			error(`{path} has to stay inside the plugin's folder`, 0)
		end
		if
			not (
				string.match(path, "%.luau$")
				or path == "plugin.toml"
				or string.match(path, "%.md$")
			)
		then
			error(`{path}: plugins hold .luau files, plugin.toml and docs`, 0)
		end
	end
end

local function describe(report: kern.PluginCheck): (string, boolean)
	local lines, passed = {}, true
	if report.types.skipped then
		table.insert(lines, `types: not checked ({report.types.skipped})`)
	elseif report.types.ok then
		table.insert(lines, "types: ok")
	else
		passed = false
		table.insert(lines, "types: errors\n" .. (report.types.output or ""))
	end
	if report.tests.error then
		passed = false
		table.insert(lines, `tests: couldn't run: {report.tests.error}`)
	else
		local failed = report.tests.failed or {}
		passed = passed and #failed == 0
		local passed_count = report.tests.passed or 0
		if passed_count == 0 and #failed == 0 then
			table.insert(lines, "tests: none yet; add some in test/*.luau")
		else
			table.insert(lines, `tests: {passed_count} passed, {#failed} failed`)
		end
		for _, f in failed do
			table.insert(lines, `  {f.file}: {f.name}: {f.message}`)
		end
	end
	return table.concat(lines, "\n"), passed
end

local function write_files(dir: string, files: { [string]: string })
	for path, text in files do
		local ok, err = kern.fs.write(`{dir}/{path}`, text)
		if not ok then
			error(err, 0)
		end
	end
end

--- Writes `files` as a fresh try of plugin `name` and checks it. Returns
--- the report and whether everything passed.
function M.try(name: string, files: { [string]: string }): (string, boolean)
	check_files(name, files)
	files = table.clone(files)
	if files["plugin.toml"] == nil then
		files["plugin.toml"] = `name = "{name}"\nrequires = ["core"]\n`
	end
	tries += 1
	local dir = `{M.dirs.staging}/{name}-{tries}`
	write_files(dir, files)
	local report, passed = describe(kern.plugin.check(dir))
	staged[name] = { files = files, report = report, passed = passed }
	return report, passed
end

-- The review waiting for the user, if any.
local review: { done: kern.Signal, view: kern.View }? = nil

local function finish(accepted: boolean)
	local r = review
	if r == nil then
		return
	end
	review = nil
	r.view:close()
	r.done.send(accepted)
end

--- Shows the latest try of plugin `name` for review, and installs and
--- loads it if the user accepts. Returns what happened, in words.
function M.install(name: string): string
	local s = staged[name]
	if s == nil then
		error(`try {name} with plugin_try first`, 0)
	end
	if not s.passed then
		error(`{name} doesn't pass its checks yet:\n{s.report}`, 0)
	end
	if review then
		error("another plugin is waiting for review", 0)
	end
	local target = `{M.dirs.plugins}/{name}`
	local lines = {
		`An agent wrote the plugin "{name}" and wants it installed in {target}.`,
		"It can do anything Kern's plugin API allows: edit buffers, read and write files, offer tools to agents.",
		"",
		s.report,
		"",
		"a  install and load it    r  reject it",
	}
	local paths = {}
	for path in s.files do
		table.insert(paths, path)
	end
	table.sort(paths)
	for _, path in paths do
		table.insert(lines, "")
		table.insert(lines, `── {path} ──`)
		table.insert(lines, s.files[path])
	end
	local buffer =
		kern.create_buffer("plugin-review", table.concat(lines, "\n"), { readonly = true })
	local view = kern.panel(buffer, { side = "right", width = "60%", title = `Install {name}?` })
	local r = { done = kern.signal(), view = view }
	review = r
	kern.echo(`an agent wants to install the plugin {name} - a installs it, r rejects it`)
	if not r.done.wait() then
		return `the user rejected {name}`
	end
	write_files(target, s.files)
	kern.plugin.load(target)
	kern.echo(`installed {name}`)
	return `the user installed {name}; it's loaded and its commands are ready`
end

kern.command({
	name = "plugin-review-accept",
	doc = "Install and load the plugin under review",
	run = function()
		finish(true)
	end,
})

kern.command({
	name = "plugin-review-reject",
	doc = "Reject the plugin under review",
	run = function()
		finish(false)
	end,
})

kern.keymap.bind({ mode = "normal", kind = "plugin-review" }, {
	a = "plugin-review-accept",
	r = "plugin-review-reject",
	q = "plugin-review-reject",
	esc = "plugin-review-reject",
})

local function object(properties: { [string]: any }, required: { string }?): { [string]: any }
	return { type = "object", properties = properties, required = required }
end

registry.tool({
	name = "plugin_guide",
	description = "How to write a Kern plugin, with the full typed API. Read this before plugin_try",
	run = function()
		local plugins = {}
		for name in kern.plugin.dirs() do
			table.insert(plugins, name)
		end
		table.sort(plugins)
		return `{GUIDE}\nLoaded plugins: {table.concat(plugins, ", ")}\n\n{read_types()}`
	end,
})

registry.tool({
	name = "plugin_try",
	description = "Write a plugin's files and check them: strict types against Kern's API, "
		.. "then its tests. Returns what failed; fix and try again until it passes",
	input = object({
		name = { type = "string", description = "Lowercase words with dashes" },
		files = {
			type = "object",
			description = 'Paths in the plugin to their text, e.g. { "init.luau": "...", "test/basic.luau": "..." }',
			additionalProperties = { type = "string" },
		},
	}, { "name", "files" }),
	run = function(args)
		local report = M.try(args.name, args.files)
		return report
	end,
})

registry.tool({
	name = "plugin_install",
	description = "Ask the user to install the plugin last tried with plugin_try. "
		.. "They see its code and checks; waits for their answer",
	input = object({ name = { type = "string" } }, { "name" }),
	run = function(args)
		return M.install(args.name)
	end,
})

return M
