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
--
-- `find` has every object by its key, paragraphs and sentences too, so
-- the other editing styles and plugins pick the same text.

local greed = require("@greed")
local motions = require("./motions")
local syntax = require("./syntax")
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
local function word(
	buffer: Buffer,
	pos: number,
	big: boolean,
	include_space: boolean
): (number, number)
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
	return from, to
end

-- Lines `first` to `last` whole, line break included, as `from, to`. With
-- `vim`, lines at the end of the buffer take the line break before them
-- instead, as Vim deletes them.
local function whole_lines(
	buffer: Buffer,
	first: number,
	last: number,
	vim: boolean?
): (number, number)
	local from = buffer:line_start(first)
	if last + 1 < buffer:line_count() then
		return from, buffer:line_start(last + 1)
	end
	if vim and from > 0 then
		from = buffer:prev_char(from)
	end
	return from, buffer:len()
end

local M = {}

--- Whether `line` is empty or only spaces.
function M.blank(buffer: Buffer, line: number): boolean
	return string.match(buffer:line_text(line), "^%s*$") ~= nil
end

local blank = M.blank

--- The first and last line of the paragraph around `line`, or of the run
--- of blank lines it's in. Lines of only spaces count as blank.
function M.paragraph(buffer: Buffer, line: number): (number, number)
	local is_blank = blank(buffer, line)
	local first, last = line, line
	while first > 0 and blank(buffer, first - 1) == is_blank do
		first -= 1
	end
	while last + 1 < buffer:line_count() and blank(buffer, last + 1) == is_blank do
		last += 1
	end
	return first, last
end

-- The range inside the pair from `from` to `to`, or with `outer`, around it.
local function pair_range(
	buffer: Buffer,
	from: number?,
	to: number?,
	outer: boolean
): (number?, number?)
	if from == nil or to == nil then
		return nil, nil
	end
	if outer then
		return from, buffer:next_char(to)
	end
	return buffer:next_char(from), to
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

local NAMES: { [string]: string } = {
	["("] = "parens",
	["["] = "brackets",
	["{"] = "braces",
	["<"] = "angles",
	['"'] = "double-quotes",
	["'"] = "quotes",
	["`"] = "backticks",
}

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

-- How far `line` is indented, or nil for a blank line.
local function indent_of(buffer: Buffer, line: number): number?
	local start, stop = buffer:line_start(line), buffer:line_end(line)
	local first = text.first_non_blank(buffer, start)
	return if first >= stop then nil else first - start
end

-- The first and last of the lines `M.indent` takes.
local function indented_lines(buffer: Buffer, pos: number, around: boolean): (number, number)
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
	return first, last
end

--- The lines around `pos`'s line indented at least as far as it, blank
--- lines inside included, as a range of whole lines; `around` takes the
--- line above too, like a block's header.
function M.indent(buffer: Buffer, pos: number, around: boolean): (number, number)
	local first, last = indented_lines(buffer, pos, around)
	return whole_lines(buffer, first, last)
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

-- The paragraph around `pos` (see `M.find`).
local function paragraph_object(
	buffer: Buffer,
	pos: number,
	around: boolean,
	vim: boolean?
): (number, number, boolean)
	local first, last = M.paragraph(buffer, buffer:line_of(pos))
	-- "a paragraph" takes the blank lines after it; Vim's, on blank lines,
	-- the paragraph after them.
	if around and last + 1 < buffer:line_count() and (vim or not blank(buffer, last)) then
		local _, next_last = M.paragraph(buffer, last + 1)
		last = next_last
	end
	if vim or around then
		local from, to = whole_lines(buffer, first, last, vim)
		return from, to, true
	end
	return buffer:line_start(first), buffer:line_end(last), false
end

-- The pair for the bracket or quote `char` around `pos` (see `M.find`).
local function pair_object(
	buffer: Buffer,
	pos: number,
	char: string,
	opts: FindOptions
): (number?, number?)
	local open, close = around(buffer, pos, char, opts.count)
	if open == nil and opts.vim and QUOTES[char] then
		-- Before the quotes on a line, Vim takes the next pair on it.
		local finish = buffer:line_end(buffer:line_of(pos))
		local at = pos
		while at < finish and buffer:char_at(at) ~= char do
			at = buffer:next_char(at)
		end
		if at < finish then
			open, close = quotes_around(buffer, at, char)
		end
	end
	return open, close
end

export type FindOptions = {
	--- Brackets further out: 2 is the pair around the nearest one.
	count: number?,
	--- For `n` and `l`, the bracket or quote; read from the keyboard when
	--- not given.
	char: string?,
	--- Vim's way where it differs: quotes after the cursor on its line
	--- count, a paragraph is whole lines (at the end of the buffer, with
	--- the line break before them), and "a paragraph" on blank lines takes
	--- the paragraph after them.
	vim: boolean?,
}

--- The text object for `key` around `pos`, inside it or `around` it, as
--- `from, to, linewise`, or nil when there's none. The keys: `w` and `W`
--- words (around: with the spaces after, or before at a line's end), `p`
--- a paragraph (around: with the blank lines after), `s` a sentence
--- (around: with the blanks after), a bracket or quote for its pair, `m`
--- the nearest pair, `n` and `l` the next and last pair of a bracket or
--- quote, `x` an XML element, `i` an indented block, `d` a number, and the
--- syntax tree's objects in `core.syntax.OBJECTS` (`f` a function, `a` an
--- argument, `c` a comment...).
function M.find(
	buffer: Buffer,
	pos: number,
	key: string,
	around: boolean,
	opts: FindOptions?
): (number?, number?, boolean)
	local o: FindOptions = opts or {}
	local from: number?, to: number? = nil, nil
	if key == "w" or key == "W" then
		from, to = word(buffer, pos, key == "W", around)
	elseif key == "p" then
		return paragraph_object(buffer, pos, around, o.vim)
	elseif key == "i" then
		local first, last = indented_lines(buffer, pos, around)
		local start, stop = whole_lines(buffer, first, last, o.vim)
		return start, stop, true
	elseif key == "s" then
		local start, stop = buffer:sentence(pos)
		while around and stop < buffer:len() and text.class(buffer:char_at(stop)) == "space" do
			stop = buffer:next_char(stop)
		end
		from, to = start, stop
	elseif key == "x" then
		from, to = M.tag(buffer, pos, around)
	elseif key == "d" then
		from, to = M.number(buffer, pos, around)
	elseif key == "m" then
		local open, close = nearest(buffer, pos, o.count)
		from, to = pair_range(buffer, open, close, around)
	elseif key == "n" or key == "l" then
		local char = o.char or pair_key()
		if char then
			local open, close = M.next_pair(buffer, pos, char, key == "l")
			from, to = pair_range(buffer, open, close, around)
		end
	elseif syntax.OBJECTS[key] then
		local range =
			syntax.select(buffer, { anchor = pos, head = pos }, syntax.OBJECTS[key], around)
		if range then
			from, to = range.anchor, range.head
		end
	elseif OPEN[key] or QUOTES[key] then
		local open, close = pair_object(buffer, pos, key, o)
		from, to = pair_range(buffer, open, close, around)
	end
	return from, to, false
end

--- What wraps text for the pair key `char`: a bracket and its partner, or
--- the character twice. With `spaced`, an opening bracket ( [ { puts a
--- space inside each side, as vim-surround does.
function M.pair(char: string, spaced: boolean?): (string, string)
	local open, close = pair(char)
	if spaced and char == open and open ~= "<" and CLOSE[open] then
		return open .. " ", " " .. close
	end
	return open, close
end

-- Bindings for every object, filled in below.
M.keys = {} :: { [string]: string }

-- Makes command `name` select object `key` (`outer`: around it) at each
-- selection, bound to m i or m a and `key`. With `reads`, it
-- reads the pair's character first.
local function object(name: string, doc: string, key: string, outer: boolean, reads: boolean?)
	greed.command({
		name = name,
		doc = doc,
		run = function(ctx)
			local char = if reads then pair_key() else nil
			if reads and char == nil then
				return
			end
			motions.each_range(ctx, function(buffer, range)
				local from, to = M.find(
					buffer,
					motions.cursor(buffer, range),
					key,
					outer,
					{ count = ctx.count, char = char }
				)
				return if from and to then { anchor = from, head = to } else range
			end)
		end,
	})
	M.keys[`m {if outer then "a" else "i"} {key}`] = name
end

for _, outer in { false, true } do
	local side = if outer then "around" else "inside"
	for _, big in { false, true } do
		local what = if big then "WORD" else "word"
		object(
			`select-{side}-{if big then "big-word" else "word"}`,
			`Select the {what}{if outer then " and the space after it" else ""}`,
			if big then "W" else "w",
			outer
		)
	end
	for char, label in NAMES do
		local name = `select-{side}-{label}`
		object(name, `Select {side} the {label}`, char, outer)
		if CLOSE[char] then
			M.keys[`m {if outer then "a" else "i"} {CLOSE[char]}`] = name
		end
	end
	object(`select-{side}-tag`, `Select {side} the XML or HTML element`, "x", outer)
	object(`select-{side}-pair`, `Select {side} the nearest brackets or quotes`, "m", outer)
	for _, back in { false, true } do
		local which = if back then "last" else "next"
		object(
			`select-{side}-{which}`,
			`Select {side} the {which} pair of the bracket or quote typed next`,
			if back then "l" else "n",
			outer,
			true
		)
	end
	object(
		`select-{side}-indent`,
		`Select the lines indented as far as this one{if outer then ", and the one above" else ""}`,
		"i",
		outer
	)
	object(
		`select-{side}-number`,
		`Select the number at or after the cursor{if outer then ", with its sign" else ""}`,
		"d",
		outer
	)
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
		motions.replace_each(ctx.view, function(_, range)
			return open .. ctx.buffer:slice(text.span(range)) .. close
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
