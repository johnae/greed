local test = require("@greed/test")
local greed = require("@greed")
local agent = require("@agent")

-- Runs the socket tool `name` with `args`.
local function run(name: string, args: { [string]: any }?, caller: agent.Caller?): any
	for _, tool in agent.tools() do
		if tool.name == name then
			return tool.run(args or {}, nil, caller)
		end
	end
	error(`no tool {name}`)
end

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
	assert(string.find(text, "Keys: w (normal)", 1, true), text)
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
	local offered = names(agent.offered(nil, mine))
	assert(offered.read and offered.tools and not offered.rename, "the core set")
	assert(offered.plan_read, "the plan group is on from the start")
	local said = run("tools", { group = "refactor" }, mine)
	assert(string.find(said, "rename", 1, true), said)
	assert(names(agent.offered(nil, mine)).rename, "switched on")
	assert(not names(agent.offered(nil, theirs)).rename, "not for another caller")
	assert(names(agent.offered("shell", nil)).rename, "a shell gets every tool")
	assert(not pcall(run, "tools", { group = "nope" }, mine), "an unknown group fails")
end)

test("agent-tool-groups gives groups from the start, or all of them", function(t)
	t:run("set", { "agent-tool-groups", "notes" })
	local offered = names(agent.offered(nil, agent.caller()))
	assert(offered.notes_read and not offered.plan_read and not offered.rename)
	t:run("set", { "agent-tool-groups", "all" })
	offered = names(agent.offered(nil, agent.caller()))
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
