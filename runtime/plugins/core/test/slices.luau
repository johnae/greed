local test = require("@greed/test")
local greed = require("@greed")

-- Keeps the editor's thread busy for `ms`, as heavy plugin code would.
local function busy(ms: number)
	local until_ = os.clock() + ms / 1000
	while os.clock() < until_ do
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
	greed.keymap.bind("normal", { ["f8"] = "test-slow-key", ["f9"] = "test-quick-key" })
	t:buffer("|x")
	greed.keys.feed("f8 f9")
	t:wait(10)
	assert(table.concat(order, " ") == "slow quick", table.concat(order, " "))
end)
