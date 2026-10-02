local test = require("@kern/test")
local kern = require("@kern")
local agent = require("@agent")

-- Runs the socket tool `name` with `args`.
local function run(name: string, args: { [string]: any }?): any
	for _, tool in agent.tools() do
		if tool.name == name then
			return tool.run(args or {})
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
	assert(not pcall(run, "read", { path = dir .. "/missing.txt" }), "a missing file fails")
end)

test("buffers lists open files and which have changes", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a", ["b.txt"] = "b" })
	kern.open(dir .. "/a.txt")
	t:keys("i x esc")
	kern.open(dir .. "/b.txt")
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
	kern.run("project", { args = { dir } })
	t:buffer("|x")
	assert(run("project") == dir, tostring(run("project")))
	assert(#run("diagnostics", { path = dir .. "/not-open.txt" }) == 0)
end)

test("eval returns what the code returns, and fails with its error", function(t)
	t:buffer("|x")
	assert(run("eval", { code = "return 6 * 7" }) == "42")
	local ok, err = pcall(run, "eval", { code = "error('broken')" })
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
	require("@kern").syntax.set_query(
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

	local ok, err = pcall(run, "syntax_query", { query = "(x) @y" })
	assert(not ok and string.find(tostring(err), "no syntax tree", 1, true), tostring(err))
end)

test("history_recent says who changed which files lately, with a diff", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one\ntwo\n", ["b.txt"] = "b\n" })
	kern.open(dir .. "/b.txt")
	kern.open(dir .. "/a.txt")
	t:keys("j A space 2 esc")
	assert(kern.view():buffer():text() == "one\ntwo 2\n", kern.view():buffer():text())
	local recent = run("history_recent")
	assert(#recent == 1, "only the changed file")
	local file = recent[1]
	assert(file.path == dir .. "/a.txt", file.path)
	assert(file.edits[1].author == "user" and file.edits[1].cause ~= nil, file.edits[1].author)
	assert(file.diff == "@@ line 2\n-two\n+two 2", file.diff)
	assert(#run("history_recent", { author = "agent" }) == 0, "nothing by agents")
	assert(#run("history_recent", { path = dir .. "/b.txt" }) == 0, "b is unchanged")
end)
