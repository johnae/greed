local test = require("@greed/test")
local greed = require("@greed")
local shell = require("@shell")
local chart = require("@chart")

type Shell = typeof(shell.open())
type Block = typeof(assert(shell.run(shell.open(), "true")))

local read, scale = chart.read, chart.scale

test("ticks are round, 1, 2 or 5 times a power of ten apart, and numbers are short", function()
	local ticks = scale.ticks(0.13, 0.87, 4)
	assert(
		ticks.step == 0.2 and ticks.lo == 0 and ticks.hi == 1,
		`{ticks.step} {ticks.lo} {ticks.hi}`
	)
	assert(#ticks.values == 6 and ticks.values[2] == 0.2, tostring(ticks.values[2]))
	local one = scale.ticks(5, 5, 3)
	assert(one.lo < 5 and one.hi > 5, "a single value gets room")
	assert(scale.format(1250) == "1.25k" and scale.format(3400000, 1e6) == "3M", scale.format(1250))
	assert(
		scale.format(0.25, 0.05) == "0.25" and scale.format(2, 0.5) == "2",
		scale.format(0.25, 0.05)
	)
end)

test("what chart is asked for: a kind, columns, by, over and flags", function()
	local ask = assert(read.ask("bar CPU MEM by NAME --stacked --last 30 --width 40"))
	assert(ask.kind == "bar" and #ask.columns == 2 and ask.by == "NAME" and ask.stacked)
	assert(ask.last == 30 and ask.width == 40)
	local over = assert(read.ask("line rate over TIME --log"))
	assert(over.kind == "line" and over.columns[1] == "rate" and over.over == "TIME" and over.log)
	local none, why = read.ask("--sideways")
	assert(none == nil and string.find(why or "", "there's no --sideways", 1, true), why)
	assert(read.ask("--height x") == nil)
end)

local function tbl(columns: { string }, rows: { { string } }): any
	local out = {}
	for _, cells in rows do
		local row = {}
		for i, c in columns do
			row[c] = cells[i]
		end
		table.insert(out, row)
	end
	return { columns = columns, rows = out }
end

test("the kind is guessed from the columns", function()
	local pods = tbl(
		{ "NAME", "CPU", "MEMORY" },
		{ { "api", "250m", "128Mi" }, { "worker", "1", "1Gi" } }
	)
	local bars = assert(read.chart(pods, assert(read.ask("")), nil, 0))
	assert(bars.kind == "bar" and bars.labels and bars.labels[2] == "worker")
	assert(bars.series[1].points[1][2] == 0.25, tostring(bars.series[1].points[1][2]))
	-- Of the first number only, as CPU and bytes on one scale would hide
	-- the CPU; both when they're asked for.
	assert(#bars.series == 1, tostring(#bars.series))
	local both = assert(read.chart(pods, assert(read.ask("CPU MEMORY")), nil, 0))
	assert(#both.series == 2 and both.series[2].name == "MEMORY")
	local times = tbl(
		{ "time", "rate" },
		{ { "2026-10-11T10:00:05Z", "3" }, { "2026-10-11T10:00:00Z", "1" } }
	)
	local line = assert(read.chart(times, assert(read.ask("")), nil, 0))
	assert(
		line.kind == "line" and line.x == "time" and line.series[1].points[1][2] == 1,
		"sorted by time"
	)
	local numbers = tbl({ "a", "b", "c" }, { { "1", "2", "3" }, { "2", "3", "4" } })
	local each = assert(read.chart(numbers, assert(read.ask("")), nil, 0))
	assert(each.kind == "line" and each.x == "index" and #each.series == 3)
	local two = tbl({ "x", "y" }, { { "1", "2" }, { "2", "4" } })
	assert(assert(read.chart(two, assert(read.ask("")), nil, 0)).kind == "scatter")
	-- Text as words charts its first number.
	local words = tbl({ "1", "2", "3", "4" }, { { "0.52", "0.48", "0.40", "1/123" } })
	local load = assert(read.chart(words, assert(read.ask("")), nil, 0))
	assert(#load.series == 1 and load.series[1].name == "1", load.series[1].name)
	-- What can't be charted says why.
	local _, missing = read.chart(pods, assert(read.ask("DISK")), nil, 0)
	assert(
		string.find(missing or "", "there's no column DISK; there are NAME, CPU, MEMORY", 1, true),
		missing
	)
	local _, none = read.chart(tbl({ "NAME" }, { { "api" } }), assert(read.ask("")), nil, 0)
	assert(string.find(none or "", "no numbers to chart", 1, true), none)
end)

test("in a watch each run adds a point to each series, as many as --last keeps", function()
	local ask = assert(read.ask("--last 2"))
	local history = read.history("--last 2")
	local pods = tbl({ "NAME", "CPU" }, { { "api", "1" }, { "worker", "2" } })
	for t = 1, 3 do
		assert(read.chart(pods, ask, history, t))
	end
	local made = assert(read.chart(pods, ask, history, 4))
	assert(made.kind == "line" and made.x == "time" and #made.series == 2)
	local points = made.series[1].points
	assert(made.series[1].name == "api" and #points == 2 and points[2][1] == 4, tostring(#points))
end)

test("bars and lines are drawn in characters, with labels and values", function()
	local pods = tbl({ "NAME", "CPU" }, { { "api", "2" }, { "worker", "1" } })
	local lines = assert(chart.lines(pods, "", 30, 4))
	local text = require("@scene").text(lines)
	assert(string.find(text, "^api%s+█+"), text)
	assert(string.find(text, "\nworker%s+█") and string.find(text, " 1%s*$"), text)
	local styled = false
	for _, mark in lines[1].marks do
		styled = styled or mark.style == "chart.series.1"
	end
	assert(styled, "the bar is in the first series' style")
	local numbers = tbl({ "n" }, { { "1" }, { "3" }, { "2" }, { "5" } })
	local drawn = require("@scene").text((assert(chart.lines(numbers, "", 30, 6))))
	assert(string.find(drawn, "[\u{2801}-\u{28ff}]"), "braille: " .. drawn)
	-- Ticks up the side, and the first and last row along the bottom.
	assert(string.find(drawn, "^6") and string.find(drawn, "\n0"), drawn)
	assert(string.find(drawn, "1%s+4%s*$"), drawn)
end)

local function open(t: test.TestContext): Shell
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = t:tempdir()
	return sh
end

local function finished(t: test.TestContext, block: Block): Block
	t:wait_for(function()
		return block.status ~= "running"
	end)
	return block
end

test("| chart in the shell draws the table, in the chart styles", function(t)
	local sh = open(t)
	greed.fs.write(`{sh.cwd}/pods`, "NAME    CPU\napi     2\nworker  1\n")
	local block = finished(t, assert(shell.run(sh, "cat pods | chart --width 30 --height 3")))
	assert(block.status == "done", block.output)
	assert(string.find(block.output, "api%s+█"), block.output)
	assert(block.drawn, "its output is a drawing")
	local styles: { [string]: boolean } = {}
	for _, mark in sh.buffer:decorations(`chart.{block.uid}`) do
		styles[mark.style or ""] = true
	end
	assert(styles["chart.series.1"] and styles["chart.label"], "styled")
	-- A scene over it, for the clients that draw one better.
	local placed: any = nil
	for _, mark in sh.buffer:decorations(`chart.{block.uid}`) do
		placed = mark.scene or placed
	end
	assert(placed and placed.cols == 30 and placed.rows == 2, "a scene over its two rows")
	assert(greed.scene.set(placed.id, { alt = "still there", items = {} }), "the scene is kept")
	local bad = finished(t, assert(shell.run(sh, "cat pods | chart DISK")))
	assert(string.find(bad.output, "there's no column DISK", 1, true), bad.output)
end)

test("in a watch, | chart draws how the numbers went, without marking lines changed", function(t)
	local sh = open(t)
	greed.fs.write(`{sh.cwd}/load`, "0.5 0.4 0.3 1/120 4567\n")
	local block = assert(
		shell.run(sh, "watch -n 1 cat load | chart --width 30 --height 6", { view = greed.view() })
	)
	t:wait_for(function()
		return block.output ~= ""
	end)
	local first = block.output
	greed.fs.write(`{sh.cwd}/load`, "0.9 0.4 0.3 1/120 4567\n")
	greed.sleep(1000)
	t:wait_for(function()
		return block.output ~= first
	end)
	assert(block.drawn and block.table == nil, "a drawing, not a table")
	assert(string.find(block.output, "[\u{2801}-\u{28ff}]"), block.output)
	for _, mark in sh.buffer:decorations(`shell.out.{block.uid}`) do
		assert(mark.style ~= "shell.changed", "its lines aren't marked changed")
	end
	shell.interrupt(block)
end)
