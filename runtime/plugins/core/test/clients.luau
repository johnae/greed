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
