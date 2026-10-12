-- Charts in the shell: `| chart` draws a table as a chart, guessing the
-- kind from its columns unless told. A name column and numbers are bars;
-- times and numbers, lines over time; numbers alone, a line each; two
-- numbers, one against the other. In a watch every run adds a point, so
-- `watch -n 1 kubectl top pods | chart` draws how each pod's CPU goes.
--
--     kubectl top pods | chart                  bars, a pod each
--     kubectl top pods | chart bar MEMORY       of another column
--     watch -n 1 cat /proc/loadavg | chart      the load, over time
--     $3 | chart area --stacked                 how a table says
--
-- A chart is drawn in characters, braille for lines and eighth blocks for
-- bars, in the theme's chart styles, so it shows in every terminal; on a
-- board, a card with `chart` after its language is one.

local greed = require("@greed")
local shell = require("@shell")
local scene = require("@scene")
local core = require("@core")
local markdown = require("@markdown")
local data_blocks = require("@data").document
local draw = require("@self/draw")
local read = require("@self/read")

type Block = shell.Block
type Shell = shell.Shell

local M = {}

M.draw = draw
M.read = read
M.scale = require("@self/scale")

greed.option.define({
	name = "chart-height",
	doc = "How many lines tall a chart in the shell is, unless --height says",
	default = 12,
})

-- What each watch's chart has had, and each block's chart as drawn, to
-- style its output once it shows and place its scene over it: the scene's
-- id, and how many cells wide it is.
local histories: { [Block]: read.History } = setmetatable({}, { __mode = "k" }) :: any
type Drawn = { shell: Shell, lines: { scene.Line }, scene: number, cols: number }
local drawn: { [Block]: Drawn } = setmetatable({}, { __mode = "k" }) :: any

-- The scenes charts in each shell's buffer drew, by its id, to forget with
-- it.
local scenes: { [number]: { number } } = {}

-- How wide a chart in `sh` is: as the view showing it, a little in.
local function width_of(sh: Shell?): number
	if sh then
		for _, view in sh.buffer:views() do
			local _, cols = view:size()
			if cols then
				return math.max(cols - 2, 20)
			end
		end
	end
	return 72
end

-- A chart made: the scene (none for `--why`, which is only text), how many
-- cells wide it is, and the scene in characters.
type Made = { spec: scene.Spec?, cols: number, lines: { scene.Line } }

-- `tbl` as a chart `rest` asks for, as `lines` says; nil and why when
-- there's nothing to chart.
local function make(
	tbl: shell.Table,
	rest: string,
	cols: number?,
	rows: number?,
	history: read.History?
): (Made?, string?)
	local ask, why = read.ask(rest)
	if ask == nil then
		return nil, why
	end
	local chart, problem = read.chart(tbl, ask, history, os.time())
	if chart == nil then
		return nil, problem
	end
	if ask.why then
		local lines: { scene.Line } = {}
		for _, text in string.split(read.why(chart), "\n") do
			local line: scene.Line = { text = text, marks = {} }
			table.insert(lines, line)
		end
		return { cols = 0, lines = lines }, nil
	end
	local width = ask.width or cols or 72
	local height = ask.height or rows or greed.option.get("chart-height") :: number
	local spec = draw.scene(chart, width, height)
	local lines = scene.cells(spec, width, height)
	-- Bars for a few rows leave empty ones under them.
	while #lines > 1 and lines[#lines].text == "" do
		table.remove(lines)
	end
	return { spec = spec, cols = width, lines = lines }, nil
end

--- `tbl` as a chart `rest` asks for, `cols` by `rows` cells, as styled
--- lines: in a watch, `history` keeps its points from run to run. Nil and
--- why when there's nothing to chart.
function M.lines(
	tbl: shell.Table,
	rest: string,
	cols: number?,
	rows: number?,
	history: read.History?
): ({ scene.Line }?, string?)
	local made, why = make(tbl, rest, cols, rows, history)
	return if made then made.lines else nil, why
end

shell.stage({
	name = "chart",
	usage = read.USAGE,
	doc = "Draw the table as a chart: bars, lines, areas or dots, guessed from its columns; in a watch, over time",
	args = "columns",
	starts = true,
	text = true,
}, function(tbl, rest, ctx)
	local block: Block? = ctx.block
	local history: read.History? = nil
	if block and block.watching then
		local kept = histories[block]
		if kept == nil or kept.key ~= rest then
			kept = read.history(rest)
			histories[block] = kept
		end
		history = kept
	end
	local made, why = make(tbl, rest, width_of(ctx.shell), nil, history)
	if made == nil then
		return nil, why
	end
	local sh: Shell? = ctx.shell
	local spec = made.spec
	if block and sh and spec then
		block.drawn = true
		-- The block's scene, a version on, or a new one.
		local before = drawn[block]
		local id = if before and greed.scene.set(before.scene, spec)
			then before.scene
			else greed.scene.new(spec)
		if before == nil or before.scene ~= id then
			local buffer = sh.buffer:id()
			scenes[buffer] = scenes[buffer] or {}
			table.insert(scenes[buffer], id)
		end
		drawn[block] = { shell = sh, lines = made.lines, scene = id, cols = made.cols }
	end
	return scene.text(made.lines), nil
end)

-- A chart's output takes its styles once it shows, as long as it's the
-- chart as drawn.
local function paint(block: Block)
	local d = drawn[block]
	if d == nil then
		return
	end
	local buffer = d.shell.buffer
	local from = shell.output(d.shell, block)
	local marks: { greed.Mark } = {}
	local matched = 0
	if from then
		local first = buffer:line_of(from)
		for i, line in d.lines do
			local n = first + i - 1
			if n >= buffer:line_count() then
				break
			end
			local start = buffer:line_start(n)
			if buffer:slice(start, start + #line.text) ~= line.text then
				break
			end
			matched = i
			for _, mark in line.marks do
				table.insert(
					marks,
					{ from = start + mark.from, to = start + mark.to, style = mark.style }
				)
			end
		end
	end
	-- The whole chart showing, its scene goes over it, for the clients that
	-- draw one better than the characters.
	-- It covers the chart's characters, so it's drawn only while they all
	-- show as they are: not once the block is folded, or its text changes.
	if from and matched == #d.lines and scene.drawn() then
		local first = buffer:line_of(from)
		table.insert(marks, {
			from = buffer:line_start(first),
			to = buffer:line_end(first + #d.lines - 1),
			style = "",
			scene = { id = d.scene, cols = d.cols, rows = #d.lines },
		})
	end
	buffer:decorate(`chart.{block.uid}`, marks)
end
shell.on_update(paint)

-- Charts show as `scene-drawing` says now.
greed.on("option.changed", function(event)
	if event.name == "scene-drawing" then
		for block in drawn do
			paint(block)
		end
	end
end)

-- A shell's charts' scenes go with it.
greed.on("buffer.closed", function(event)
	local ids: { number } = scenes[event.id] or {}
	for _, id in ids do
		greed.scene.forget(id)
	end
	scenes[event.id] = nil
end)

--- The chart `block` drew last, if it drew one: its lines as drawn,
--- styled, and its scene's id, cells wide and as many rows as lines, to
--- show it elsewhere, as a board's card does.
function M.drawing(block: Block): { lines: { scene.Line }, scene: number, cols: number }?
	local d = drawn[block]
	return if d then { lines = d.lines, scene = d.scene, cols = d.cols } else nil
end

-- Charts in Markdown: `<!-- chart: bar per_year -->` right under a table
-- (after any formula lines) draws the table, its formulas worked out
-- (markdown's values.luau), under it, as `| chart` would: the same words
-- after `chart:`. GitHub and the like don't show it; here it's drawn again
-- as the table and the values it uses change.

-- `line` as pieces for a mark's line, its styles kept.
local function pieces(line: scene.Line): greed.MarkLine
	local out: { { text: string, style: string?, action: string? } } = {}
	local marks = table.clone(line.marks)
	table.sort(marks, function(a: greed.Mark, b: greed.Mark): boolean
		return a.from < b.from
	end)
	local at = 0
	for _, mark in marks do
		if mark.from > at then
			table.insert(out, { text = string.sub(line.text, at + 1, mark.from) })
		end
		table.insert(
			out,
			{ text = string.sub(line.text, mark.from + 1, mark.to), style = mark.style }
		)
		at = math.max(at, mark.to)
	end
	if at < #line.text then
		table.insert(out, { text = string.sub(line.text, at + 1) })
	end
	return out
end

-- How wide a chart in a document shown in `buffer` is: as its view, a
-- little in, and no wider than reads well.
local function document_width(buffer: greed.Buffer): number
	for _, view in buffer:views() do
		local _, cols = view:size()
		if cols then
			return math.clamp(cols - 4, 20, 80)
		end
	end
	return 60
end

-- A chart drawn: its lines, and its scene (nil when there's none) and how
-- many cells wide.
type Charted = { lines: { greed.MarkLine }, spec: scene.Spec?, cols: number }

-- `data` charted as `ask` asks, for `buffer`; or why it can't be.
local function charted(buffer: greed.Buffer, data: markdown.Data, ask: string): Charted
	local rows: { { [string]: string } } = {}
	for _, row in data.rows do
		local cells: { [string]: string } = {}
		for _, key in data.keys do
			cells[key] = core.formula.show(row[key])
		end
		table.insert(rows, cells)
	end
	local tbl: shell.Table = { columns = data.keys, rows = rows }
	local made, why = make(tbl, ask, document_width(buffer), nil, nil)
	if made == nil then
		return { lines = { { { text = `⚠ {why}`, style = "markdown.value.error" } } }, cols = 0 }
	end
	local lines: { greed.MarkLine } = {}
	for _, line in made.lines do
		table.insert(lines, pieces(line))
	end
	return { lines = lines, spec = made.spec, cols = made.cols }
end

-- The scenes charts in each document drew, by its buffer's id and the line
-- of the chart, to draw again as the chart changes and forget with it.
local document_scenes: { [number]: { [number]: number } } = {}

-- The scene for the chart on line `n` of `buffer`, showing `spec`.
local function scene_for(buffer: greed.Buffer, n: number, spec: scene.Spec): number
	local id = buffer:id()
	local known = document_scenes[id] or {}
	document_scenes[id] = known
	local before = known[n]
	if before and greed.scene.set(before, spec) then
		return before
	end
	local made = greed.scene.new(spec)
	known[n] = made
	return made
end

greed.on("buffer.closed", function(event)
	local known: { [number]: number } = document_scenes[event.id] or {}
	for _, id in known do
		greed.scene.forget(id)
	end
	document_scenes[event.id] = nil
end)

-- The charts the comment lines from line `n` of `s` ask for (formula lines
-- may come first), drawing the table `data` gives, into `out`; only those
-- on lines `first` to `last`. `data` is asked once, if a chart needs it,
-- and gives nil while there's no table yet.
local function charts_from(
	buffer: greed.Buffer,
	s: markdown.Structure,
	n: number,
	first: number,
	last: number,
	data: () -> markdown.Data?,
	out: { greed.Mark }
)
	local got: markdown.Data? = nil
	while n < #s.lines and string.match(s.lines[n + 1], "^%s*<!%-%-") do
		local ask = string.match(s.lines[n + 1], "^%s*<!%-%-%s*chart:%s*(.-)%s*%-%->%s*$")
		if ask and n >= first and n <= last then
			got = got or data()
		end
		if ask and got and n >= first and n <= last then
			local chart = charted(buffer, got, ask)
			local from, to = s.starts[n + 1], s.starts[n + 1] + #s.lines[n + 1]
			table.insert(out, { from = from, to = to, style = "", lines = chart.lines })
			-- For the clients that draw one, the chart's scene over its
			-- lines, a row under the comment line, which stays in sight
			-- to edit. Empty, as those lines are only drawn, not the
			-- file's: the scene is placed from the line's start.
			local spec = chart.spec
			if spec and scene.drawn() then
				table.insert(out, {
					from = from,
					to = from,
					style = "",
					scene = {
						id = scene_for(buffer, n, spec),
						cols = chart.cols,
						rows = #chart.lines,
						row = -1,
					},
				})
			end
		end
		n += 1
	end
end

-- A data table (a data block's, see the data plugin) as a chart reads a
-- Markdown table: its columns named as formulas name them.
local function from_data(t: core.DataTable): markdown.Data
	local keys: { string } = {}
	for _, column in t.columns do
		table.insert(keys, markdown.values.key(column.name))
	end
	local rows: { { [string]: any } } = {}
	for _, row in ipairs(markdown.values.table(t)) do
		table.insert(rows, row)
	end
	return { keys = keys, rows = rows }
end

markdown.conceal({
	ns = "chart-tables",
	wants = markdown.drawn,
	draw = function(buffer, s, first, last): { greed.Mark }
		local out: { greed.Mark } = {}
		for _, found in s.tables do
			charts_from(buffer, s, found.last + 1, first, last, function(): markdown.Data?
				return markdown.values.data(buffer, s, found)
			end, out)
		end
		-- Under a data block, the table it read.
		for _, code in s.code do
			if code.closed and core.data.get(code.lang) then
				charts_from(buffer, s, code.close + 1, first, last, function(): markdown.Data?
					local t = data_blocks.table(buffer, code)
					return if t then from_data(t) else nil
				end, out)
			end
		end
		return out
	end,
})

return M
