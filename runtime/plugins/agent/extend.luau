-- Lets an agent extend Greed: it reads how plugins are written, tries a
-- plugin until its types and tests pass, then asks to install it. You see
-- the code and the check results before anything loads.
--
-- In the review:  a  install, approve and load it    r  reject it

local greed = require("@greed")
local registry = require("./registry")
local approvals = require("@approvals")
local pages = require("./pages")

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

type Staged = {
	files: { [string]: string },
	dir: string,
	report: string,
	passed: boolean,
	--- The report as the install review shows it.
	shown: string,
}

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
- Keys: `greed.keymap.bind({ layer = "leader" }, { x = "command-name" })` (`space x` in Helix and Vim,
  `ctrl-space x` in edit mode), or `{ role = "command" }` for normal mode in every style.
- Edits: `ctx.buffer:edit(function(e) e:replace(from, to, "text") end)`; positions are 0-based bytes.
- Showing text to read: `require("@core").floats.show_text("Title", text, { anchor = "cursor",
  width = 60, height = 8 })` opens a float that esc or q closes (`requires = ["core"]`);
  `greed.echo(text)` says one line on the status line.
- Status line: `require("@statusline").add("right", "my-piece", function(ctx) return text or nil
  end, "language")` (`requires = ["statusline"]`). It runs on every redraw, so keep it cheap:
  work over the whole buffer is remembered by `ctx.buffer:version()`, which changes with each
  edit. `add_async` is for pieces that wait on a program.
- Events: `greed.on("buffer.saved", function(event) ... end)`; also "buffer.changed" (every
  edit, so keep it cheap and wait for a quiet moment before heavy work), "buffer.opened",
  "mode.changed", "lsp.diagnostics", "option.changed", "editor.started" and more.
- Options: `greed.option.define({ name = "my-option", default = true, doc = "..." })`, read with
  `greed.option.get`.
- Agents: `require("@agent").tool({ name, description, input, group, run })` offers a tool over
  MCP; `input = agent.schema.object({ path = { type = "string" } }, { "path" })` describes its
  arguments, and `run(args, caller)` returns text or data. A plugin with several puts them in
  a group (`require("@agent").group(name, line)`).
- More files: init.luau requires the plugin's other files with `require("@self/blame")`
  (init.luau stands for the folder); those files require each other with `require("./git")`.
  Whatever init.luau returns is the plugin's module: other plugins and the plugin's own tests
  get it with `require("@my-plugin")`, so return what tests need to reach.
- Waiting (greed.sleep, greed.fs.grep, greed.signal) works in commands and event handlers.
- Searching: Greed's own functions (buffer:find, buffer:find_all, greed.fs.grep) take Rust
  regexes (`\bTODO\b`, `a|b`); Luau's string.find and string.match take Lua patterns.
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

`t:keys("i")` presses keys by name ("g g", "esc", "ctrl-s"); `t:type("some text")` types
text. `buffer:decorations("my-plugin")` gives back the marks a plugin drew, to check them.
`t:buffer` makes an untitled buffer, which fires no "buffer.opened" (only files do, as in the
editor); to test a plugin reacting to opened files, write one with `t:tempdir({ ["a.txt"] =
"..." })` and `greed.open` it. A plugin decorating every buffer goes through
`greed.buffers()` as it loads, then follows "buffer.opened" and "buffer.changed".

Before writing one, check whether Greed does it already (describe a likely command name, or
grep Greed's plugins): then say so, and offer to change or extend what's there.

Keep it small and say what each command does in its doc. The API's types
follow; they're exactly what luau-analyze checks against.
]]

-- Greed's types without their doc comments: the signatures are what a
-- plugin needs at hand, and leaving the comments out takes about two
-- thirds off what every later turn carries. describe gives any one's doc.
local function read_types(): string
	local core = greed.plugin.dirs().core
	local path = if core then core .. "/../../types/greed/init.luau" else nil
	local types = if path then greed.fs.read(path) else nil
	if path == nil or types == nil then
		return "(Greed's type definitions weren't found)"
	end
	local kept = {}
	for _, line in string.split(types, "\n") do
		if not string.match(line, "^%s*%-%-%-") then
			table.insert(kept, line)
		end
	end
	return `Greed's API, without its doc comments: describe a function or type for its doc, `
		.. `or read {path} for all of them.\n\n{table.concat(kept, "\n")}`
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

-- The capabilities the plugin in `dir` declares.
local function declared(dir: string): { string }
	local names = {}
	for _, capability in greed.plugin.describe(dir).capabilities do
		table.insert(names, capability.name)
	end
	return names
end

-- What a test failure says when it needed something not approved yet.
local NEEDS_APPROVAL = "needs approval:"

--- `report` in words for an agent, and whether the plugin may go to the
--- user to install. Tests that fail only for want of approval of what the
--- plugin `declares` don't stop it: before it's installed nothing is
--- approved, and installing approves what it asks for (and checks it
--- again). Needing something it doesn't declare is a failure like any.
--- `for_user` words it for the install review rather than the agent.
function M.describe(
	report: greed.PluginCheck,
	declares: { string }?,
	for_user: boolean?
): (string, boolean)
	local declared: { string } = declares or {}
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
		local waiting = 0
		for _, f in failed do
			local needs: string? = nil
			if string.sub(f.message, 1, #NEEDS_APPROVAL) == NEEDS_APPROVAL then
				needs = string.match(f.message, 'you haven\'t approved "([^"]+)"')
			end
			if needs and table.find(declared, needs) then
				waiting += 1
			end
		end
		passed = passed and #failed == waiting
		local passed_count = report.tests.passed or 0
		if passed_count == 0 and #failed == 0 then
			table.insert(lines, "tests: none yet; add some in test/*.luau")
		else
			table.insert(lines, `tests: {passed_count} passed, {#failed} failed`)
		end
		for _, f in failed do
			table.insert(lines, `  {f.file}: {f.name}: {f.message}`)
		end
		if waiting > 0 then
			local next_step = if for_user
				then "they run again once you install it"
				else "plugin_install may go ahead"
			table.insert(
				lines,
				`  {waiting} of them only need what the plugin asks for, which installing it approves; `
					.. next_step
			)
		end
	end
	for _, warning in report.warnings do
		table.insert(lines, `warning: {warning}`)
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
	-- A folder of its own: one left from an earlier session would mix its
	-- files in with these.
	local dir
	repeat
		tries += 1
		dir = `{M.dirs.staging}/{name}-{tries}`
	until greed.fs.stat(dir) == nil
	write_files(dir, files)
	local check, declares = greed.plugin.check(dir), declared(dir)
	local report, passed = M.describe(check, declares)
	local shown = M.describe(check, declares, true)
	staged[name] = { files = files, dir = dir, report = report, passed = passed, shown = shown }
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
	r.done:send(accepted)
end

greed.on("view.closed", function(event)
	if review and review.view:id() == event.view then
		finish(false)
	end
end)

-- The review of `s`, the latest try of plugin `name`, and installing it.
local function review_and_install(name: string, s: Staged): string
	local target = `{M.dirs.plugins}/{name}`
	local lines = {
		`An agent wrote the plugin "{name}" and wants it installed in {target}.`,
		"It can edit buffers and add commands, keys and agent tools; beyond the editor:",
	}
	for _, line in approvals.lines(greed.plugin.describe(s.dir)) do
		table.insert(lines, line)
	end
	for _, line in { "", s.shown, "", "a  install, approve and load it    r  reject it" } do
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
	-- A float over everything, so it reads at full width whatever panels are open.
	local view = greed.float(buffer, { title = `Install {name}?`, width = "80%", height = "85%" })
	local r = { done = greed.signal(), view = view }
	review = r
	greed.echo(`an agent wants to install the plugin {name} - a installs it, r rejects it`)
	if not r.done:wait() then
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
	local said = `the user installed {name} in {target}; it's loaded and its commands are ready`
	-- Tests that waited for approval run now, with what was approved.
	if string.find(s.report, NEEDS_APPROVAL, 1, true) then
		local report = M.describe(greed.plugin.check(target), declared(target))
		said ..= `\nchecked again with what it was approved for:\n{report}`
	end
	return said
end

--- Shows the latest try of plugin `name` for review, after any other page
--- asking you, and installs and loads it if you accept. Returns what
--- happened, in words.
function M.install(name: string): string
	local s = staged[name]
	if s == nil then
		error(`try {name} with plugin_try first`, 0)
	end
	if not s.passed then
		error(`{name} doesn't pass its checks yet:\n{s.report}`, 0)
	end
	return pages.one_at_a_time(function()
		return review_and_install(name, s)
	end)
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

greed.keymap.bind({ kind = "plugin-review" }, {
	a = "plugin-review-accept",
	r = "plugin-review-reject",
	q = "plugin-review-reject",
	esc = "plugin-review-reject",
})

local object = registry.schema.object

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
		local core = greed.plugin.dirs().core
		local runtime = core and string.match(core, "^(.*)/[^/]+/[^/]+$")
		local examples = if runtime
			then `Greed's own plugins, in {runtime}/plugins, are working examples of all of this: `
				.. `grep with path "{runtime}" searches them and these types, and read opens them.\n`
			else ""
		return `{GUIDE}\n{examples}Loaded plugins: {table.concat(plugins, ", ")}\n\n{read_types()}`
	end,
})

registry.tool({
	name = "plugin_try",
	kind = "execute",
	-- It writes only to the staging folder, and checks the plugin in an
	-- editor of its own with nothing approved for it.
	sandboxed = true,
	group = "plugins",
	description = "Write a plugin's files and check them: strict types against Greed's API, "
		.. "then its tests. Returns what failed; fix and try again until it passes. This is how "
		.. "to add anything new to Greed for the user: the plugin is kept apart from the project "
		.. "and installed in their config with plugin_install, so don't write plugins into the "
		.. "project's files unless they ask you to change the project",
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
