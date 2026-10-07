local test = require("@greed/test")
local greed = require("@greed")

-- Keeps the editor's thread busy for `ms`, as heavy plugin code would. On
-- a busy machine the thread gets less of that time to work in, and only
-- work counts toward a slice, so it does a set amount of work too.
local function busy(ms: number)
	local until_ = os.clock() + ms / 1000
	local spins = 0
	while os.clock() < until_ or spins < ms * 2000 do
		for _ = 1, 100 do
			spins += 1
		end
	end
end

test("a long command yields to the editor and carries on", function(t)
	local done = false
	greed.command({
		name = "test-long",
		run = function()
			busy(80)
			done = true
		end,
	})
	t:buffer("|x")
	-- greed.run comes back as soon as the command yields; t:run would wait
	-- for its work to settle.
	greed.run("test-long")
	assert(not done, "it gave the editor a turn before finishing")
	t:wait(10)
	assert(done, "and finished after")
end)

test("a plugin's own coroutines never see a yield they didn't ask for", function(t)
	local got = nil
	greed.command({
		name = "test-generator",
		run = function()
			local numbers = coroutine.wrap(function()
				busy(40)
				coroutine.yield(1)
				busy(40)
				coroutine.yield(2)
			end)
			got = { numbers(), numbers() }
		end,
	})
	t:buffer("|x")
	t:run("test-generator")
	t:wait(10)
	assert(got and got[1] == 1 and got[2] == 2, "the generator gave 1 and 2")
end)

-- Long enough, at a check for every call, to have run the coroutine out of
-- stack when each check took a slot of it.
test("a plugin's own coroutine can work long past a slice", function(t)
	local calls = 0
	greed.command({
		name = "test-long-coroutine",
		run = function()
			local work = coroutine.wrap(function()
				local until_ = os.clock() + 1.2
				while os.clock() < until_ do
					calls += 1
				end
				return "done"
			end)
			greed.echo(work())
		end,
	})
	t:buffer("|x")
	t:run("test-long-coroutine")
	t:wait(10)
	local said = t:messages()
	assert(said[#said] == "done", table.concat(said, ", "))
	assert(calls > 10000, `it called os.clock {calls} times`)
end)

test("code that can't yield, like a status line, can work long past a slice", function(t)
	local calls = 0
	greed.statusline(function()
		local until_ = os.clock() + 1.2
		while os.clock() < until_ do
			calls += 1
		end
		return { left = {}, right = {} }
	end)
	t:buffer("|x")
	-- The test runs as a command does, so its slice runs out meanwhile.
	t:status()
	assert(calls > 10000, `it called os.clock {calls} times`)
end)

test("code that holds the editor up is noted with its plugin and what it ran", function(t)
	greed.statusline(function()
		busy(80)
		return { left = {}, right = {} }
	end)
	t:buffer("|x")
	t:status()
	local stall = greed.stalls()[1]
	assert(
		stall and stall.what == "the status line" and stall.ms >= 50,
		"the status line held it up"
	)
	assert(stall.plugin == "test", tostring(stall.plugin))
	t:run("stalls")
	local text = greed.view():buffer():text()
	assert(string.find(text, "the status line", 1, true), text)
	t:keys("q")
end)

test("keys fed together wait for what the key before started to finish", function(t)
	local order = {}
	greed.command({
		name = "test-slow-key",
		run = function()
			busy(40)
			table.insert(order, "slow")
		end,
	})
	greed.command({
		name = "test-quick-key",
		run = function()
			table.insert(order, "quick")
		end,
	})
	greed.keymap.bind("helix", { ["f8"] = "test-slow-key", ["f9"] = "test-quick-key" })
	t:buffer("|x")
	greed.keys.feed("f8 f9")
	t:wait(10)
	assert(table.concat(order, " ") == "slow quick", table.concat(order, " "))
end)
