local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")

-- A fourth style, from a plugin no other plugin knows about: a command
-- mode with one key of its own, a typing mode, and a leader of its own.
local MINE = [[
local greed = require("@greed")
local core = require("@core")
greed.command({ name = "mine-type", run = function() greed.mode.set("mine-insert") end })
greed.keymap.bind("mine", { i = "mine-type" })
greed.keymap.fallback("mine-insert", "insert-char")
core.style.define({
	name = "mine",
	doc = "Mine, a style no plugin knows",
	mode = "mine",
	roles = { command = "mine", typing = "mine-insert" },
	labels = { mine = "normal", ["mine-insert"] = "insert" },
	leader = "ctrl-l",
})
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

test("keys bound for a role work in each style's mode for it, by style in one", function(t)
	t:buffer("a\nb\n|c")
	greed.keymap.bind({ role = "command" }, { ["g z"] = "goto-start" })
	greed.keymap.bind({ role = "typing" }, { ["ctrl-z"] = "goto-start" })
	greed.keymap.bind({ style = "mine", role = "command" }, { i = "goto-end" })
	load_mine(t)
	for _, mode in { "helix", "helix-select", "mine" } do
		greed.mode.set(mode)
		assert(greed.keymap.resolve("g z") == "goto-start", mode)
	end
	for _, mode in { "helix-insert", "mine-insert" } do
		greed.mode.set(mode)
		assert(greed.keymap.resolve("ctrl-z") == "goto-start", mode)
		assert(greed.keymap.resolve("g z") == nil, `not the command role's in {mode}`)
	end
	greed.mode.set("mine")
	assert(
		greed.keymap.resolve("i") == "goto-end",
		"a style's own role keys come ahead of its mode's"
	)
	greed.mode.set("helix")
	assert(greed.keymap.resolve("i") == "insert-mode", "and only in that style")
	assert(
		core.style.role("mine-insert") == "typing"
			and core.style.role("helix-select") == "selecting"
	)
	greed.plugin.unload("mine")
	t:wait(0)
end)

test("a new style gets everything without plugins naming it", function(t)
	t:buffer("apple\n|")
	load_mine(t)
	core.style.set("mine")
	t:expect_mode("mine")

	-- Typing: completion in its typing mode, and the keys every typing
	-- mode has, esc back to its own.
	t:keys("i a")
	t:run("completion-words")
	t:expect_mode("completion-mine-insert")
	t:keys("p enter")
	t:expect("apple\napple|")
	t:expect_mode("mine-insert")
	assert(greed.keymap.resolve("ctrl-space") == "completion-ask", "asking for completion")
	local left, right = t:status()
	assert(left and string.find(left, "INSERT", 1, true), left)
	assert(right and string.find(right, "mine", 1, true), right)
	t:keys("enter x backspace esc")
	t:expect("apple\napple\n|")
	t:expect_mode("mine")
	left = t:status()
	assert(left and string.find(left, "NORMAL", 1, true), left)

	-- Keys plugins bind for the command role, and the leader with its own key.
	assert(greed.keymap.resolve(":") == "command-line")
	assert(greed.keymap.resolve("] d") == "next-diagnostic")
	local leader_f = greed.keymap.resolve("ctrl-l f")
	assert(leader_f == "pick-file", tostring(leader_f))
	assert(greed.keymap.resolve("space f") == nil, "space is another style's way in")

	-- A picker takes typing in its typing mode, and keeps its keys there.
	local chosen = nil
	require("@picker").pick("Test", { { label = "apple" }, { label = "pear" } }, function(item)
		chosen = item.label
	end)
	t:expect_mode("mine-insert")
	t:keys("p e enter")
	assert(chosen == "pear", tostring(chosen))
	t:expect_mode("mine")

	-- It's in :style's list, on the setup page and in describe.
	assert(table.find(core.style.names(), "mine"))
	t:run("style")
	local list = t:floats()[1]
	assert(list and string.find(list, "Mine, a style no plugin knows", 1, true), tostring(list))
	t:keys("esc")
	require("@setup").open()
	local page = greed.view():buffer():text()
	assert(string.find(page, "Mine, a style no plugin knows", 1, true), page)
	local described = require("@describe").text("mine", "style") :: string
	assert(string.find(described, "command: mine (shown as NORMAL)", 1, true), described)
	assert(string.find(described, "typing: mine-insert (shown as INSERT)", 1, true), described)
	assert(string.find(described, "The leader: ctrl-l", 1, true), described)

	greed.option.set("editing-style", "helix")
	greed.plugin.unload("mine")
	t:wait(0)
end)

test("a style name that isn't one keeps the style in use, and says which there are", function(t)
	-- A style other than helix, the default: vim's, or one made here when
	-- core runs alone.
	local core = require("@core")
	if not table.find(core.style.names(), "vim") then
		greed.keymap.bind("other-home", {})
		core.style.define({ name = "vim", doc = "for the test", mode = "other-home" })
	end
	greed.option.set("editing-style", "vim")
	t:buffer("|x")
	greed.option.set("editing-style", "vin")
	assert(greed.mode.get() ~= "helix", "not back in helix")
	local said = table.concat(t:messages(), "\n")
	assert(string.find(said, "no editing style called vin", 1, true), said)
	assert(string.find(said, "vim stays", 1, true), said)
	greed.option.set("editing-style", "helix")
end)
