local test = require("@greed/test")
local greed = require("@greed")
local agent = require("@agent")

-- Runs the socket tool `name` with `args`.
local function run(name: string, args: { [string]: any }?, caller: agent.Caller?): any
	for _, tool in agent.tools() do
		if tool.name == name then
			return tool.run(args or {}, caller or agent.caller())
		end
	end
	error(`no tool {name}`)
end

test("focus tells the file you were in while a pane without one has focus", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one\ntwo\n" })
	greed.open(dir .. "/a.txt")
	greed.view():set_selection({ ranges = { { anchor = 4, head = 7 } }, primary = 1 })
	greed.panel(greed.create_buffer("notes", "x"), { side = "right" })
	local focus = run("focus")
	assert(focus.path == dir .. "/a.txt", tostring(focus.path))
	assert(focus.selections[1].text == "two", focus.selections[1].text)
	assert(focus.mode == "normal" and focus.style == "helix", `{focus.mode} {focus.style}`)
	t:keys("i")
	local typing = run("focus")
	assert(typing.mode == "insert", tostring(typing.mode))
	t:keys("esc")
end)

test("focus tells the file you were in after moving to a pane without one", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one\ntwo\n" })
	greed.open(dir .. "/a.txt")
	t:wait(0)
	greed.view():split("right", greed.create_buffer("notes", "x")):focus()
	t:wait(0)
	local focus = run("focus")
	assert(focus.path == dir .. "/a.txt", tostring(focus.path))
end)

test("read falls back to the disk for files that aren't open", function(t)
	local dir = t:tempdir({ ["closed.txt"] = "a\nb\nc" })
	t:buffer("|x")
	assert(run("read", { path = dir .. "/closed.txt" }) == "a\nb\nc")
	assert(run("read", { path = dir .. "/closed.txt", from_line = 2, to_line = 3 }) == "b\nc")
	assert(
		run("read", { path = dir .. "/closed.txt", from_line = 3, to_line = 1 }) == "",
		"an empty range"
	)
	assert(not pcall(run, "read", { path = dir .. "/missing.txt" }, nil), "a missing file fails")
end)

test("tools take relative paths from the project's root, wherever Greed started", function(t)
	local dir = t:tempdir({ [".git/HEAD"] = "", ["src/a.txt"] = "disk\n" })
	greed.run("project", { args = { dir } })
	assert(greed.fs.cwd() ~= dir)
	assert(run("read", { path = "src/a.txt" }) == "disk\n", "read")
	greed.load(dir .. "/src/a.txt"):edit(function(e)
		e:replace(0, 4, "open")
	end)
	assert(run("read", { path = "./src/a.txt" }) == "open\n", "read sees the open buffer")
	run("open", { path = "src/a.txt" })
	assert(greed.view():buffer():path() == dir .. "/src/a.txt", "open")
end)

test("buffers lists open files and which have changes", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a", ["b.txt"] = "b" })
	greed.open(dir .. "/a.txt")
	t:keys("i x esc")
	greed.open(dir .. "/b.txt")
	local modified = {}
	for _, entry in run("buffers") do
		modified[entry.path] = entry.modified
	end
	assert(modified[dir .. "/a.txt"] == true and modified[dir .. "/b.txt"] == false)
end)

test("open goes to a line, kept inside the file", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one\ntwo\nthree" })
	t:buffer("|x")
	assert(run("open", { path = dir .. "/a.txt", line = 2 }) == `opened {dir}/a.txt`)
	t:expect("one\n|two\nthree")
	run("open", { path = dir .. "/a.txt", line = 99 })
	t:expect("one\ntwo\n|three")
end)

test("project and diagnostics answer about the editor", function(t)
	local dir = t:tempdir({ [".git/HEAD"] = "", ["a.txt"] = "" })
	greed.run("project", { args = { dir } })
	t:buffer("|x")
	assert(run("project") == dir, tostring(run("project")))
	assert(#run("diagnostics", { path = dir .. "/not-open.txt" }) == 0)
end)

test("diagnostics are where the problems are now, after edits", function(t)
	local dir = t:tempdir({ ["a.rs"] = "let x = bad;\n" })
	greed.open(dir .. "/a.rs")
	local buffer = greed.view():buffer()
	-- Language servers' diagnostics are marks in this namespace.
	buffer:decorate("diagnostics", {
		{
			from = 8,
			to = 11,
			style = "diagnostic.error",
			data = { severity = 1, message = "bad word" },
		},
	})
	buffer:edit(function(e)
		e:insert(0, "// note\n")
	end)
	local d = greed.lsp.diagnostics(buffer)[1]
	assert(
		buffer:slice(d.from, d.to) == "bad" and d.message == "bad word",
		buffer:slice(d.from, d.to)
	)
	local found = run("diagnostics", { path = dir .. "/a.rs" })
	assert(#found == 1, tostring(#found))
	assert(found[1].line == 2 and found[1].column == 9, `{found[1].line}:{found[1].column}`)
	assert(found[1].severity == "error" and found[1].message == "bad word")
end)

test("eval returns what the code returns, and fails with its error", function(t)
	t:buffer("|x")
	assert(run("eval", { code = "return 6 * 7" }) == "42")
	local ok, err = pcall(run, "eval", { code = "error('broken')" }, nil)
	assert(not ok and string.find(tostring(err), "broken", 1, true), tostring(err))
end)

test("tool names are checked, and a tool with the same name replaces the old one", function(t)
	assert(not pcall(agent.tool, { name = "bad name", description = "", run = function() end }))
	agent.tool({
		name = "twice",
		description = "first",
		run = function()
			return 1
		end,
	})
	agent.tool({
		name = "twice",
		description = "second",
		run = function()
			return 2
		end,
	})
	assert(run("twice") == 2)
	local ide = {}
	for _, tool in agent.tools("ide") do
		table.insert(ide, tool.name)
	end
	assert(
		table.find(ide, "openDiff") and not table.find(ide, "twice"),
		"each client has its own tools"
	)
end)

test("outline and syntax_query read a file's syntax tree, open or not", function(t)
	require("@greed").syntax.set_query(
		"rust",
		"textobjects",
		"(function_item) @function.around (struct_item) @type.around"
	)
	local dir = t:tempdir({ ["a.rs"] = "struct S;\n\nfn main() {\n    run(1);\n}\n" })
	t:buffer("|x")
	local outline = run("outline", { path = dir .. "/a.rs" })
	assert(#outline == 2, `{#outline} entries`)
	assert(outline[1].name == "S" and outline[1].line == 1, outline[1].name)
	assert(outline[2].name == "main" and outline[2].line == 3 and outline[2].end_line == 5)

	local calls = run("syntax_query", {
		path = dir .. "/a.rs",
		query = "(call_expression function: (identifier) @name)",
	})
	assert(#calls == 1, `{#calls} matches`)
	local name = calls[1].name
	assert(name.text == "run" and name.line == 4 and name.column == 5, name.text)

	local ok, err = pcall(run, "syntax_query", { query = "(x) @y" }, nil)
	assert(not ok and string.find(tostring(err), "no syntax tree", 1, true), tostring(err))
end)

test("history_recent says who changed which files lately, with a diff", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one\ntwo\n", ["b.txt"] = "b\n" })
	greed.open(dir .. "/b.txt")
	greed.open(dir .. "/a.txt")
	t:keys("j A space 2 esc")
	assert(greed.view():buffer():text() == "one\ntwo 2\n", greed.view():buffer():text())
	local recent = run("history_recent")
	assert(#recent == 1, "only the changed file")
	local file = recent[1]
	assert(file.path == dir .. "/a.txt", file.path)
	assert(file.edits[1].author == "user" and file.edits[1].cause ~= nil, file.edits[1].author)
	assert(file.diff == "@@ line 2\n-two\n+two 2", file.diff)
	assert(#run("history_recent", { author = "agent" }) == 0, "nothing by agents")
	assert(#run("history_recent", { path = dir .. "/b.txt" }) == 0, "b is unchanged")
end)

test("eval's edits are one operation, and an eval that edits nothing leaves none", function(t)
	-- Files outside the project need approval in auto, which this isn't about.
	greed.option.set("agent-eval", "allow")
	local operations = require("@operations")
	local dir = t:tempdir({ ["a.txt"] = "a\n", ["b.txt"] = "b\n" })
	t:buffer("|x")
	local before = #operations.list()
	run("eval", { code = "return 1" })
	assert(#operations.list() == before, "nothing changed, so no operation")
	local code = `local greed = require("@greed")\n`
		.. `for _, name in \{ "a", "b" \} do\n`
		.. `  local b = greed.load("{dir}/" .. name .. ".txt")\n`
		.. `  b:edit(function(e) e:insert(0, "!") end)\n`
		.. `end`
	run("eval", { code = code })
	local op = operations.list()[1]
	assert(op.author == "agent" and #op.files == 2, op.name)
	assert(string.find(op.name, "^eval: local greed"), op.name)
	assert(operations.undo(op))
	assert(greed.load(dir .. "/a.txt"):text() == "a\n")
	greed.option.set("agent-eval", "auto")
end)

test("describe tells an agent what something is, or the names like it", function(t)
	t:buffer("|")
	local text = run("describe", { name = "next-word" })
	assert(string.find(text, "command next-word", 1, true), text)
	assert(string.find(text, "Keys: w (helix)", 1, true), text)
	local like = run("describe", { name = "option.s", kind = "api" })
	assert(string.find(like, "api greed.option.set", 1, true), like)
	assert(run("describe", { name = "zzz-nothing" }) == "nothing called zzz-nothing")
end)

local function names(tools: { agent.Tool }): { [string]: boolean }
	local set = {}
	for _, tool in tools do
		set[tool.name] = true
	end
	return set
end

test("grouped tools are offered once a group is switched on, to that caller only", function()
	local mine, theirs = agent.caller(), agent.caller()
	local offered = names(agent.offered(mine))
	assert(offered.read and offered.tools and not offered.rename, "the core set")
	assert(offered.plan_read, "the plan group is on from the start")
	local said = run("tools", { group = "refactor" }, mine)
	assert(string.find(said, "rename", 1, true), said)
	assert(names(agent.offered(mine)).rename, "switched on")
	assert(not names(agent.offered(theirs)).rename, "not for another caller")
	assert(names(agent.offered({ kind = "shell", groups = {} })).rename, "a shell gets every tool")
	assert(not pcall(run, "tools", { group = "nope" }, mine), "an unknown group fails")
end)

test("agent-tool-groups gives groups from the start, or all of them", function(t)
	t:run("set", { "agent-tool-groups", "notes" })
	local offered = names(agent.offered(agent.caller()))
	assert(offered.notes_read and not offered.plan_read and not offered.rename)
	t:run("set", { "agent-tool-groups", "all" })
	offered = names(agent.offered(agent.caller()))
	assert(offered.rename and offered.notes_read and offered.plan_read)
end)

test("the tools tool lists the groups, saying which are on", function()
	local caller = agent.caller()
	run("tools", { group = "map" }, caller)
	local listing = run("tools", {}, caller)
	assert(string.find(listing, "map (on): Where things are", 1, true), listing)
	assert(string.find(listing, "refactor: Renaming", 1, true), listing)
	assert(string.find(listing, "Tools: code_action, code_actions, rename", 1, true), listing)
end)

test("the tools tool names its groups, so an agent needn't guess them", function()
	local tool
	for _, known in agent.tools() do
		if known.name == "tools" then
			tool = known
		end
	end
	assert(tool, "there's a tools tool")
	assert(string.find(tool.description, "map (Where things are", 1, true), tool.description)
	local enum = tool.input and tool.input.properties.group.enum
	assert(
		enum and table.find(enum, "refactor") and table.find(enum, "notes"),
		"and allows only those"
	)
	local ok, err = pcall(run, "tools", { group = "repo" }, agent.caller())
	assert(not ok and string.find(tostring(err), "the groups are", 1, true), tostring(err))
end)

test("a tool's result reads as text: MCP results marked as such, other tables as data", function()
	assert(agent.as_text("plain") == "plain")
	assert(agent.as_text(agent.result("done")) == "done", "a result's text")
	local pieces =
		agent.result({ { type = "text", text = "a" }, { type = "text", text = "b" } }, true)
	assert(pieces.isError and agent.as_text(pieces) == "a\nb", agent.as_text(pieces))
	local data = { content = { { type = "text", text = "not a result" } } }
	assert(agent.as_text(data) == greed.json.encode(data), "data with content stays data")
end)

test("schema.object makes an object's schema, the second list naming the required", function()
	local schema = agent.schema.object({ path = { type = "string" } }, { "path" })
	assert(schema.type == "object" and schema.properties.path.type == "string")
	assert(schema.required[1] == "path")
	assert(agent.schema.object({}).required == nil, "nothing required by default")
end)

test("a tool failing a capability check tells the agent not to change capabilities", function()
	agent.tool({
		name = "needs_more",
		description = "Fails as a plugin without a capability would",
		input = agent.schema.object({}),
		run = function()
			error('tiny can\'t run programs: add "proc" to capabilities in its plugin.toml', 0)
		end,
	})
	local text = agent.as_text(agent.call("needs_more", {}, agent.caller()))
	assert(string.find(text, "don't change any plugin.toml's capabilities", 1, true), text)
	local plain = agent.error_text("no such file")
	assert(plain == "no such file", plain)
end)

test("widens says what a plugin.toml change lets the plugin do that it couldn't", function()
	local before = 'name = "acp"\ncapabilities = ["proc", "fs.read"]\n'
	local after =
		'name = "acp"\ncapabilities = [\n  "proc",\n  "fs.read",\n  "plugins",\n  "eval",\n]\n'
	local said = agent.widens("/x/acp/plugin.toml", before, after)
	assert(said == "widens what acp may do: + eval, + plugins", tostring(said))
	-- A new plugin.toml adds all it lists.
	local new = agent.widens("/x/tiny/plugin.toml", nil, "name = 'tiny'\ncapabilities = ['net']\n")
	assert(new == "widens what tiny may do: + net", tostring(new))
	-- Taking away, keeping, other files and plugins without capabilities: nothing.
	assert(agent.widens("/x/acp/plugin.toml", after, before) == nil)
	assert(agent.widens("/x/acp/plugin.toml", before, before .. "# note\n") == nil)
	assert(agent.widens("/x/notes.toml", before, after) == nil)
	assert(agent.widens("/x/tiny/plugin.toml", nil, 'name = "tiny"\n') == nil)
end)

test("trying a plugin doesn't ask: it's checked in a sandbox", function()
	local by_name: { [string]: any } = {}
	for _, tool in agent.tools() do
		by_name[tool.name] = tool
	end
	assert(by_name.plugin_try and not agent.asks(by_name.plugin_try), "plugin_try runs at once")
	assert(by_name.eval and not agent.asks(by_name.eval), "eval puts its review in front of you")
end)
