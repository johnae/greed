local test = require("@greed/test")
local greed = require("@greed")

local function text(): string
	return greed.view():buffer():text()
end

local function current(): number
	return greed.view():buffer():undo_tree().current
end

test("the undo tree keeps a branch that undo and a new edit leave behind", function(t)
	t:buffer("|")
	t:keys("i a esc i b esc")
	assert(text() == "ab", text())
	t:keys("u i c esc")
	assert(text() == "ac", text())
	local tree = greed.view():buffer():undo_tree()
	assert(#tree.nodes == 4, `the root and three steps: {#tree.nodes}`)
	assert(#tree.nodes[2].children == 2, "the first step has two branches")
	assert(tree.nodes[1].time == nil and tree.nodes[2].time ~= nil, "only steps have times")
	-- Over to the other branch, which redo then follows.
	assert(greed.view():undo_to(2))
	assert(text() == "ab", text())
	t:keys("u U")
	assert(text() == "ab", text())
	assert(not greed.view():undo_to(2), "already there")
	assert(not greed.view():undo_to(99), "no such node")
end)

test("alt-u and alt-U go through every state in the order it was made", function(t)
	t:buffer("|")
	t:keys("i a esc i b esc u i c esc")
	assert(current() == 3)
	t:keys("alt-u")
	assert(current() == 2)
	assert(text() == "ab", text())
	t:keys("alt-u alt-u")
	assert(current() == 0)
	t:keys("3 alt-U")
	assert(current() == 3)
	assert(text() == "ac", text())
	t:keys("alt-U")
	local messages = t:messages()
	assert(messages[#messages] == "already at the latest change", messages[#messages])
end)
