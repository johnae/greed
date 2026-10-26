local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")

test("a command a second client runs sees that client's view and selection", function(t)
	t:buffer("|hello world")
	local second = t:client("laptop")
	local seen: { client: number, current: number, cursor: number }? = nil
	greed.command({
		name = "test-where",
		run = function(ctx)
			seen = {
				client = ctx.client,
				current = greed.client.current().id,
				cursor = ctx.view:cursor(),
			}
		end,
	})
	second:keys("w")
	second:run("test-where")
	assert(seen, "it ran")
	assert(seen.client == second:id(), `ctx.client {seen.client}`)
	assert(seen.current == second:id(), `greed.client.current() {seen.current}`)
	assert(seen.cursor == 6, `cursor {seen.cursor}`)
	second:expect("^hello |world")
	t:expect("|hello world")
	t:run("test-where")
	assert(seen.client == 1 and seen.cursor == 0, `the first client: {seen.client} {seen.cursor}`)
end)

test("greed.client.list describes every client", function(t)
	local second = t:client("laptop")
	local list = greed.client.list()
	assert(#list == 2, `{#list} clients`)
	local first, other = list[1], list[2]
	assert(first.id == 1 and first.kind == "headless", `{first.id} {first.kind}`)
	assert(other.id == second:id() and other.name == "laptop" and other.kind == "test", other.name)
	assert(first.color ~= other.color, "each its own color")
	assert(
		other.layout == "follow" and other.remote == false and other.person == "owner",
		other.layout
	)
	assert(other.size == nil, "no size before it draws")
	second:draw(30, 8)
	local drawn = greed.client.list()[2].size
	assert(drawn and drawn.width == 30 and drawn.height == 8, "its size once it drew")
end)

test("view.focused comes once, for the client whose focus moved", function(t)
	t:buffer("|hello")
	local second = t:client()
	local heard: { number } = {}
	greed.on("view.focused", function(event: greed.ViewFocused)
		table.insert(heard, event.client)
		assert(greed.client.current().id == event.client, "the handler runs as that client")
	end)
	greed.command({
		name = "test-float",
		run = function()
			greed.float(greed.create_buffer("notes"), { focus = true })
		end,
	})
	second:run("test-float")
	assert(#heard == 1 and heard[1] == second:id(), `heard {table.concat(heard, ", ")}`)
	t:wait(0)
	assert(#heard == 1, "not again")
end)

test("each client has its own mode", function(t)
	t:buffer("|hello")
	local second = t:client()
	local changed: { number } = {}
	greed.on("mode.changed", function(event: greed.ModeChanged)
		table.insert(changed, event.client)
	end)
	second:keys("i")
	second:expect_mode("helix-insert")
	t:expect_mode("helix")
	assert(#changed == 1 and changed[1] == second:id(), `mode.changed for {changed[1]}`)
	t:keys("v")
	t:expect_mode("helix-select")
	second:expect_mode("helix-insert")
	second:keys("x esc")
	second:expect("x|hello")
	second:expect_mode("helix")
end)

test("a key a command waits for comes from the client that ran it", function(t)
	t:buffer("|abc")
	local second = t:client()
	local got: { client: number, key: string }? = nil
	greed.command({
		name = "test-next-key",
		run = function(ctx)
			local key = greed.next_key()
			got = { client = greed.client.current().id, key = key }
		end,
	})
	second:run("test-next-key")
	t:keys("i z esc")
	assert(got == nil, "the first client's keys go through its keymap")
	t:expect("z|abc")
	second:keys("y")
	assert(got and got.key == "y" and got.client == second:id(), "the second client's key answers")
end)

test("each client records its own macro", function(t)
	t:buffer("|abc")
	local second = t:client()
	t:keys("Q")
	assert(core.registers.recording() == "@", "the first client records")
	second:keys("l")
	t:keys("x Q")
	assert(core.registers.macro("@") == "x", `the macro: {core.registers.macro("@")}`)
	second:keys("Q")
	assert(core.registers.recording() == nil, "the first client's isn't")
	second:keys("w Q")
	assert(core.registers.macro("@") == "w", `the second's: {core.registers.macro("@")}`)
end)

-- A hundred numbered lines, without line numbers, the cursor on the first,
-- and a command that puts the acting client's cursor on line `n`.
local function long(t: any)
	-- The views follow their cursors to the edge, with no scroll margin.
	greed.option.set("scroll-margin", 0)
	local lines = {}
	for i = 0, 99 do
		table.insert(lines, (if i == 0 then "|" else "") .. `line {i}`)
	end
	t:buffer(table.concat(lines, "\n"))
	greed.view():buffer():set_line_numbers(false)
	greed.command({
		name = "test-line",
		args = { { name = "n" } },
		run = function(ctx)
			local at = ctx.buffer:line_start(tonumber(ctx.args[1]) :: number)
			ctx.view:set_selection({ ranges = { { anchor = at, head = at } }, primary = 1 })
		end,
	})
end

test("clients of different sizes each scroll to their own cursor", function(t)
	long(t)
	local second = t:client()
	local scrolled: { { client: number, line: number } } = {}
	greed.on("view.scrolled", function(event: greed.ViewScrolled)
		table.insert(scrolled, { client = event.client, line = event.line })
	end)
	second:run("test-line", { "50" })
	local mine = t:draw(30, 11)
	local theirs = second:draw(20, 6)
	assert(mine[1] == "line 0", mine[1])
	assert(theirs[#theirs - 1] == "line 50", `the second's last line: {theirs[#theirs - 1]}`)
	assert(#scrolled == 1 and scrolled[1].client == second:id(), `scrolled: {#scrolled}`)
	assert(scrolled[1].line == 46, `to {scrolled[1].line}`)
	-- Each keeps its place when the other draws.
	assert(t:draw(30, 11)[1] == "line 0", "the first's stayed")
	assert(second:draw(20, 6)[1] == "line 46", "the second's stayed")
end)

test("view:size and view.resized are the acting client's", function(t)
	long(t)
	local second = t:client()
	local resized: { [number]: { number } } = {}
	greed.on("view.resized", function(event: greed.ViewResized)
		resized[event.client] = { event.rows, event.cols }
	end)
	local sizes: { [number]: { number? } } = {}
	greed.command({
		name = "test-size",
		run = function(ctx)
			local rows, cols = ctx.view:size()
			sizes[ctx.client] = { rows, cols }
		end,
	})
	t:draw(30, 11)
	second:draw(20, 6)
	t:run("test-size")
	second:run("test-size")
	assert(sizes[1][1] == 10 and sizes[1][2] == 30, `first: {sizes[1][1]} {sizes[1][2]}`)
	local id = second:id()
	assert(sizes[id][1] == 5 and sizes[id][2] == 20, `second: {sizes[id][1]} {sizes[id][2]}`)
	assert(resized[1] and resized[1][1] == 10, "the first was told its size")
	assert(resized[id] and resized[id][1] == 5 and resized[id][2] == 20, "the second its own")
end)

test("a click lands where the client that clicked shows things", function(t)
	long(t)
	local second = t:client()
	second:run("test-line", { "50" })
	t:draw(30, 11)
	second:draw(20, 6)
	-- The second shows lines 46 to 50; its top row is line 46.
	second:mouse("press", 2, 0)
	second:mouse("release", 2, 0)
	assert(string.find(second:marked(), "\nli|ne 46\n", 1, true), "the second's cursor moved there")
	assert(string.sub(t:marked(), 1, 1) == "|", "the first's stayed")
end)

test("a client gone independent has tabs of its own, and follows again", function(t)
	t:buffer("|hello")
	local second = t:client()
	local closed: { number } = {}
	greed.on("view.closed", function(event: greed.ViewClosed)
		table.insert(closed, event.view)
	end)
	local tabs: { [number]: number } = {}
	greed.command({
		name = "test-tabs",
		run = function(ctx)
			tabs[ctx.client] = #greed.tab.list()
		end,
	})
	greed.command({
		name = "test-new-tab",
		run = function()
			greed.tab.new()
		end,
	})
	second:run("client-independent")
	second:run("test-new-tab")
	t:run("test-tabs")
	second:run("test-tabs")
	assert(tabs[1] == 1 and tabs[second:id()] == 2, `tabs: {tabs[1]} {tabs[second:id()]}`)
	assert(greed.client.list()[2].layout == "independent", "listed as independent")
	-- Its edits still go to the same buffer.
	greed.command({
		name = "test-first-tab",
		run = function()
			greed.tab.switch(greed.tab.list()[1].id)
		end,
	})
	second:run("test-first-tab")
	second:keys("i X esc")
	t:expect("X|hello")
	t:keys("i Y esc")
	second:expect("XY|hello")

	second:run("client-follow")
	assert(greed.client.list()[2].layout == "follow", "following again")
	second:run("test-tabs")
	assert(tabs[second:id()] == 1, `the shared tabs: {tabs[second:id()]}`)
	assert(#closed == 2, `its two panes closed: {#closed}`)
	t:run("test-new-tab")
	second:run("test-tabs")
	assert(tabs[second:id()] == 2, "it follows the first's new tab")
end)

test("zoom is each client's own while following", function(t)
	t:buffer("|hello")
	local second = t:client()
	greed.command({
		name = "test-split",
		run = function(ctx)
			ctx.view:split("right")
		end,
	})
	t:run("test-split")
	local zoomed: { [number]: boolean } = {}
	greed.command({
		name = "test-zoomed",
		run = function(ctx)
			zoomed[ctx.client] = greed.tab.current().zoomed
		end,
	})
	greed.command({
		name = "test-zoom",
		run = function()
			greed.tab.set_zoomed(true)
		end,
	})
	t:run("test-zoom")
	t:run("test-zoomed")
	second:run("test-zoomed")
	assert(zoomed[1] == true and zoomed[second:id()] == false, "the first's alone")
	local mine, theirs = t:draw(30, 6), second:draw(30, 6)
	assert(not string.find(mine[1], "│", 1, true), `one pane: {mine[1]}`)
	assert(string.find(theirs[1], "│", 1, true), `two panes: {theirs[1]}`)
end)

test("a client typing keeps typing where it is while what it's in still shows", function(t)
	t:buffer("|hello")
	local second = t:client()
	greed.command({
		name = "test-split",
		run = function(ctx)
			ctx.view:split("right")
		end,
	})
	greed.command({
		name = "test-new-tab",
		run = function()
			greed.tab.new()
		end,
	})
	second:keys("i")
	t:run("test-split")
	second:expect_mode("helix-insert")
	second:keys("a b")
	second:expect("ab|hello")
	-- Another tab shown takes it out of insert mode, where it's moved to.
	t:run("test-new-tab")
	second:expect_mode("helix")
	second:keys("x")
	t:keys("i y esc")
	t:expect("y|")
end)

test("following and laying out on its own say so, and following keeps the focus", function(t)
	t:buffer("|hello")
	local second = t:client()
	second:run("client-independent")
	local messages = t:messages()
	assert(
		string.find(messages[#messages], "laid out on its own now", 1, true),
		messages[#messages]
	)
	second:keys("i")
	second:run("client-follow")
	messages = t:messages()
	assert(
		string.find(messages[#messages], "follows the others again", 1, true),
		messages[#messages]
	)
	second:expect_mode("helix")
	second:keys("i X esc")
	t:expect("X|hello")
end)
