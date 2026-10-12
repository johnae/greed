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
	-- With scene-drawing cells, the characters are all there is.
	local function scened(): boolean
		for _, mark in sh.buffer:decorations(`chart.{block.uid}`) do
			if mark.scene then
				return true
			end
		end
		return false
	end
	greed.option.set("scene-drawing", "cells")
	assert(not scened(), "no scene with cells")
	greed.option.set("scene-drawing", "auto")
	assert(scened(), "back with auto")
	local bad = finished(t, assert(shell.run(sh, "cat pods | chart DISK")))
	assert(string.find(bad.output, "there's no column DISK", 1, true), bad.output)
end)

test("a chart in the shell shows as an image on the screen, in a watch too", function(t)
	local sh = open(t)
	greed.fs.write(`{sh.cwd}/pods`, "NAME    CPU\napi     2\nworker  1\n")
	local block = finished(t, assert(shell.run(sh, "cat pods | chart --width 30 --height 3")))
	assert(block.status == "done", block.output)
	local frame = t:frame(80, 24)
	assert(#frame.scenes == 1, `{#frame.scenes} scenes placed`)
	local placed = frame.scenes[1]
	assert(placed.width == 30 and placed.height == 2, `{placed.width}x{placed.height}`)
	-- On the chart's own rows: its first one holds the first bar's label.
	assert(string.find(frame.rows[placed.row + 1], "api", 1, true), frame.rows[placed.row + 1])
	-- A watch's chart too, with the shell's space under its block.
	greed.fs.write(`{sh.cwd}/load`, "0.5 0.4 0.3 1/120 4567\n")
	local watch = assert(shell.run(sh, "watch -n 1 cat load | chart --width 30 --height 4"))
	t:wait_for(function()
		return watch.drawn == true and require("@chart").drawing(watch) ~= nil
	end)
	t:wait_for(function()
		return #t:frame(80, 30).scenes == 2
	end)
	shell.kill(watch)
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

test("numbers keep their unit: bytes, kubectl's CPU and percents", function()
	assert(scale.unit({ "", "128Mi", "1Gi" }) == "bytes" and scale.unit({ "4KB" }) == "bytes")
	assert(scale.unit({ "250m", "1" }) == "cores" and scale.unit({ "45%" }) == "percent")
	assert(scale.unit({ "12", "3.5" }) == nil and scale.unit({ "5d" }) == nil)
	assert(
		scale.format(128 * 1024 ^ 2, nil, "bytes") == "128Mi",
		scale.format(128 * 1024 ^ 2, nil, "bytes")
	)
	assert(scale.format(1.5 * 1024 ^ 3, nil, "bytes") == "1.5Gi")
	assert(scale.format(0.25, nil, "cores") == "250m" and scale.format(1.2, nil, "cores") == "1.2")
	assert(scale.format(45, nil, "percent") == "45%")
	-- Ticks of bytes are round in their own unit.
	local ticks = scale.ticks_in(0, 900 * 1024 ^ 2, 3, "bytes")
	assert(
		scale.format(ticks.values[2], ticks.step, "bytes") == "500Mi",
		scale.format(ticks.values[2], ticks.step, "bytes")
	)
	-- Bars of CPU and memory each fill their own room, with their units.
	local pods = tbl(
		{ "NAME", "CPU", "MEMORY" },
		{ { "api", "250m", "128Mi" }, { "worker", "500m", "1Gi" } }
	)
	local text = require("@scene").text((assert(chart.lines(pods, "CPU MEMORY", 40, 5))))
	assert(string.find(text, "250m", 1, true) and string.find(text, "128Mi", 1, true), text)
	assert(string.find(text, "1Gi", 1, true), text)
end)

test("a stacked bar leaves room for its total", function()
	local rows = tbl({ "NAME", "A", "B" }, { { "x", "600", "500" } })
	local text = require("@scene").text((assert(chart.lines(rows, "bar A B --stacked", 20, 3))))
	assert(string.find(text, "1.1k", 1, true), text)
	for line in string.gmatch(text, "[^\n]+") do
		assert((utf8.len(line) or #line) <= 20, "within its width: " .. line)
	end
end)

test("text read as words names a row by its words that aren't numbers", function()
	local authors = tbl(
		{ "1", "2", "3", "4" },
		{ { "737", "John", "Axel", "Eriksson" }, { "12", "Ann", "Lee" } }
	)
	local bars = assert(read.chart(authors, assert(read.ask("")), nil, 0))
	assert(bars.kind == "bar" and bars.labels and bars.labels[1] == "John Axel Eriksson", bars.kind)
	-- One row is a line of its first number, its other words no name.
	local load = tbl(
		{ "1", "2", "3", "4", "5" },
		{ { "5.96", "4.45", "3.32", "1/2615", "3822008" } }
	)
	local line = assert(read.chart(load, assert(read.ask("")), nil, 0))
	assert(line.kind == "line" and line.series[1].name == "1", line.kind)
end)

test("on a short chart each row has one tick label at most", function()
	local numbers = tbl({ "n" }, { { "0.024" }, { "0.03" } })
	local text = require("@scene").text((assert(chart.lines(numbers, "", 30, 4))))
	assert(not string.find(text, "00.0", 1, true), text)
end)

test("--why says how each column was read and why the chart is what it is", function()
	local pods = tbl(
		{ "NAME", "CPU", "MEMORY", "AGE" },
		{ { "api", "250m", "128Mi", "3d" }, { "worker", "1", "1Gi", "2h" } }
	)
	local said = require("@scene").text((assert(chart.lines(pods, "--why", 40, 6))))
	assert(string.find(said, "NAME    names, for the rows", 1, true), said)
	assert(string.find(said, "CPU     numbers, in cores, charted", 1, true), said)
	assert(string.find(said, "MEMORY  numbers, in bytes, left out", 1, true), said)
	assert(string.find(said, "AGE     durations, left out", 1, true), said)
	assert(
		string.find(said, "because the rows have names (NAME): a bar each, of CPU", 1, true),
		said
	)
	local asked = require("@scene").text((assert(chart.lines(pods, "line --why", 40, 6))))
	assert(string.find(asked, "(as asked)", 1, true), asked)
end)

test("a watch drawing a chart says so above the prompt, not its first characters", function(t)
	local sh = open(t)
	greed.fs.write(`{sh.cwd}/load`, "0.5\n")
	local block = assert(shell.run(sh, "watch -n 1 cat load | chart --width 30 --height 4"))
	t:wait_for(function()
		return block.output ~= ""
	end)
	assert(shell.log.running_status(block) == "a chart", shell.log.running_status(block))
	shell.interrupt(block)
end)

test("ps: ids aren't charted, TIME isn't a time, and the greatest bars show", function()
	local ps = tbl({ "PID", "TTY", "TIME", "CMD", "CPU" }, {
		{ "1", "pts/0", "00:00:03", "bash", "0.5" },
		{ "2", "pts/0", "00:01:00", "cargo", "9" },
		{ "3", "pts/1", "00:00:01", "nu", "2" },
		{ "4", "pts/1", "00:00:00", "ps", "0.1" },
	})
	local made = assert(read.chart(ps, assert(read.ask("")), nil, 0))
	assert(made.kind == "bar", made.kind)
	assert(made.series[1].name == "CPU", made.series[1].name)
	-- Asked for, an id is charted all the same.
	assert(assert(read.chart(ps, assert(read.ask("PID")), nil, 0)).series[1].name == "PID")
	-- Two rows of room: the greatest, then how many more.
	local text = require("@scene").text((assert(chart.lines(ps, "CPU by CMD", 30, 3))))
	assert(string.find(text, "^cargo"), text)
	assert(string.find(text, "\nnu ", 1, true), text)
	assert(string.find(text, "2 more, the greatest above", 1, true), text)
end)

test("a watch of many rows draws the eight greatest now, on an axis from zero", function()
	local history = read.history("")
	local rows = {}
	for i = 1, 20 do
		rows[i] = { `p{i}`, if i == 15 then "50" else "0" }
	end
	local made = assert(read.chart(tbl({ "NAME", "CPU" }, rows), assert(read.ask("")), history, 1))
	assert(#made.series == 8, tostring(#made.series))
	local names = {}
	for _, s in made.series do
		names[s.name] = true
	end
	assert(names.p15, "the busiest is drawn")
	local zero = scale.ticks(0, 0, 3)
	assert(zero.lo == 0 and zero.hi >= 1, `{zero.lo} {zero.hi}`)
end)

test("a long table over time, by a column, is a line for each of its values", function()
	local samples = tbl({ "time", "host", "cpu" }, {
		{ "2026-10-11T10:00:00Z", "web", "20" },
		{ "2026-10-11T10:00:00Z", "db", "60" },
		{ "2026-10-11T10:00:05Z", "web", "30" },
		{ "2026-10-11T10:00:05Z", "db", "50" },
	})
	local split = assert(read.chart(samples, assert(read.ask("cpu by host")), nil, 0))
	assert(split.kind == "line" and split.x == "time", split.kind)
	assert(#split.series == 2, tostring(#split.series))
	local web = split.series[1]
	assert(web.name == "web" and #web.points == 2 and web.points[2][2] == 30, web.name)
	-- Guessed too: the time column, the name column and the number.
	local guessed = assert(read.chart(samples, assert(read.ask("by host")), nil, 0))
	assert(#guessed.series == 2 and guessed.series[2].name == "db", guessed.series[2].name)
	-- Over another column than the time, as asked.
	local over = assert(read.chart(samples, assert(read.ask("cpu over time by host")), nil, 0))
	assert(#over.series == 2, tostring(#over.series))
end)

test("in a watch, rows of the same name in one run add up to one point", function()
	local ask = assert(read.ask(""))
	local history = read.history("")
	local ps = tbl({ "COMMAND", "%CPU" }, {
		{ "firefox", "10" },
		{ "greed", "3" },
		{ "firefox", "5" },
	})
	local made = assert(read.chart(ps, ask, history, 1))
	assert(#made.series == 2, tostring(#made.series))
	local firefox = made.series[1]
	assert(firefox.name == "firefox" and #firefox.points == 1, firefox.name)
	assert(firefox.points[1][2] == 15, tostring(firefox.points[1][2]))
end)

test("--why in the shell is text, with no picture over it", function(t)
	local sh = open(t)
	greed.fs.write(`{sh.cwd}/pods`, "NAME CPU\napi 250m\nworker 1\n")
	local block = finished(t, assert(shell.run(sh, "cat pods | chart --why")))
	assert(string.find(block.output, "NAME  names, for the rows", 1, true), block.output)
	assert(chart.drawing(block) == nil, "nothing drawn")
end)
