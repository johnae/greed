-- Scenes: small vector drawings, as charts are made of, and how one looks
-- drawn in a block of character cells, which every client shows. Lines
-- and dots are braille, two by four dots a cell; filled shapes are eighth
-- blocks, so a bar's end falls between cells; text is text. Each cell
-- takes the style of what was drawn in it last.
--
-- A scene's coordinates are in cells, as numbers with fractions: (0, 0)
-- is the top left, (cols, rows) the bottom right, y going down.
--
--     local scene = require("@scene")
--     local lines = scene.cells({
--         alt = "cpu over the last minute",
--         items = {
--             { kind = "line", points = { { 0, 9 }, { 10, 2 } }, style = "chart.series.1" },
--             { kind = "rect", at = { 12, 4 }, size = { 1, 6 }, fill = "chart.series.2" },
--             { kind = "text", at = { 0, 0 }, text = "cpu", style = "chart.title" },
--         },
--     }, 40, 10)
--
-- Items are drawn in order: `line` (points, style), `area` (points down
-- to `base`, fill), `rect` (at, size, fill, or style for its edges),
-- `dots` (points, style), `text` (at, text, style, align "start",
-- "middle" or "end") and `group` (items, clipped to `clip`, x0 y0 x1 y1).
-- Kinds it doesn't know are left out.

local greed = require("@greed")

local M = {}

greed.option.define({
	name = "scene-drawing",
	doc = "How charts and other scenes show: auto (as an image where the terminal can draw one, else characters) or cells (characters everywhere)",
	default = "auto",
	choices = { "auto", "cells" },
})

--- Whether scenes go over their characters, for the clients that can draw
--- them better: unless `scene-drawing` says cells.
function M.drawn(): boolean
	return greed.option.get("scene-drawing") ~= "cells"
end

--- A point, x then y, in cells.
export type Point = { number }

--- Something drawn in a scene; which fields it uses depends on its kind.
export type Item = {
	kind: string,
	points: { Point }?,
	at: Point?,
	size: Point?,
	text: string?,
	style: string?,
	fill: string?,
	base: number?,
	align: string?,
	weight: number?,
	opacity: number?,
	items: { Item }?,
	clip: { number }?,
}

--- A scene: what's drawn, and a line saying what it shows.
export type Spec = { alt: string, items: { Item } }

--- A line of a scene in characters, with styles over parts of it, as the
--- shell's output lines are.
export type Line = { text: string, marks: { greed.Mark } }

-- The braille dot for each place in a cell, by row then column.
local DOT = { { 0x01, 0x08 }, { 0x02, 0x10 }, { 0x04, 0x20 }, { 0x40, 0x80 } }

-- Eighth blocks: filled from the bottom, and from the left.
local LOWER = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
local LEFT = { "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█" }

-- What's drawn in each cell: braille dots, a block or a character of
-- text, and its style.
type Cell = { dots: number?, char: string?, style: string? }

-- A clip: cells outside x0 <= x < x1, y0 <= y < y1 are left alone.
type Clip = { number }

-- A grid of cells being drawn.
type Grid = { cols: number, rows: number, cells: { [number]: Cell } }

-- How much of the cell from `a` to `a + 1` the span from `lo` to `hi`
-- covers, from 0 to 1.
local function overlap(lo: number, hi: number, a: number): number
	return math.max(0, math.min(hi, a + 1) - math.max(lo, a))
end

-- Whether the point (`x`, `y`), in cells, is inside `clip`.
local function inside(clip: Clip, x: number, y: number): boolean
	return x >= clip[1] and x < clip[3] and y >= clip[2] and y < clip[4]
end

-- The cell at (`cx`, `cy`), made when it's first drawn in; nil off the grid.
local function cell(grid: Grid, cx: number, cy: number): Cell?
	if cx < 0 or cy < 0 or cx >= grid.cols or cy >= grid.rows then
		return nil
	end
	local i = cy * grid.cols + cx + 1
	local found = grid.cells[i]
	if found then
		return found
	end
	local made: Cell = {}
	grid.cells[i] = made
	return made
end

-- Puts braille dot (`px`, `py`), two across and four down a cell, in
-- `style`. A cell holding a block or text gives way to dots.
local function dot(grid: Grid, clip: Clip, px: number, py: number, style: string?)
	if not inside(clip, (px + 0.5) / 2, (py + 0.5) / 4) then
		return
	end
	local c = cell(grid, px // 2, py // 4)
	if c == nil then
		return
	end
	if c.dots == nil then
		c.dots, c.char = 0, nil
	end
	c.dots = bit32.bor(c.dots :: number, DOT[py % 4 + 1][px % 2 + 1])
	c.style = style
end

-- Puts `char` in cell (`cx`, `cy`) in `style`, in place of what's there.
local function put(grid: Grid, clip: Clip, cx: number, cy: number, char: string, style: string?)
	if not inside(clip, cx + 0.5, cy + 0.5) then
		return
	end
	local c = cell(grid, cx, cy)
	if c then
		c.dots, c.char, c.style = nil, char, style
	end
end

-- A line of dots from `a` to `b`, in cells.
local function segment(grid: Grid, clip: Clip, a: Point, b: Point, style: string?)
	local x0, y0 = math.floor(a[1] * 2), math.floor(a[2] * 4)
	local x1, y1 = math.floor(b[1] * 2), math.floor(b[2] * 4)
	local steps = math.max(math.abs(x1 - x0), math.abs(y1 - y0), 1)
	for s = 0, steps do
		local t = s / steps
		dot(
			grid,
			clip,
			math.floor(x0 + (x1 - x0) * t + 0.5),
			math.floor(y0 + (y1 - y0) * t + 0.5),
			style
		)
	end
end

-- Fills the box from (`x0`, `y0`) to (`x1`, `y1`) in `style`, with eighth
-- blocks where an edge falls inside a cell: a bar standing on the bottom
-- of a cell, or starting at the left of one.
local function fill(
	grid: Grid,
	clip: Clip,
	x0: number,
	y0: number,
	x1: number,
	y1: number,
	style: string?
)
	if x1 < x0 then
		x0, x1 = x1, x0
	end
	if y1 < y0 then
		y0, y1 = y1, y0
	end
	for cy = math.floor(y0), math.ceil(y1) - 1 do
		local tall = overlap(y0, y1, cy)
		-- A box at least half a row tall with room above and below it in
		-- its row fills the row, as a bar does.
		if tall >= 0.5 and y0 > cy + 0.01 and y1 < cy + 0.99 then
			tall = 1
		end
		for cx = math.floor(x0), math.ceil(x1) - 1 do
			local wide = overlap(x0, x1, cx)
			local char: string? = nil
			if wide > 0.9 and tall > 0.9 then
				char = "█"
			elseif wide > 0.9 then
				local eighths = math.floor(tall * 8 + 0.5)
				if eighths > 0 then
					-- Filled from the cell's bottom, or else from its top.
					char = if y1 >= cy + 0.99
						then LOWER[eighths]
						elseif tall >= 0.5 then "▀"
						else "▔"
				end
			elseif tall > 0.9 then
				local eighths = math.floor(wide * 8 + 0.5)
				if eighths > 0 then
					char = if x0 <= cx + 0.01
						then LEFT[eighths]
						elseif wide >= 0.5 then "▐"
						else "▕"
				end
			elseif wide * tall >= 0.5 then
				char = "█"
			end
			if char then
				put(grid, clip, cx, cy, char :: string, style)
			end
		end
	end
end

-- The y of the line through `points` (sorted by x) at `x`, or nil outside
-- them.
local function y_at(points: { Point }, x: number): number?
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		if x >= a[1] and x <= b[1] then
			local span = b[1] - a[1]
			return if span == 0 then a[2] else a[2] + (b[2] - a[2]) * (x - a[1]) / span
		end
	end
	return if #points == 1 and math.abs(points[1][1] - x) <= 0.5 then points[1][2] else nil
end

-- `clip` cut down to `other`, when there's one.
local function within(clip: Clip, other: { number }?): Clip
	if other == nil then
		return clip
	end
	return {
		math.max(clip[1], other[1]),
		math.max(clip[2], other[2]),
		math.min(clip[3], other[3]),
		math.min(clip[4], other[4]),
	}
end

-- Draws `item` into `grid`.
local function draw_item(grid: Grid, clip: Clip, item: Item)
	local kind = item.kind
	if kind == "line" then
		local points = item.points or {}
		for i = 1, #points - 1 do
			segment(grid, clip, points[i], points[i + 1], item.style)
		end
		if #points == 1 then
			segment(grid, clip, points[1], points[1], item.style)
		end
	elseif kind == "dots" then
		local points: { Point } = item.points or {}
		for _, p in points do
			local px, py = math.floor(p[1] * 2), math.floor(p[2] * 4)
			dot(grid, clip, px, py, item.style)
			if (item.weight or 1) >= 2 then
				dot(grid, clip, px + 1, py, item.style)
				dot(grid, clip, px, py + 1, item.style)
				dot(grid, clip, px + 1, py + 1, item.style)
			end
		end
	elseif kind == "rect" then
		local at, size = item.at or { 0, 0 }, item.size or { 0, 0 }
		local x0, y0, x1, y1 = at[1], at[2], at[1] + size[1], at[2] + size[2]
		if item.fill then
			fill(grid, clip, x0, y0, x1, y1, item.fill)
		end
		if item.style then
			local corners = { { x0, y0 }, { x1, y0 }, { x1, y1 }, { x0, y1 }, { x0, y0 } }
			for i = 1, 4 do
				segment(grid, clip, corners[i], corners[i + 1], item.style)
			end
		end
	elseif kind == "area" then
		local points = table.clone(item.points or {})
		table.sort(points, function(a: Point, b: Point): boolean
			return a[1] < b[1]
		end)
		local base = item.base or grid.rows
		if #points > 0 then
			for cx = math.floor(points[1][1]), math.ceil(points[#points][1]) - 1 do
				local top = y_at(points, cx + 0.5)
				if top then
					fill(grid, clip, cx, top, cx + 1, base, item.fill)
				end
			end
		end
	elseif kind == "text" then
		local text = item.text or ""
		local at = item.at or { 0, 0 }
		local width = greed.text.width(text)
		local x = at[1]
		if item.align == "middle" then
			x -= width / 2
		elseif item.align == "end" then
			x -= width
		end
		local cx, cy = math.floor(x + 0.5), math.floor(at[2])
		for _, code in utf8.codes(text) do
			put(grid, clip, cx, cy, utf8.char(code), item.style)
			cx += 1
		end
	elseif kind == "group" then
		local inner = within(clip, item.clip)
		local items: { Item } = item.items or {}
		for _, each in items do
			draw_item(grid, inner, each)
		end
	end
end

--- `spec` drawn in `cols` by `rows` character cells: a line each, with
--- the styles of what's in it. Spaces at a line's end are left off.
function M.cells(spec: Spec, wide: number, tall: number): { Line }
	local cols: number, rows: number = math.max(math.floor(wide), 1), math.max(math.floor(tall), 1)
	local grid: Grid = { cols = cols, rows = rows, cells = {} }
	for _, item in spec.items do
		draw_item(grid, { 0, 0, cols, rows }, item)
	end
	local lines: { Line } = {}
	for cy = 0, rows - 1 do
		local parts: { string } = {}
		local marks: { greed.Mark } = {}
		local pos = 0
		local last = 0
		for cx = 0, cols - 1 do
			local c = grid.cells[cy * cols + cx + 1]
			local char = " "
			if c and c.dots then
				char = utf8.char(0x2800 + c.dots)
			elseif c and c.char then
				char = c.char
			end
			local style = if c then c.style else nil
			if style and char ~= " " then
				local before = marks[#marks]
				if before and before.style == style and before.to == pos then
					before.to = pos + #char
				else
					table.insert(marks, { from = pos, to = pos + #char, style = style })
				end
			end
			table.insert(parts, char)
			pos += #char
			if char ~= " " then
				last = #parts
			end
		end
		table.insert(lines, { text = table.concat(parts, "", 1, last), marks = marks })
	end
	return lines
end

--- The text of `lines`, a line each.
function M.text(lines: { Line }): string
	local out: { string } = {}
	for _, line in lines do
		table.insert(out, line.text)
	end
	return table.concat(out, "\n")
end

return M
