-- Lets an agent extend Greed: it reads how plugins are written, tries a
-- plugin until its types and tests pass, then asks to install it. You see
-- the code and the check results before anything loads.
--
-- In the review:  a  install, approve and load it    r  reject it

local greed = require("@greed")
local registry = require("./registry")
local approvals = require("@approvals")

local M = {}

local user_dirs = greed.fs.dirs()
local cache = user_dirs.cache or (greed.fs.cwd() .. "/.greed-cache")
local config = user_dirs.config or (greed.fs.cwd() .. "/.greed-config")
local data = user_dirs.data or (greed.fs.cwd() .. "/.greed-data")

--- Where tried plugins are staged and where installed ones go: your config,
--- or the data folder when the config can't be written (Nix). Tests point
--- these somewhere temporary.
M.dirs = {
	staging = cache .. "/staging",
	plugins = config .. "/plugins",
	fallback = data .. "/plugins",
}

type Staged = { files: { [string]: string }, dir: string, report: string, passed: boolean }

-- The latest try of each plugin, by name.
local staged: { [string]: Staged } = {}
local tries = 0

local GUIDE = [[
# Writing a Greed plugin

A plugin is a folder with plugin.toml (`name = "my-plugin"`, optionally
`requires = ["core"]` to use `require("@core")`, and `capabilities` for
what it uses beyond the editor), an init.luau, and tests in
test/*.luau. It's Luau, not Lua 5.1: types (`local x: number`), `if a then b
else c` expressions, string interpolation with backticks, `+=`, and
`for k, v in t do` without pairs(). Everything comes from `require("@greed")`.

- Commands: `greed.command({ name = "words-like-this", doc = "...", run = function(ctx) ... end })`.
  `ctx.buffer` and `ctx.view` are where the command runs.
- Keys: `greed.keymap.bind("normal", { ["g x"] = "command-name" })`.
- Edits: `ctx.buffer:edit(function(e) e:replace(from, to, "text") end)`; positions are 0-based bytes.
- Events: `greed.on("buffer.saved", function(event) ... end)`; also "buffer.changed" (every
  edit, so keep it cheap and wait for a quiet moment before heavy work), "buffer.opened",
  "mode.changed", "lsp.diagnostics", "option.changed", "editor.started" and more.
- Options: `greed.option.define({ name = "my-option", default = true, doc = "..." })`, read with
  `greed.option.get`.
- Agents: `require("@agent").tool({ name, description, input, group, run })` offers a tool over
  MCP; a plugin with several puts them in a group (`require("@agent").group(name, line)`).
- Waiting (greed.sleep, greed.fs.grep, greed.signal) works in commands and event handlers.
- Capabilities, in plugin.toml as `capabilities = ["fs.read"]`: "proc" (greed.process.run,
  greed.terminal.spawn, greed.lsp.server), "fs.read" (greed.fs reads, greed.load, greed.open,
  greed.files), "fs.write" (greed.fs.write, mkdir, remove, rename, copy, buffer:save(path)),
  "clipboard" (reading it), "net" or "net:HOST" (greed.http), "secrets:NAME" (greed.secrets.get),
  "eval", "plugins". Ask only for what the plugin needs; the user sees the list.
  Editing buffers, commands, keys and the rest of the editor need none.

Tests:

    local test = require("@greed/test")
    test("what it does", function(t)
        t:buffer("hello |world")   -- | is the cursor, ^ a selection's anchor
        t:run("command-name")
        t:expect("hello world|")
    end)

Keep it small and say what each command does in its doc. The API's types
follow; they're exactly what luau-analyze checks against.
]]

local function read_types(): string
	local core = greed.plugin.dirs().core
	local types = if core then greed.fs.read(core .. "/../../types/greed/init.luau") else nil
	return types or "(Greed's type definitions weren't found)"
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

local function describe(report: greed.PluginCheck): (string, boolean)
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
		local failed: { { file: string, name: string, message: string } } = report.tests.failed
			or {}
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
		local ok, err = greed.fs.write(`{dir}/{path}`, text)
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
	local report, passed = describe(greed.plugin.check(dir))
	staged[name] = { files = files, dir = dir, report = report, passed = passed }
	return report, passed
end

-- The review waiting for the user, if any.
local review: { done: greed.Signal, view: greed.View }? = nil

local function finish(accepted: boolean)
	local r = review
	if r == nil then
		return
	end
	review = nil
	r.view:close()
	r.done.send(accepted)
end

greed.on("view.closed", function(event)
	if review and review.view:id() == event.view then
		finish(false)
	end
end)

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
		"It can edit buffers and add commands, keys and agent tools; beyond the editor:",
	}
	for _, line in approvals.lines(greed.plugin.describe(s.dir)) do
		table.insert(lines, line)
	end
	for _, line in { "", s.report, "", "a  install, approve and load it    r  reject it" } do
		table.insert(lines, line)
	end
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
		greed.create_buffer("plugin-review", table.concat(lines, "\n"), { readonly = true })
	local view = greed.panel(buffer, { side = "right", width = "60%", title = `Install {name}?` })
	local r = { done = greed.signal(), view = view }
	review = r
	greed.echo(`an agent wants to install the plugin {name} - a installs it, r rejects it`)
	if not r.done.wait() then
		return `the user rejected {name}`
	end
	-- Your config first; when it can't be written, as when Nix manages it,
	-- the data folder, so a declared config is never written to.
	if not pcall(write_files, target, s.files) then
		target = `{M.dirs.fallback}/{name}`
		write_files(target, s.files)
	end
	-- Accepting the review approves what it asked for.
	greed.plugin.approve(target)
	local where = target
	-- On the far end of greed ssh, it's on this machine, not yours.
	if greed.fs.dirs().brought then
		local machine = greed.hostname() or "this machine"
		where = `{target} on {machine}; on your own machine, greed bring HOST {name} copies it home`
	end
	greed.echo(`installed {name} in {where}`)
	return `the user installed {name} in {target}; it's loaded and its commands are ready`
end

greed.command({
	name = "plugin-review-accept",
	doc = "Install, approve and load the plugin under review",
	run = function()
		finish(true)
	end,
})

greed.command({
	name = "plugin-review-reject",
	doc = "Reject the plugin under review",
	run = function()
		finish(false)
	end,
})

greed.keymap.bind({ mode = "normal", kind = "plugin-review" }, {
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
	group = "plugins",
	description = "How to write a Greed plugin, with the full typed API. Read this before plugin_try",
	run = function()
		local plugins = {}
		for name in greed.plugin.dirs() do
			table.insert(plugins, name)
		end
		table.sort(plugins)
		return `{GUIDE}\nLoaded plugins: {table.concat(plugins, ", ")}\n\n{read_types()}`
	end,
})

registry.tool({
	name = "plugin_try",
	kind = "execute",
	group = "plugins",
	description = "Write a plugin's files and check them: strict types against Greed's API, "
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
	kind = "execute",
	reviews = true,
	group = "plugins",
	description = "Ask the user to install the plugin last tried with plugin_try. "
		.. "They see its code and checks; waits for their answer",
	input = object({ name = { type = "string" } }, { "name" }),
	run = function(args)
		return M.install(args.name)
	end,
})

return M
