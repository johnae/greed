local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")

test("calls at once with the same key share one run; another key runs apart", function(t)
	local runs: { string } = {}
	local start = core.joined(function(key: string): (string?, string?)
		table.insert(runs, key)
		greed.sleep(50)
		return `{key} started`, nil
	end)
	local got: { string } = {}
	for _, key in { "a", "a", "b", "a" } do
		greed.spawn(function()
			local said = assert(start(key))
			table.insert(got, said)
		end)
	end
	t:wait_for(function(): boolean
		return #got == 4
	end)
	table.sort(runs)
	assert(table.concat(runs, " ") == "a b", table.concat(runs, " "))
	table.sort(got)
	local said = table.concat(got, ", ")
	assert(said == "a started, a started, a started, b started", said)
	-- Once it's done, the next call runs again.
	greed.spawn(function()
		start("a")
	end)
	t:wait_for(function(): boolean
		return #runs == 3
	end)
end)

test("an error goes to the caller, and those waiting get it as why", function(t)
	local start = core.joined(function(_key: string): (string?, string?)
		greed.sleep(20)
		error("no program", 0)
	end)
	local whys: { string } = {}
	for _ = 1, 2 do
		greed.spawn(function()
			local ok, value, why = pcall(start, "x")
			table.insert(whys, if ok then tostring(why) else tostring(value))
		end)
	end
	t:wait_for(function(): boolean
		return #whys == 2
	end)
	assert(whys[1] == "no program" and whys[2] == "no program", table.concat(whys, " | "))
end)
