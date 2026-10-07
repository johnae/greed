-- Text objects and surround, like Helix's match mode:
--
--   m i w / m a w   the word (a: with the space after it); W for WORDs
--   m i ( / m a (   inside or around the brackets; also [ { < and the
--                   closing brackets
--   m i " / m a "   inside or around the quotes; also ' and `
--   m i n X / m i l X  inside the next or last X pair (m a: around)
--   m i i / m a i   the lines indented as far as this one (a: and the
--                   line above)
--   m i d / m a d   the number at or after the cursor (a: with its sign)
--   m s X           wrap each selection in X and its pair
--   m d X           take away the X pair around each selection
--   m r X Y         swap the X pair around each selection for Y's

local greed = require("@greed")
local motions = require("./motions")
local text = require("./text")

type Buffer = greed.Buffer
type Range = greed.Range

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
-- are, or nil. With `outside`, a pair opening at `pos` doesn't count.
local function brackets_around(
	buffer: Buffer,
	pos: number,
	open: string,
	outside: boolean?
): (number?, number?)
	-- On the opener itself, that's the pair.
	if not outside and buffer:char_at(pos) == open then
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

-- Where each `quote` is on `pos`'s line.
local function quotes_on_line(buffer: Buffer, pos: number, quote: string): { number }
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
	return found
end

-- The `quote` pair around `pos` on its line, or nil.
local function quotes_around(buffer: Buffer, pos: number, quote: string): (number?, number?)
	local found = quotes_on_line(buffer, pos, quote)
	-- Quotes pair up from the start of the line.
	for i = 1, #found - 1, 2 do
		if found[i] <= pos and pos <= found[i + 1] then
			return found[i], found[i + 1]
		end
	end
	return nil, nil
end

-- Where the pair for `char` around `pos` is, or nil. A count picks brackets
-- further out: 2 is the pair around the nearest one.
local function around(buffer: Buffer, pos: number, char: string, count: number?): (number?, number?)
	if QUOTES[char] then
		return quotes_around(buffer, pos, char)
	end
	local open = OPEN[char] :: string
	local from, to = brackets_around(buffer, pos, open)
	for _ = 2, count or 1 do
		if from == nil then
			break
		end
		from, to = brackets_around(buffer, from, open, true)
	end
	return from, to
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

local function object(name: string, doc: string, pick: (Buffer, Range, number?) -> Range?)
	greed.command({
		name = name,
		doc = doc,
		run = function(ctx)
			motions.each_range(ctx, function(buffer, range)
				return pick(buffer, range, ctx.count) or range
			end)
		end,
	})
end

-- The range inside the pair from `from` to `to`, or with `outer`, around it.
local function pair_range(buffer: Buffer, from: number?, to: number?, outer: boolean): Range?
	if from == nil or to == nil then
		return nil
	end
	if outer then
		return { anchor = from, head = buffer:next_char(to) }
	end
	return { anchor = buffer:next_char(from), head = to }
end

local M = {}

-- Bindings for every object, filled in below.
M.keys = {} :: { [string]: string }

for _, big in { false, true } do
	local w = if big then "W" else "w"
	local what = if big then "WORD" else "word"
	for _, outer in { false, true } do
		local name =
			`select-{if outer then "around" else "inside"}-{if big then "big-word" else "word"}`
		object(
			name,
			`Select the {what}{if outer then " and the space after it" else ""}`,
			function(buffer, range)
				return word(buffer, motions.cursor(buffer, range), big, outer)
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
		object(name, `Select {side} the {label}`, function(buffer, range, count)
			local from, to = around(buffer, motions.cursor(buffer, range), char, count)
			return pair_range(buffer, from, to, outer)
		end)
		local key = if outer then "a" else "i"
		M.keys[`m {key} {char}`] = name
		if CLOSE[char] then
			M.keys[`m {key} {CLOSE[char]}`] = name
		end
	end
end

--- The innermost XML or HTML element around `pos`: inside it (between its
--- tags) or around it (the tags too), as `from, to`, or nil.
function M.tag(buffer: Buffer, pos: number, around: boolean): (number?, number?)
	local tags: { { from: number, to: number } } = buffer:find_all("</?[A-Za-z][\\w:.-]*[^<>]*>")
		or {}
	local open: { { name: string, from: number, to: number } } = {}
	local best: { number }? = nil
	for _, tag in tags do
		local source = buffer:slice(tag.from, tag.to)
		local closing, name = string.match(source, "^<(/?)([%w:%.%-_]+)")
		if string.sub(source, -2) == "/>" or name == nil then
			continue
		elseif closing == "" then
			table.insert(open, { name = name, from = tag.from, to = tag.to })
			continue
		end
		-- A closing tag ends the latest open one of its name.
		for i = #open, 1, -1 do
			if open[i].name == name then
				local first = open[i]
				for _ = i, #open do
					table.remove(open)
				end
				if first.from <= pos and pos < tag.to and (best == nil or first.from > best[1]) then
					best = { first.from, first.to, tag.from, tag.to }
				end
				break
			end
		end
	end
	if best == nil then
		return nil, nil
	end
	if around then
		return best[1], best[4]
	end
	return best[2], best[3]
end

for _, outer in { false, true } do
	local side = if outer then "around" else "inside"
	object(`select-{side}-tag`, `Select {side} the XML or HTML element`, function(buffer, range)
		local from, to = M.tag(buffer, motions.cursor(buffer, range), outer)
		return if from and to then { anchor = from, head = to } else nil
	end)
	M.keys[`m {if outer then "a" else "i"} x`] = `select-{side}-tag`
end

-- The innermost pair of any kind around `pos`, as Helix's m i m finds it.
local function nearest(buffer: Buffer, pos: number, count: number?): (number?, number?)
	local best_from, best_to: number? = nil, nil
	for char in NAMES do
		local from, to = around(buffer, pos, char, count)
		if from and to and (best_from == nil or from > best_from) then
			best_from, best_to = from, to
		end
	end
	return best_from, best_to
end

for _, outer in { false, true } do
	local side = if outer then "around" else "inside"
	object(
		`select-{side}-pair`,
		`Select {side} the nearest brackets or quotes`,
		function(buffer, range, count)
			local from, to = nearest(buffer, motions.cursor(buffer, range), count)
			return pair_range(buffer, from, to, outer)
		end
	)
	M.keys[`m {if outer then "a" else "i"} m`] = `select-{side}-pair`
end

-- Reads a character to stand for a pair; nil for keys like esc.
local function pair_key(): string?
	local key = greed.next_key()
	return if utf8.len(key) == 1 then key else nil
end

--- The next pair for `char` that starts after `pos` (or, with `back`, the
--- last one that ends before it): the opener and closer, or nil. Quotes
--- look on `pos`'s line, brackets anywhere.
function M.next_pair(buffer: Buffer, pos: number, char: string, back: boolean): (number?, number?)
	local open, close = pair(char)
	if QUOTES[char] then
		local found = quotes_on_line(buffer, pos, char)
		local last_from, last_to: number? = nil, nil
		for i = 1, #found - 1, 2 do
			local a, b = found[i], found[i + 1]
			if not back and a > pos then
				return a, b
			elseif back and b < pos then
				last_from, last_to = a, b
			end
		end
		return last_from, last_to
	end
	local at = pos
	while true do
		if back then
			if at == 0 then
				return nil, nil
			end
			at = buffer:prev_char(at)
		else
			at = buffer:next_char(at)
			if at >= buffer:len() then
				return nil, nil
			end
		end
		local c = buffer:char_at(at)
		if not back and c == open then
			local to = text.matching_bracket(buffer, at)
			if to then
				return at, to
			end
		elseif back and c == close then
			local from = text.matching_bracket(buffer, at)
			if from then
				return from, at
			end
		end
	end
end

for _, outer in { false, true } do
	local side = if outer then "around" else "inside"
	for _, back in { false, true } do
		local which = if back then "last" else "next"
		local name = `select-{side}-{which}`
		greed.command({
			name = name,
			doc = `Select {side} the {which} pair of the bracket or quote typed next`,
			run = function(ctx)
				local char = pair_key()
				if char == nil then
					return
				end
				motions.each_range(ctx, function(buffer, range)
					local from, to = M.next_pair(buffer, motions.cursor(buffer, range), char, back)
					return pair_range(buffer, from, to, outer) or range
				end)
			end,
		})
		M.keys[`m {if outer then "a" else "i"} {if back then "l" else "n"}`] = name
	end
end

-- How far `line` is indented, or nil for a blank line.
local function indent_of(buffer: Buffer, line: number): number?
	local start, stop = buffer:line_start(line), buffer:line_end(line)
	local first = text.first_non_blank(buffer, start)
	return if first >= stop then nil else first - start
end

--- The lines around `pos`'s line indented at least as far as it, blank
--- lines inside included, as a range of whole lines; `around` takes the
--- line above too, like a block's header.
function M.indent(buffer: Buffer, pos: number, around: boolean): (number, number)
	local line = buffer:line_of(pos)
	local count = buffer:line_count()
	-- A blank line belongs with the next line that isn't.
	local base = indent_of(buffer, line)
	local probe = line
	while base == nil and probe + 1 < count do
		probe += 1
		base = indent_of(buffer, probe)
	end
	local depth = base or 0
	local function inside(l: number): boolean
		local found = indent_of(buffer, l)
		return found == nil or found >= depth
	end
	local first, last = line, line
	while first > 0 and inside(first - 1) do
		first -= 1
	end
	while last + 1 < count and inside(last + 1) do
		last += 1
	end
	-- Blank lines at the edges aren't part of it.
	while first < line and indent_of(buffer, first) == nil do
		first += 1
	end
	while last > line and indent_of(buffer, last) == nil do
		last -= 1
	end
	if around and first > 0 then
		first -= 1
	end
	local to = if last + 1 < count then buffer:line_start(last + 1) else buffer:line_end(last)
	return buffer:line_start(first), to
end

--- The number at or after `pos` on its line: decimal (with a fraction) or
--- hex; `around` takes its minus sign too. Nil when there's none.
function M.number(buffer: Buffer, pos: number, around: boolean): (number?, number?)
	local line = buffer:line_of(pos)
	local start, stop = buffer:line_start(line), buffer:line_end(line)
	local found: { { from: number, to: number } } = buffer:find_all(
		"-?(0[xX][0-9a-fA-F]+|[0-9]+(\\.[0-9]+)?)",
		start,
		stop
	) or {}
	for _, m in found do
		if m.to > pos then
			local from = m.from
			if not around and buffer:char_at(from) == "-" then
				from += 1
			end
			return from, m.to
		end
	end
	return nil, nil
end

for _, outer in { false, true } do
	local side = if outer then "around" else "inside"
	local key = if outer then "a" else "i"
	object(
		`select-{side}-indent`,
		`Select the lines indented as far as this one{if outer then ", and the one above" else ""}`,
		function(buffer, range)
			local from, to = M.indent(buffer, motions.cursor(buffer, range), outer)
			return { anchor = from, head = to }
		end
	)
	M.keys[`m {key} i`] = `select-{side}-indent`
	object(
		`select-{side}-number`,
		`Select the number at or after the cursor{if outer then ", with its sign" else ""}`,
		function(buffer, range)
			local from, to = M.number(buffer, motions.cursor(buffer, range), outer)
			return if from and to then { anchor = from, head = to } else nil
		end
	)
	M.keys[`m {key} d`] = `select-{side}-number`
end

greed.command({
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
				local from, to = text.span(range)
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
local function replace_pairs(ctx: greed.Context, char: string, open: string, close: string)
	local buffer = ctx.buffer
	local found, seen = {}, {}
	for _, range in ctx.view:selection().ranges do
		local from, to = around(buffer, motions.cursor(buffer, range), char)
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

greed.command({
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

greed.command({
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

--- Where the pair for `char` (a bracket or quote) around `pos` is: the
--- opener and the closer, or nil.
M.around = around

return M
