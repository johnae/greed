local test = require("@kern/test")
local kern = require("@kern")
local context = require("@context")

test("space i p pins the selection, which follows edits, or the file", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one\ntwo\nthree\n" })
	kern.project.open(dir)
	kern.open(dir .. "/a.txt")
	t:keys("j x space i p")
	local items = context.list()
	assert(#items == 1 and items[1].kind == "selection", "the line is pinned")
	t:keys("g g O n e w esc")
	local text, label = context.read(items[1])
	assert(text == "two\n", "it follows the text: " .. text)
	assert(label == "a.txt:3-3", label)
	t:keys("; space i p")
	assert(context.list()[2].kind == "file", "a cursor pins the whole file")
	assert(
		string.find(context.text(), "## a.txt\n\nnew\none\ntwo\nthree\n", 1, true),
		context.text()
	)
end)

test("space i i lists the items with sizes, and deleting a line drops one", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one\n", ["b.txt"] = "two\n" })
	kern.project.open(dir)
	kern.open(dir .. "/a.txt")
	t:keys("space i p")
	kern.open(dir .. "/b.txt")
	t:keys("space i p")
	t:keys("space i i")
	local listed = kern.view():buffer():text()
	assert(listed == "a.txt  (1 tokens)\nb.txt  (1 tokens)", listed)
	t:keys("x d")
	assert(#context.list() == 1, "the first item is gone")
	local _, label = context.read(context.list()[1])
	assert(label == "b.txt", label)
	t:keys("q")
end)

test("computed items are worked out when read", function(t)
	t:tempdir({})
	local runs = 0
	context.define("count", function()
		runs += 1
		return `run {runs}`
	end)
	context.add({ kind = "computed", name = "count" })
	local first = context.text()
	assert(string.find(first, "## count\n\nrun 1", 1, true), first)
	assert(string.find(context.text(), "run 2", 1, true), "read fresh each time")
	t:run("context-clear")
	assert(#context.list() == 0)
end)

test("agents read the context with context_get", function(t)
	local dir = t:tempdir({ ["a.txt"] = "pinned text\n" })
	kern.project.open(dir)
	kern.open(dir .. "/a.txt")
	t:keys("space i p")
	local agent = require("@agent")
	for _, tool in agent.tools() do
		if tool.name == "context_get" then
			local answer = tool.run({})
			assert(string.find(answer, "pinned text", 1, true), answer)
			return
		end
	end
	error("no context_get tool")
end)
