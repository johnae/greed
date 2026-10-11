-- Laying a board's cards out: side by side, in as many columns as the
-- board is wide enough for, each section starting a row of its own. A row
-- is as tall as its tallest card, and a card wider than one column takes
-- `span` of them, or the whole row with 0. Every line of a card is cut at
-- its width, so the board stays lined up however wide what it shows is.

local greed = require("@greed")
local core = require("@core")

local width_of, clip = core.text.width, core.text.clip

local M = {}

--- The spaces between two cards in a row.
M.GAP = 2

--- A card to lay out: its first line, whose first `title` bytes are its
--- title, the lines it shows, and a line saying how many more there are.
export type Piece = {
	head: string,
	title: number,
	lines: { string },
	more: string?,
	section: string?,
	--- How many columns it takes; 0 for the whole row.
	span: number,
}

--- Where a card is on a line of the board: the bytes from `from` to `to`.
export type Spot = { from: number, to: number, card: number }

--- A board laid out: its text, the styles over it, and the cards on each
--- line (0-based), left to right.
export type Laid = { text: string, marks: { greed.Mark }, at: { [number]: { Spot } } }

--- How many columns of cards at least `least` wide fit in `width`.
-- The narrowest a card is when a board says how many columns it has: a
-- narrower window has fewer.
local NARROWEST = 20

--- How many columns of cards at least `least` wide fit in `width`, or of
--- the board's own `fixed` number, as many of those as fit.
function M.columns(width: number, least: number, fixed: number?): number
	if fixed then
		return math.clamp((width + M.GAP) // (NARROWEST + M.GAP), 1, fixed)
	end
	return math.max(1, (width + M.GAP) // (least + M.GAP))
end

--- How wide a card taking `span` columns is on a board `width` wide,
--- with cards at least `least` wide.
function M.card_width(width: number, least: number, span: number, fixed: number?): number
	local columns = M.columns(width, least, fixed)
	local column = math.max((width - (columns - 1) * M.GAP) // columns, 1)
	local cards = if span <= 0 then columns else math.min(span, columns)
	return cards * column + (cards - 1) * M.GAP
end

-- A card in a row being laid out: how wide it is, and which card.
type Placed = { piece: Piece, width: number, card: number }

-- `text` cut to `width` and filled out to it with spaces.
local function fit(text: string, width: number): string
	local cut = clip(text, width)
	return cut .. string.rep(" ", width - width_of(cut))
end

-- The line `n` of `piece`, from 1, with its style: its head, the lines it
-- shows, then the line saying there's more.
local function line_of(piece: Piece, n: number): (string?, string?)
	if n == 1 then
		return piece.head, "markdown.heading"
	elseif n - 1 <= #piece.lines then
		return piece.lines[n - 1], nil
	elseif n == #piece.lines + 2 and piece.more then
		return piece.more, "shell.status"
	end
	return nil, nil
end

-- How many lines `piece` takes.
local function tall(piece: Piece): number
	return 1 + #piece.lines + (if piece.more then 1 else 0)
end

--- Lays out `pieces` under `title` in `width` columns of text, with cards
--- at least `least` wide.
function M.lay(
	title: string?,
	pieces: { Piece },
	width: number,
	least: number,
	fixed: number?
): Laid
	local columns = M.columns(width, least, fixed)
	local column = math.max((width - (columns - 1) * M.GAP) // columns, 1)
	local parts: { string } = {}
	local marks: { greed.Mark } = {}
	local at: { [number]: { Spot } } = {}
	local pos = 0
	local function add(text: string, style: string?)
		if style and text ~= "" then
			table.insert(marks, { from = pos, to = pos + #text, style = style })
		end
		table.insert(parts, text)
		pos += #text + 1
	end
	-- The cards in the row being filled, and how many columns they take.
	local row: { Placed } = {}
	local used = 0
	local function flush()
		if #row == 0 then
			return
		end
		local height = 0
		for _, placed in row do
			height = math.max(height, tall(placed.piece))
		end
		for n = 1, height do
			local line = ""
			local spots: { Spot } = {}
			for k, placed in row do
				if k > 1 then
					line ..= string.rep(" ", M.GAP)
				end
				local text, style = line_of(placed.piece, n)
				local from = #line
				if text and style then
					local shown = #clip(text, placed.width)
					local styled = if n == 1 then math.min(placed.piece.title, shown) else shown
					table.insert(
						marks,
						{ from = pos + from, to = pos + from + styled, style = style }
					)
				end
				line ..= fit(text or "", placed.width)
				table.insert(spots, { from = from, to = #line, card = placed.card })
			end
			at[#parts] = spots
			add((string.gsub(line, "%s+$", "")))
		end
		add("")
		row, used = {}, 0
	end
	if title then
		add(title, "markdown.heading.1")
		add("")
	end
	local section: string? = nil
	for i, piece in pieces do
		if piece.section ~= section then
			flush()
			section = piece.section
			if section then
				add(section, "markdown.heading.2")
				add("")
			end
		end
		local span = if piece.span <= 0 then columns else math.min(piece.span, columns)
		if used + span > columns then
			flush()
		end
		table.insert(row, { piece = piece, width = span * column + (span - 1) * M.GAP, card = i })
		used += span
	end
	flush()
	return { text = table.concat(parts, "\n"), marks = marks, at = at }
end

--- The card at byte `offset` of a line whose cards are `spots`: the one
--- it's on, or the nearest to its left in the space between two.
function M.card(spots: { Spot }?, offset: number): number?
	if spots == nil then
		return nil
	end
	local found: number? = nil
	for _, spot in spots do
		if offset >= spot.from then
			found = spot.card
		end
	end
	return found or (spots[1] and spots[1].card)
end

return M
