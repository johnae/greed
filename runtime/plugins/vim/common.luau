-- Text helpers the rest of the Vim style shares: character classes, where
-- the cursor is, and visual selections.

local greed = require("@greed")
local core = require("@core")

type Buffer = greed.Buffer

-- How a motion's range is taken: up to but not including the target, up
-- to and including it, or whole lines.
export type Kind = "exclusive" | "inclusive" | "line"

-- Where a motion goes from `pos`, done `count` times.
export type Motion = (buffer: Buffer, pos: number, count: number) -> (number?, Kind)

-- core's character classes, with the end of the buffer as a line end.
local function class(ch: string?): string
	return core.text.class(ch) or "eol"
end

local function is_blank(buffer: Buffer, pos: number): boolean
	local of = class(buffer:char_at(pos))
	return of == "space" or of == "eol"
end

local function line_bounds(buffer: Buffer, pos: number): (number, number, number)
	local line = buffer:line_of(pos)
	return line, buffer:line_start(line), buffer:line_end(line)
end

-- In normal mode the cursor sits on a character, so not past the last one.
local function on_char(buffer: Buffer, pos: number): number
	local _, start, finish = line_bounds(buffer, pos)
	if pos >= finish and finish > start then
		return buffer:prev_char(finish)
	end
	return math.min(pos, finish)
end

-- The character the cursor is on. In visual mode the selection includes it,
-- so going forward it's the selection's last character.
local function cursor(ctx: greed.Context): number
	local selection = ctx.view:selection()
	return core.motions.cursor(ctx.buffer, selection.ranges[selection.primary])
end

-- A visual selection from the character at `from` to the one at `to`, both
-- included, whichever way round.
local function visual(buffer: Buffer, from: number, to: number): greed.Selection
	local range = if to >= from
		then { anchor = from, head = buffer:next_char(to) }
		else { anchor = buffer:next_char(from), head = to }
	return { ranges = { range }, primary = 1 }
end

-- The character a visual selection started on.
local function visual_start(buffer: Buffer, range: greed.Range): number
	return if range.head > range.anchor or range.anchor == range.head
		then range.anchor
		else buffer:prev_char(range.anchor)
end

local function point(pos: number): greed.Selection
	return { ranges = { { anchor = pos, head = pos } }, primary = 1 }
end

-- Adds command "vim-`name`".
local function command(name: string, doc: string, run: (ctx: greed.Context) -> ())
	greed.command({ name = "vim-" .. name, doc = doc, run = run })
end

return {
	class = class,
	is_blank = is_blank,
	line_bounds = line_bounds,
	on_char = on_char,
	cursor = cursor,
	visual = visual,
	visual_start = visual_start,
	point = point,
	command = command,
}
