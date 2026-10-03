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
	t:run("test-long")
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
