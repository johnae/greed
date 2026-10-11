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
-- style its output once it shows.
local histories: { [Block]: read.History } = setmetatable({}, { __mode = "k" }) :: any
type Drawn = { shell: Shell, lines: { scene.Line } }
local drawn: { [Block]: Drawn } = setmetatable({}, { __mode = "k" }) :: any

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
	local ask, why = read.ask(rest)
	if ask == nil then
		return nil, why
	end
	local chart, problem = read.chart(tbl, ask, history, os.time())
	if chart == nil then
		return nil, problem
	end
	local width = ask.width or cols or 72
	local height = ask.height or rows or greed.option.get("chart-height") :: number
	local lines = scene.cells(draw.scene(chart, width, height), width, height)
	-- Bars for a few rows leave empty ones under them.
	while #lines > 1 and lines[#lines].text == "" do
		table.remove(lines)
	end
	return lines, nil
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
	local lines, why = M.lines(tbl, rest, width_of(ctx.shell), nil, history)
	if lines == nil then
		return nil, why
	end
	if block and ctx.shell then
		block.drawn = true
		drawn[block] = { shell = ctx.shell, lines = lines }
	end
	return scene.text(lines), nil
end)

-- A chart's output takes its styles once it shows, as long as it's the
-- chart as drawn.
shell.log.on_update(function(block: Block)
	local d = drawn[block]
	if d == nil then
		return
	end
	local buffer = d.shell.buffer
	local from = shell.log.output_range(d.shell, block)
	local marks: { greed.Mark } = {}
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
			for _, mark in line.marks do
				table.insert(
					marks,
					{ from = start + mark.from, to = start + mark.to, style = mark.style }
				)
			end
		end
	end
	buffer:decorate(`chart.{block.uid}`, marks)
end)

return M
