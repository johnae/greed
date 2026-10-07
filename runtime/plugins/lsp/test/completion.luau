local test = require("@greed/test")
local greed = require("@greed")

-- What a command line or prompt does: a float typed into, closed by enter
-- before the typing pause runs out.
test("a float typed into and closed before the pause doesn't break completion", function(t)
	t:buffer("|x")
	local dir = t:tempdir({ ["a.txt"] = "" })
	local list = greed.create_buffer("scratch", "")
	list:save(dir .. "/a.txt")
	local float = greed.float(list, { width = 20, height = 1 })
	t:keys("i a b")
	float:close()
	t:wait(greed.option.get("completion-delay") :: number + 100)
	for _, message in t:messages() do
		assert(not string.find(message, "closed", 1, true), message)
	end
end)

test("a completion menu whose view closes some other way goes back to typing", function(t)
	t:buffer("apple apricot\n|")
	t:keys("i a")
	t:run("completion-words")
	t:expect_mode("completion-helix-insert")
	local menu = t:floats()
	assert(#menu == 1, `{#menu} floats`)
	for _, view in greed.floats() do
		if view:buffer():kind() == "completion" then
			view:close()
		end
	end
	t:wait(0)
	t:expect_mode("helix-insert")
	t:keys("p")
	t:expect("apple apricot\nap|")
end)

test("a style no plugin names gets completion in its typing mode", function(t)
	local core = require("@core")
	t:buffer("apple\n|")
	greed.keymap.inherit("mine-insert", "helix-insert")
	core.style.define({ name = "mine", doc = "Mine", mode = "mine", typing = { "mine-insert" } })
	greed.mode.set("mine-insert")
	t:keys("a")
	t:run("completion-words")
	t:expect_mode("completion-mine-insert")
	assert(core.style.is_typing(), "the menu's mode types too")
	assert(core.style.label("completion-mine-insert") == "mine-insert")
	-- Typing goes on in the menu's mode, and enter takes the match.
	t:keys("p enter")
	t:expect("apple\napple|")
	t:expect_mode("mine-insert")
end)
