local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")

-- A fourth style, from a plugin no other plugin knows about.
local MINE = [[
local greed = require("@greed")
local core = require("@core")
greed.command({ name = "mine-type", run = function() greed.mode.set("mine-insert") end })
greed.keymap.bind("mine", { i = "mine-type" })
greed.keymap.inherit("mine-insert", "helix-insert")
core.style.define({ name = "mine", doc = "Mine", mode = "mine", typing = { "mine-insert" }, leader = "ctrl-l" })
core.commands.tag("no-repeat", { "mine-type" })
return {}
]]

local function load_mine(t: test.TestContext)
	local dir = t:tempdir({
		["mine/plugin.toml"] = 'name = "mine"\nrequires = ["core"]\n',
		["mine/init.luau"] = MINE,
	})
	greed.plugin.load(dir .. "/mine")
	t:wait(0)
end

test("a style from a plugin types, with no plugin naming its modes", function(t)
	t:buffer("hello\n|")
	load_mine(t)
	core.style.set("mine")
	t:expect_mode("mine")
	t:keys("i h")
	t:expect_mode("mine-insert")
	t:expect("hello\nh|")
	assert(core.style.is_typing())
	assert(core.style.reveal() == "line")
	assert(core.commands.has("mine-type", "no-repeat"))
	greed.plugin.unload("mine")
	t:wait(0)
	assert(not core.style.is_typing("mine-insert"), "gone with its plugin")
	assert(not core.commands.has("mine-type", "no-repeat"), "its tags too")
	t:expect_mode("helix")
end)

test("a panel's keys work in every style and mode, a style from a plugin's too", function(t)
	t:buffer("|")
	greed.keymap.bind({ kind = "test-panel" }, { q = "goto-end", enter = "goto-start" })
	load_mine(t)
	greed.view():show(greed.create_buffer("test-panel", ""))
	for _, mode in { "helix", "helix-insert", "helix-select", "mine", "mine-insert" } do
		greed.mode.set(mode)
		assert(greed.keymap.resolve("q") == "goto-end", mode)
		assert(greed.keymap.resolve("enter") == "goto-start", `ahead of the mode's own in {mode}`)
	end
	greed.view():show(greed.create_buffer("scratch", ""))
	assert(greed.keymap.resolve("q") == nil, "only in that kind")
	greed.plugin.unload("mine")
	t:wait(0)
end)

test("a kind of buffer that takes typing does in the style's typing mode", function(t)
	t:buffer("|")
	core.style.typing_kind("test-prompt")
	load_mine(t)
	core.style.set("mine")
	local view = greed.view()
	view:show(greed.create_buffer("test-prompt", ""))
	assert(core.style.home_for(view) == "mine-insert", core.style.home_for(view))
	view:show(greed.create_buffer("scratch", ""))
	assert(core.style.home_for(view) == "mine")
	greed.plugin.unload("mine")
	t:wait(0)
end)

test("markup shows as written while typing, and inside it without modes", function(t)
	t:buffer("|")
	core.style.define({ name = "plain", doc = "No modes", mode = "plain", typing = { "plain" } })
	core.style.show_as("test-menu", "helix-insert")
	assert(core.style.reveal("helix") == "never")
	assert(core.style.reveal("helix-insert") == "line")
	assert(core.style.reveal("test-menu") == "line", "shown as insert")
	assert(core.style.reveal("plain") == "cursor")
	assert(core.style.reveal("picker-thing") == "never")
	assert(core.style.is_typing("plain") and core.style.is_typing("test-menu"))
	assert(not core.style.is_typing("helix"))
end)

test("each_typing hears of every typing mode once, now and later", function(t)
	t:buffer("|")
	local heard = {}
	core.style.each_typing(function(mode)
		table.insert(heard, mode)
	end)
	assert(table.find(heard, "helix-insert"), table.concat(heard, " "))
	local before = #heard
	core.style.define({
		name = "again",
		doc = "Again",
		mode = "again",
		typing = { "helix-insert", "again-insert" },
	})
	assert(#heard == before + 1 and heard[#heard] == "again-insert", table.concat(heard, " "))
end)

test("the leader opens with each style's own keys, and lists the same keys", function(t)
	t:buffer("a\n|b")
	greed.keymap.bind({ layer = "leader" }, { ["q q"] = "goto-start" })
	t:keys("space q q")
	t:expect("|a\nb")
	load_mine(t)
	core.style.set("mine")
	t:keys("ctrl-l")
	assert(greed.keymap.resolve("ctrl-l") == nil, "waiting for more")
	local next = {}
	for _, key in greed.keymap.next("ctrl-l") do
		table.insert(next, key.key)
	end
	assert(table.find(next, "q"), table.concat(next, " "))
	t:keys("esc")
	local found = false
	for _, binding in greed.keymap.active() do
		found = found or (binding.keys == "ctrl-l q q" and binding.command == "goto-start")
	end
	assert(found, "the command palette lists it with the style's keys")
	assert(greed.keymap.resolve("space q q") == nil, "space is Helix's way in")
	greed.plugin.unload("mine")
	t:wait(0)
end)
