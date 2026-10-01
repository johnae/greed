-- Text objects and surround, like Helix's match mode:
--
--   m i w / m a w   the word (a: with the space after it); W for WORDs
--   m i ( / m a (   inside or around the brackets; also [ { < and the
--                   closing brackets
--   m i " / m a "   inside or around the quotes; also ' and `
--   m s X           wrap each selection in X and its pair
--   m d X           take away the X pair around each selection
--   m r X Y         swap the X pair around each selection for Y's

local kern = require("@kern")
local motions = require("./motions")
local text = require("./text")

type Buffer = kern.Buffer
type Range = kern.Range

local OPEN = {
	["("] = "(",
	[")"] = "(",
	["["] = "[",
	["]"] = "[",
	["{"] = "{",
	["}"] = "{",
	["<"] = "<",
	[">"] = "<",
}
local CLOSE = { ["("] = ")", ["["] = "]", ["{"] = "}", ["<"] = ">" }
local QUOTES = { ['"'] = true, ["'"] = true, ["`"] = true }

-- The opening and closing characters for `char`: a bracket pair, or the
-- same character twice.
local function pair(char: string): (string, string)
	local open = OPEN[char]
	if open then
		return open, CLOSE[open]
	end
	return char, char
end

-- The bracket pair of kind `open` around `pos`: where the opener and closer
-- are, or nil.
local function brackets_around(buffer: Buffer, pos: number, open: string): (number?, number?)
	-- On the opener itself, that's the pair.
	if buffer:char_at(pos) == open then
		return pos, text.matching_bracket(buffer, pos)
	end
	local close = CLOSE[open]
	local depth, at = 0, pos
	while at > 0 do
		at = buffer:prev_char(at)
		local c = buffer:char_at(at)
		if c == close then
			depth += 1
		elseif c == open then
			if depth == 0 then
				return at, text.matching_bracket(buffer, at)
			end
			depth -= 1
		end
	end
	return nil, nil
end

-- The `quote` pair around `pos` on its line, or nil.
local function quotes_around(buffer: Buffer, pos: number, quote: string): (number?, number?)
	local line = buffer:line_of(pos)
	local start, stop = buffer:line_start(line), buffer:line_end(line)
	local found: { number } = {}
	local at = start
	while at < stop do
		if buffer:char_at(at) == quote then
			table.insert(found, at)
		end
		at = buffer:next_char(at)
	end
	-- Quotes pair up from the start of the line.
	for i = 1, #found - 1, 2 do
		if found[i] <= pos and pos <= found[i + 1] then
			return found[i], found[i + 1]
		end
	end
	return nil, nil
end

-- Where the pair for `char` around `pos` is, or nil.
local function around(buffer: Buffer, pos: number, char: string): (number?, number?)
	if QUOTES[char] then
		return quotes_around(buffer, pos, char)
	end
	return brackets_around(buffer, pos, OPEN[char] :: string)
end

-- The word (or WORD) under `pos`, and with `include_space`, the spaces after it
-- (or before it, at the end of a line).
local function word(buffer: Buffer, pos: number, big: boolean, include_space: boolean): Range
	local function kind(p: number): string?
		local class = text.class(buffer:char_at(p))
		return if big and class == "punct" then "word" else class
	end
	local class = kind(pos)
	local from, to = pos, pos
	while from > 0 and kind(buffer:prev_char(from)) == class do
		from = buffer:prev_char(from)
	end
	while to < buffer:len() and kind(to) == class do
		to = buffer:next_char(to)
	end
	if include_space then
		local after = to
		while after < buffer:len() and kind(after) == "space" do
			after = buffer:next_char(after)
		end
		if after > to then
			to = after
		else
			while from > 0 and kind(buffer:prev_char(from)) == "space" do
				from = buffer:prev_char(from)
			end
		end
	end
	return { anchor = from, head = to }
end

local function object(name: string, doc: string, pick: (Buffer, Range) -> Range?)
	kern.command({
		name = name,
		doc = doc,
		run = function(ctx)
			motions.each_range(ctx, function(buffer, range)
				return pick(buffer, range) or range
			end)
		end,
	})
end

local M = {}

-- Bindings for every object, filled in below.
M.keys = {} :: { [string]: string }

for _, big in { false, true } do
	local w = if big then "W" else "w"
	local what = if big then "WORD" else "word"
	for _, outer in { false, true } do
		local name = `select-{if outer then "around" else "inside"}-{string.lower(what)}`
		object(
			name,
			`Select the {what}{if outer then " and the space after it" else ""}`,
			function(buffer, range)
				return word(buffer, range.head, big, outer)
			end
		)
		M.keys[`m {if outer then "a" else "i"} {w}`] = name
	end
end

local NAMES: { [string]: string } = {
	["("] = "parens",
	["["] = "brackets",
	["{"] = "braces",
	["<"] = "angles",
	['"'] = "double-quotes",
	["'"] = "quotes",
	["`"] = "backticks",
}
for char, label in NAMES do
	for _, outer in { false, true } do
		local side = if outer then "around" else "inside"
		local name = `select-{side}-{label}`
		object(name, `Select {side} the {label}`, function(buffer, range)
			local from, to = around(buffer, range.head, char)
			if from == nil or to == nil then
				return nil
			end
			if outer then
				return { anchor = from, head = buffer:next_char(to) }
			end
			return { anchor = buffer:next_char(from), head = to }
		end)
		local key = if outer then "a" else "i"
		M.keys[`m {key} {char}`] = name
		if CLOSE[char] then
			M.keys[`m {key} {CLOSE[char]}`] = name
		end
	end
end

-- Reads a character to stand for a pair; nil for keys like esc.
local function pair_key(): string?
	local key = kern.next_key()
	return if utf8.len(key) == 1 then key else nil
end

kern.command({
	name = "surround-add",
	doc = "Wrap each selection in the pair of the next character typed",
	run = function(ctx)
		local char = pair_key()
		if char == nil then
			return
		end
		local open, close = pair(char)
		local selection = ctx.view:selection()
		ctx.buffer:edit(function(e)
			local shift = 0
			for i, range in selection.ranges do
				local from, to =
					math.min(range.anchor, range.head), math.max(range.anchor, range.head)
				e:insert(from, open)
				e:insert(to, close)
				selection.ranges[i] = { anchor = from + shift, head = to + shift + #open + #close }
				shift += #open + #close
			end
			e:select(selection)
		end)
	end,
})

-- Swaps the `char` pair around each selection's head for `open` and
-- `close`, once per pair.
local function replace_pairs(ctx: kern.Context, char: string, open: string, close: string)
	local buffer = ctx.buffer
	local found, seen = {}, {}
	for _, range in ctx.view:selection().ranges do
		local from, to = around(buffer, range.head, char)
		if from and to and not seen[from] then
			seen[from] = true
			table.insert(found, { from, to })
		end
	end
	buffer:edit(function(e)
		for _, p in found do
			e:replace(p[1], buffer:next_char(p[1]), open)
			e:replace(p[2], buffer:next_char(p[2]), close)
		end
	end)
end

kern.command({
	name = "surround-delete",
	doc = "Take away the pair of the next character typed from around each selection",
	run = function(ctx)
		local char = pair_key()
		if char == nil then
			return
		end
		replace_pairs(ctx, char, "", "")
	end,
})

kern.command({
	name = "surround-replace",
	doc = "Swap the pair of the next character typed around each selection for another's",
	run = function(ctx)
		local char = pair_key()
		local with = char and pair_key()
		if char == nil or with == nil then
			return
		end
		local open, close = pair(with)
		replace_pairs(ctx, char, open, close)
	end,
})

M.keys["m s"] = "surround-add"
M.keys["m d"] = "surround-delete"
M.keys["m r"] = "surround-replace"

return M
