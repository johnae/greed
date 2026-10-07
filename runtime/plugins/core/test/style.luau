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
core.style.define({ name = "mine", doc = "Mine", mode = "mine", typing = { "mine-insert" } })
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

test("keys bound for a kind of buffer in Helix's mode work in a style from a plugin", function(t)
	t:buffer("|")
	greed.keymap.bind({ mode = "helix", kind = "test-panel" }, { q = "goto-end" })
	load_mine(t)
	core.style.set("mine")
	greed.view():show(greed.create_buffer("test-panel", ""))
	assert(greed.keymap.resolve("q") == "goto-end")
	greed.view():show(greed.create_buffer("scratch", ""))
	assert(greed.keymap.resolve("q") == nil, "only in that kind")
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
