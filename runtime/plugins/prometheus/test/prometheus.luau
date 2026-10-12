local test = require("@greed/test")
local greed = require("@greed")
local shell = require("@shell")
local prom = require("@prometheus")

-- What Prometheus answers, as its HTTP API documents it.
local VECTOR = [==[{"status":"success","data":{"resultType":"vector","result":[
{"metric":{"__name__":"up","job":"api","instance":"10.0.0.1:9100"},"value":[1760000000,"1"]},
{"metric":{"__name__":"up","job":"db","instance":"10.0.0.2:9100"},"value":[1760000000,"0"]},
{"metric":{"job":"broken"},"value":[1760000000,"NaN"]}]}}]==]

local MATRIX = [==[{"status":"success","data":{"resultType":"matrix","result":[
{"metric":{"job":"api"},"values":[[1760000000,"1.5"],[1760000060,"2.5"]]},
{"metric":{"job":"db"},"values":[[1760000000,"0.5"],[1760000060,"0.75"]]}]}}]==]

local ERROR = [==[{"status":"error","errorType":"bad_data","error":"parse error at char 5"}]==]

-- Answers `answer` to every request, keeping the URLs asked for.
local function serve(answer: string): { string }
	local asked: { string } = {}
	prom.fetch = function(url: string): (string?, string?)
		table.insert(asked, url)
		return answer, nil
	end
	return asked
end

test("an answer now is a row a series; over a range, a row a time", function()
	local now = assert(prom.rows(VECTOR))
	assert(#now == 2, "NaN left out: " .. #now)
	assert(now[1].name == "10.0.0.1:9100/api" and now[1].value == 1, now[1].name)
	local range = assert(prom.rows(MATRIX))
	assert(#range == 2 and range[1].time == "2025-10-09T08:53:20Z", range[1].time)
	assert(range[2].api == 2.5 and range[2].db == 0.75)
	local none, why = prom.rows(ERROR)
	assert(none == nil and why == "parse error at char 5", why)
	assert(prom.rows("not json") == nil)
	assert(prom.name({ __name__ = "up" }) == "up" and prom.name({}) == "value")
	assert(prom.seconds("1h") == 3600 and prom.seconds("90s") == 90 and prom.seconds("x") == nil)
end)

test("a query asks the server the option names, the range from now", function()
	local asked = serve(MATRIX)
	greed.option.set("prometheus-url", "http://prom.test:9090/")
	assert(prom.query("rate(x[5m]) > 0", { range = 600, now = 1000 }))
	assert(
		asked[1]
			== "http://prom.test:9090/api/v1/query_range?query=rate%28x%5B5m%5D%29%20%3E%200&start=400&end=1000&step=5",
		asked[1]
	)
	assert(prom.query("up", { url = "http://other:1" }))
	assert(asked[2] == "http://other:1/api/v1/query?query=up", asked[2])
end)

local function open(t: test.TestContext): shell.Shell
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = t:tempdir()
	return sh
end

local function finished(t: test.TestContext, block: shell.Block): shell.Block
	t:wait_for(function()
		return block.status ~= "running"
	end)
	return block
end

test("prom | chart draws bars of now, and lines over a range", function(t)
	local sh = open(t)
	serve(VECTOR)
	local bars = finished(t, assert(shell.run(sh, "prom 'up' | chart --width 70 --height 3")))
	assert(bars.status == "done", bars.output)
	assert(string.find(bars.output, "10.0.0.1:9100/api", 1, true), bars.output)
	assert(string.find(bars.output, "█", 1, true), bars.output)
	serve(MATRIX)
	local lines = finished(
		t,
		assert(shell.run(sh, "prom 'rate(x[5m])' --range 10m | chart --width 40 --height 6"))
	)
	assert(
		string.find(lines.output, "━ api", 1, true)
			and string.find(lines.output, "━ db", 1, true),
		lines.output
	)
	assert(string.find(lines.output, "[\u{2801}-\u{28ff}]"), lines.output)
end)

test("prom alone is a table; one that fails says why", function(t)
	local sh = open(t)
	serve(VECTOR)
	local table_block = finished(t, assert(shell.run(sh, "prom up")))
	assert(table_block.table and #table_block.table.rows == 2, table_block.output)
	serve(ERROR)
	local bad = finished(t, assert(shell.run(sh, "prom 'up{' | chart")))
	assert(bad.status == "failed", bad.status)
	assert(string.find(bad.output, "parse error at char 5", 1, true), bad.output)
	local usage = finished(t, assert(shell.run(sh, "prom --range")))
	assert(string.find(usage.output, "takes a duration", 1, true), usage.output)
	serve('{"status":"success","data":{"resultType":"vector","result":[]}}')
	local empty = finished(t, assert(shell.run(sh, "prom nothing_here | chart")))
	assert(empty.status == "failed", empty.status)
	assert(string.find(empty.output, "matched no series", 1, true), empty.output)
end)

test("in a watch, prom | chart draws a line a series over time", function(t)
	local sh = open(t)
	local value = 1
	prom.fetch = function(): (string?, string?)
		value += 1
		return `\{"status":"success","data":\{"resultType":"vector","result":[\{"metric":\{"job":"api"},"value":[0,"{value}"]}]}}`,
			nil
	end
	local block = assert(
		shell.run(sh, "watch -n 1 prom up | chart --width 40 --height 5", { view = greed.view() })
	)
	t:wait_for(function()
		return block.output ~= ""
	end)
	local first = block.output
	greed.sleep(1000)
	t:wait_for(function()
		return block.output ~= first
	end)
	assert(block.drawn, "a chart")
	shell.interrupt(block)
end)

test("prom asks the server whatever plugin's code runs it, and only asks for queries", function(t)
	-- A plugin without the network, as the shell is, running prom's fetch.
	greed.plugin.load(t:tempdir({
		["plugin.toml"] = 'name = "offline"\nrequires = ["prometheus"]\n',
		["init.luau"] = [[
local greed = require("@greed")
local prom = require("@prometheus")
greed.command({ name = "offline-ask", run = function(ctx)
	local _, err = prom.fetch(ctx.args[1])
	greed.echo("answered: " .. tostring(err))
end })
]],
	}))
	-- Nothing listens on port 1: refused, not kept from the network.
	t:run("offline-ask", { "http://127.0.0.1:1/api/v1/query?query=up" })
	local said = t:messages()
	local last = said[#said] or ""
	assert(not string.find(last, "capabilities", 1, true), last)
	t:run("offline-ask", { "http://127.0.0.1:1/somewhere/else" })
	said = t:messages()
	last = said[#said] or ""
	assert(string.find(last, "only asks for queries", 1, true), last)
end)
