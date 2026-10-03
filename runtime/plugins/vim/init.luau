-- Vim-style editing, written only against the plugin API. It has modes of
-- its own (vim, vim-insert, vim-visual and vim-visual-line), so it sits
-- beside Helix's normal mode instead of replacing it, and borrows the
-- space-leader keys, ":", search, paging, the jumplist and the language
-- server keys from normal mode.
--
-- Switch to it with `:style vim`, or put this in ~/.config/kern/init.luau:
--
--     require("@kern").option.set("editing-style", "vim")
--
-- What's here: counts, h j k l w b e W B E ge gE 0 ^ $ g_ gg G f t F T ; , % { } ( )
-- H M L - + _ |, the operators
-- d c y > < gc g~ gu gU g? gq gw = ! with any of those motions or a text object (iw aW i( a"
-- ip it, and from the syntax tree if af ia ic) and doubled for whole lines
-- (dd >> gcc), x X D C s S, r ~ J, p P, i a I A o O, u ctrl-r, v V, * #,
-- q@ macros, "a registers, and . (core's) to repeat the last change.

local kern = require("@kern")
local core = require("@core")

type Buffer = kern.Buffer

-- How a motion's range is taken: up to but not including the target, up
-- to and including it, or whole lines.
type Kind = "exclusive" | "inclusive" | "line"

-- Where a motion goes from `pos`, done `count` times.
type Motion = (buffer: Buffer, pos: number, count: number) -> (number?, Kind)

-- What `y` and `d` last took, and whether it was whole lines.
local register = { text = "", linewise = false }
-- What "a y and the like put in named registers.
local named: { [string]: { text: string, linewise: boolean } } = {}

-- Text helpers -----------------------------------------------------------

local function class(ch: string?): string
	if ch == nil or ch == "\n" then
		return "eol"
	elseif ch == " " or ch == "\t" then
		return "space"
	elseif #ch > 1 or string.match(ch, "[%w_]") then
		return "word"
	end
	return "punct"
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

local function first_non_blank(buffer: Buffer, line: number): number
	local pos, finish = buffer:line_start(line), buffer:line_end(line)
	while pos < finish and class(buffer:char_at(pos)) == "space" do
		pos = buffer:next_char(pos)
	end
	return pos
end

-- The column of `pos` in characters, and the position `column` characters
-- into `line`, stopping at its end.
local function column_of(buffer: Buffer, pos: number): number
	local _, start = line_bounds(buffer, pos)
	local column = 0
	while start < pos do
		start = buffer:next_char(start)
		column += 1
	end
	return column
end

local function at_column(buffer: Buffer, line: number, column: number): number
	local pos, finish = buffer:line_start(line), buffer:line_end(line)
	for _ = 1, column do
		if pos >= finish then
			break
		end
		pos = buffer:next_char(pos)
	end
	return pos
end

-- The column j and k aim for, kept while moving through shorter lines.
local wanted: number? = nil

local function wanted_column(buffer: Buffer, pos: number): number
	local column = wanted or column_of(buffer, pos)
	wanted = column
	return column
end

-- Any command other than j and k forgets the column.
kern.on("command.run", function(event: kern.CommandRun)
	if event.name ~= "vim-motion-j" and event.name ~= "vim-motion-k" then
		wanted = nil
	end
end)

-- The character the cursor is on. In visual mode the selection includes it,
-- so going forward it's the selection's last character.
local function cursor(ctx: kern.Context): number
	local selection = ctx.view:selection()
	return core.motions.cursor(ctx.buffer, selection.ranges[selection.primary])
end

-- A visual selection from the character at `from` to the one at `to`, both
-- included, whichever way round.
local function visual(buffer: Buffer, from: number, to: number): kern.Selection
	local range = if to >= from
		then { anchor = from, head = buffer:next_char(to) }
		else { anchor = buffer:next_char(from), head = to }
	return { ranges = { range }, primary = 1 }
end

-- The character a visual selection started on.
local function visual_start(buffer: Buffer, range: kern.Range): number
	return if range.head > range.anchor or range.anchor == range.head
		then range.anchor
		else buffer:prev_char(range.anchor)
end

local function point(pos: number): kern.Selection
	return { ranges = { { anchor = pos, head = pos } }, primary = 1 }
end

-- Motions -----------------------------------------------------------------

-- `step` done `count` times, for WORDs with `big`.
local function repeat_step(step: (Buffer, number, boolean?) -> number?, big: boolean?): Motion
	return function(buffer, pos, count)
		for _ = 1, count do
			local next = step(buffer, pos, big)
			if next == nil then
				break
			end
			pos = next
		end
		return pos, "exclusive"
	end
end

-- A character's class for word motions; for WORDs (`big`), punctuation
-- counts as part of a word.
local function word_class(ch: string?, big: boolean?): string
	local of = class(ch)
	return if big and of == "punct" then "word" else of
end

-- Vim's w (W with `big`): past the rest of the word (or run of
-- punctuation), then past blanks and line breaks. An empty line counts as
-- a word, so it stops there.
local function next_word_start(buffer: Buffer, pos: number, big: boolean?): number?
	local len = buffer:len()
	if pos >= len then
		return nil
	end
	local from = word_class(buffer:char_at(pos), big)
	if from == "word" or from == "punct" then
		while pos < len and word_class(buffer:char_at(pos), big) == from do
			pos = buffer:next_char(pos)
		end
	end
	while pos < len do
		local of = class(buffer:char_at(pos))
		if of == "eol" then
			pos = buffer:next_char(pos)
			if pos < len and class(buffer:char_at(pos)) == "eol" then
				return pos
			end
		elseif of == "space" then
			pos = buffer:next_char(pos)
		else
			break
		end
	end
	return pos
end

-- Vim's b (B with `big`): back to the start of this word or the one before.
local function prev_word_start(buffer: Buffer, pos: number, big: boolean?): number?
	if pos == 0 then
		return nil
	end
	pos = buffer:prev_char(pos)
	while pos > 0 and is_blank(buffer, pos) do
		pos = buffer:prev_char(pos)
	end
	local of = word_class(buffer:char_at(pos), big)
	while pos > 0 and word_class(buffer:char_at(buffer:prev_char(pos)), big) == of do
		pos = buffer:prev_char(pos)
	end
	return pos
end

-- Vim's e (E with `big`): on to the end of this word or the next.
local function word_end(buffer: Buffer, pos: number, big: boolean?): number?
	local len = buffer:len()
	local next = buffer:next_char(pos)
	if next >= len then
		return nil
	end
	pos = next
	while pos < len and is_blank(buffer, pos) do
		pos = buffer:next_char(pos)
	end
	local of = word_class(buffer:char_at(pos), big)
	while
		buffer:next_char(pos) < len
		and word_class(buffer:char_at(buffer:next_char(pos)), big) == of
	do
		pos = buffer:next_char(pos)
	end
	return pos
end

-- Vim's ge (gE with `big`): back to the end of the word before.
local function prev_word_end(buffer: Buffer, pos: number, big: boolean?): number?
	if pos == 0 then
		return nil
	end
	local of = word_class(buffer:char_at(pos), big)
	-- Out of this word, then over blanks, to the last character of the one before.
	while
		pos > 0
		and word_class(buffer:char_at(pos), big) == of
		and of ~= "space"
		and of ~= "eol"
	do
		pos = buffer:prev_char(pos)
	end
	while pos > 0 and is_blank(buffer, pos) do
		pos = buffer:prev_char(pos)
	end
	return pos
end

-- The last f, t, F or T, for ; and , to do again.
local last_find: { forward: boolean, before: boolean, char: string }? = nil

-- Finds the `count`-th `char` on the line: forward or back, landing on it
-- or (`before`) next to it. Done again (`again`), t starts a character
-- further on, so ; moves on past a character it's already next to.
local function find_on_line(
	buffer: Buffer,
	pos: number,
	count: number,
	find: { forward: boolean, before: boolean, char: string },
	again: boolean?
): (number?, Kind)
	local forward, before = find.forward, find.before
	local _, start, finish = line_bounds(buffer, pos)
	local at = pos
	if again and before then
		at = if forward then buffer:next_char(at) elseif at > start then buffer:prev_char(at) else at
	end
	for _ = 1, count do
		repeat
			at = if forward
				then buffer:next_char(at)
				else (if at > start then buffer:prev_char(at) else -1)
		until at < 0 or at >= finish or buffer:char_at(at) == find.char
		if at < 0 or at >= finish then
			return nil, "inclusive"
		end
	end
	if before then
		at = if forward then buffer:prev_char(at) else buffer:next_char(at)
	end
	return at, if forward then "inclusive" else "exclusive"
end

-- f, t, F and T: the character to find comes next.
local function find_char(forward: boolean, before: boolean): Motion
	return function(buffer, pos, count)
		local find = { forward = forward, before = before, char = kern.next_key() }
		last_find = find
		return find_on_line(buffer, pos, count, find)
	end
end

-- ; and ,: the last f, t, F or T again, the same way or (`reverse`) back.
local function find_again(reverse: boolean): Motion
	return function(buffer, pos, count)
		local last = last_find
		if last == nil then
			return nil, "exclusive"
		end
		local find = { forward = last.forward ~= reverse, before = last.before, char = last.char }
		return find_on_line(buffer, pos, count, find, true)
	end
end

-- A linewise motion to the first non-blank of the line `delta(count)` lines away.
local function to_line(delta: (count: number) -> number): Motion
	return function(buffer, pos, count)
		local line = math.clamp(buffer:line_of(pos) + delta(count), 0, buffer:line_count() - 1)
		return first_non_blank(buffer, line), "line"
	end
end

-- { and }: the blank line before or after the paragraph, `count` times.
local function paragraph(forward: boolean): Motion
	return function(buffer, pos, count)
		local function blank(line: number): boolean
			return buffer:line_end(line) == buffer:line_start(line)
		end
		local last = buffer:line_count() - 1
		local line = buffer:line_of(pos)
		for _ = 1, count do
			local step = if forward then 1 else -1
			-- Past blank lines first, then to the next blank one.
			while line + step >= 0 and line + step <= last and blank(line + step) do
				line += step
			end
			repeat
				line += step
			until line <= 0 or line >= last or blank(line)
			line = math.clamp(line, 0, last)
		end
		if forward and line == last and not blank(line) then
			return buffer:line_end(line), "exclusive"
		end
		return buffer:line_start(line), "exclusive"
	end
end

-- ( and ): the start of the sentence before, or after, `count` times.
local function sentence(forward: boolean): Motion
	return function(buffer, pos, count)
		for _ = 1, count do
			local from, to = buffer:sentence(pos)
			if forward then
				-- Past this sentence's end and the spaces after it.
				local at = to
				while at < buffer:len() and is_blank(buffer, at) do
					at = buffer:next_char(at)
				end
				if at == pos then
					return pos, "exclusive"
				end
				pos = at
			elseif from < pos then
				pos = from
			elseif pos > 0 then
				local before = buffer:prev_char(pos)
				while before > 0 and is_blank(buffer, before) do
					before = buffer:prev_char(before)
				end
				pos = (buffer:sentence(before))
			end
		end
		return pos, "exclusive"
	end
end

-- H, M and L: a line on the screen, the `count`-th from the top or bottom
-- for H and L.
local function screen_line(where: "top" | "middle" | "bottom"): Motion
	return function(buffer, _, count)
		local first, last = kern.view():visible()
		local top, bottom = buffer:line_of(first), buffer:line_of(math.max(first, last - 1))
		local line = if where == "top"
			then math.min(top + count - 1, bottom)
			elseif where == "bottom" then math.max(bottom - count + 1, top)
			else (top + bottom) // 2
		return first_non_blank(buffer, line), "line"
	end
end

local motions: { [string]: Motion } = {
	h = function(buffer, pos, count)
		local _, start = line_bounds(buffer, pos)
		for _ = 1, count do
			if pos > start then
				pos = buffer:prev_char(pos)
			end
		end
		return pos, "exclusive"
	end,
	l = function(buffer, pos, count)
		local _, _, finish = line_bounds(buffer, pos)
		for _ = 1, count do
			if pos < finish then
				pos = buffer:next_char(pos)
			end
		end
		return pos, "exclusive"
	end,
	j = function(buffer, pos, count)
		local line = math.min(buffer:line_of(pos) + count, buffer:line_count() - 1)
		return at_column(buffer, line, wanted_column(buffer, pos)), "line"
	end,
	k = function(buffer, pos, count)
		local line = math.max(buffer:line_of(pos) - count, 0)
		return at_column(buffer, line, wanted_column(buffer, pos)), "line"
	end,
	w = repeat_step(next_word_start),
	b = repeat_step(prev_word_start),
	e = function(buffer, pos, count)
		local target = repeat_step(word_end)(buffer, pos, count)
		return target, "inclusive"
	end,
	W = repeat_step(next_word_start, true),
	B = repeat_step(prev_word_start, true),
	E = function(buffer, pos, count)
		return (repeat_step(word_end, true)(buffer, pos, count)), "inclusive"
	end,
	["g e"] = function(buffer, pos, count)
		return (repeat_step(prev_word_end)(buffer, pos, count)), "inclusive"
	end,
	["g E"] = function(buffer, pos, count)
		return (repeat_step(prev_word_end, true)(buffer, pos, count)), "inclusive"
	end,
	[";"] = find_again(false),
	[","] = find_again(true),
	["}"] = paragraph(true),
	["{"] = paragraph(false),
	[")"] = sentence(true),
	["("] = sentence(false),
	H = screen_line("top"),
	M = screen_line("middle"),
	L = screen_line("bottom"),
	["-"] = to_line(function(count)
		return -count
	end),
	["+"] = to_line(function(count)
		return count
	end),
	["_"] = to_line(function(count)
		return count - 1
	end),
	["|"] = function(buffer, pos, count)
		return at_column(buffer, buffer:line_of(pos), count - 1), "exclusive"
	end,
	["g _"] = function(buffer, pos, count)
		local line = math.min(buffer:line_of(pos) + count - 1, buffer:line_count() - 1)
		local at, start = buffer:line_end(line), buffer:line_start(line)
		while at > start and is_blank(buffer, buffer:prev_char(at)) do
			at = buffer:prev_char(at)
		end
		return if at > start then buffer:prev_char(at) else start, "inclusive"
	end,
	["0"] = function(buffer, pos)
		local _, start = line_bounds(buffer, pos)
		return start, "exclusive"
	end,
	["^"] = function(buffer, pos)
		return first_non_blank(buffer, buffer:line_of(pos)), "exclusive"
	end,
	["$"] = function(buffer, pos, count)
		-- With a count, the end of the line count - 1 lines down.
		local line = math.min(buffer:line_of(pos) + count - 1, buffer:line_count() - 1)
		local start, finish = buffer:line_start(line), buffer:line_end(line)
		return if finish > start then buffer:prev_char(finish) else start, "inclusive"
	end,
	f = find_char(true, false),
	t = find_char(true, true),
	F = find_char(false, false),
	T = find_char(false, true),
}

-- G goes to line `count`, or the last line; gg to line `count`, or the first.
local function goto_line(first: boolean): Motion
	return function(buffer, _, count)
		local last = buffer:line_count() - 1
		local line = if count > 0 then math.min(count - 1, last) elseif first then 0 else last
		return first_non_blank(buffer, line), "line"
	end
end
motions.G = goto_line(false)
motions["g g"] = goto_line(true)
-- % goes to the matching bracket, or with a count, that percentage of the way
-- down the file.
motions["%"] = function(buffer: Buffer, pos: number, count: number): (number?, Kind)
	if count > 0 then
		local line =
			math.clamp((count * buffer:line_count() + 99) // 100 - 1, 0, buffer:line_count() - 1)
		return first_non_blank(buffer, line), "line"
	end
	return core.text.matching_bracket(buffer, pos), "inclusive"
end

-- Motions whose count, left out, is 0 rather than 1: G and % act
-- differently without one.
local COUNTLESS: { [string]: boolean } = { G = true, ["%"] = true }

-- Ranges ------------------------------------------------------------------

-- The text a motion covers from `pos`, as `from, to, linewise`.
local function motion_range(
	buffer: Buffer,
	pos: number,
	target: number,
	kind: Kind
): (number, number, boolean)
	local from, to = math.min(pos, target), math.max(pos, target)
	if kind == "inclusive" then
		to = math.min(buffer:next_char(to), buffer:len())
	elseif kind == "line" then
		local last = buffer:line_of(to)
		from = buffer:line_start(buffer:line_of(from))
		if last + 1 < buffer:line_count() then
			to = buffer:line_start(last + 1)
		else
			-- Deleting the last lines takes the line break before them instead.
			to = buffer:len()
			if from > 0 then
				from = buffer:prev_char(from)
			end
		end
		return from, to, true
	end
	return from, to, false
end

-- The word around `pos`, with the spaces after it for "a word". A WORD
-- (`big`) takes punctuation in too.
local function word_object(
	buffer: Buffer,
	pos: number,
	around: boolean,
	big: boolean?
): (number, number)
	local function kind(p: number): string
		local of = class(buffer:char_at(p))
		return if big and of == "punct" then "word" else of
	end
	local of = kind(pos)
	local from, to = pos, pos
	while from > 0 and kind(buffer:prev_char(from)) == of do
		from = buffer:prev_char(from)
	end
	local len = buffer:len()
	while to < len and kind(to) == of do
		to = buffer:next_char(to)
	end
	if around then
		while to < len and class(buffer:char_at(to)) == "space" do
			to = buffer:next_char(to)
		end
	end
	return from, to
end

-- The lines of the paragraph around `pos`, and for "a paragraph" the blank
-- lines after it, as `from, to` for a linewise range.
local function paragraph_object(buffer: Buffer, pos: number, around: boolean): (number, number)
	local function blank(line: number): boolean
		return buffer:line_end(line) == buffer:line_start(line)
	end
	local last_line = buffer:line_count() - 1
	local line = buffer:line_of(pos)
	local is_blank = blank(line)
	local first, last = line, line
	while first > 0 and blank(first - 1) == is_blank do
		first -= 1
	end
	while last < last_line and blank(last + 1) == is_blank do
		last += 1
	end
	if around then
		while last < last_line and blank(last + 1) ~= is_blank do
			last += 1
		end
	end
	return buffer:line_start(first), buffer:line_start(last)
end

local BRACKETS = { b = "(", B = "{" }

-- Objects from the syntax tree: functions, arguments and comments (`t` is
-- left out, since Vim users expect a tag there).
local SYNTAX_OBJECTS = { f = "function", a = "parameter", c = "comment" }

-- The text object for `key` around `pos` ("w", "(", '"', "p", ...), inside
-- it or around it: `from, to, linewise`, or nil.
local function text_object(
	buffer: Buffer,
	pos: number,
	key: string,
	around: boolean
): (number?, number?, boolean)
	if key == "w" or key == "W" then
		local from, to = word_object(buffer, pos, around, key == "W")
		return from, to, false
	elseif key == "p" then
		local first, last = paragraph_object(buffer, pos, around)
		return motion_range(buffer, first, last, "line")
	elseif SYNTAX_OBJECTS[key] then
		local range =
			core.syntax.select(buffer, { anchor = pos, head = pos }, SYNTAX_OBJECTS[key], around)
		if range == nil then
			return nil, nil, false
		end
		return range.anchor, range.head, false
	end
	if key == "t" then
		local from, to = core.objects.tag(buffer, pos, around)
		return from, to, false
	end
	local open, close = core.objects.around(buffer, pos, BRACKETS[key] or key)
	if open == nil and (key == '"' or key == "'" or key == "`") then
		-- Before the quotes on a line, Vim takes the next pair on it.
		local _, _, finish = line_bounds(buffer, pos)
		local at = pos
		while at < finish and buffer:char_at(at) ~= key do
			at = buffer:next_char(at)
		end
		if at < finish then
			open, close = core.objects.around(buffer, at, key)
		end
	end
	if open == nil or close == nil then
		return nil, nil, false
	end
	local first, last = open :: number, close :: number
	if around then
		return first, buffer:next_char(last), false
	end
	return buffer:next_char(first), last, false
end

-- Operators ---------------------------------------------------------------

local function enter_insert(ctx: kern.Context, pos: number)
	ctx.view:set_selection(point(pos))
	kern.mode.set("vim-insert")
end

-- Operators that work on whole lines through core's commands.
local LINE_OPERATORS: { [string]: string } = {
	[">"] = "indent",
	["<"] = "dedent",
	["gc"] = "toggle-comment",
	["gq"] = "reflow",
	["gw"] = "reflow",
	["="] = "reindent-lines",
	["!"] = "pipe",
}

-- Operators that rewrite the text they cover, character by character.
local CASE_OPERATORS: { [string]: (string) -> string } = {
	["g~"] = function(text)
		return (
			string.gsub(text, "%a", function(c)
				return if string.match(c, "%l") then string.upper(c) else string.lower(c)
			end)
		)
	end,
	gu = string.lower,
	gU = string.upper,
	["g?"] = function(text)
		return (
			string.gsub(text, "%a", function(c)
				local base = if string.match(c, "%l") then 97 else 65
				return string.char((string.byte(c) - base + 13) % 26 + base)
			end)
		)
	end,
}

-- Runs core's `command` on the lines `from`..`to` touch, keeping the cursor
-- on the same character (or the line's first, for indents).
local function on_lines(ctx: kern.Context, command: string, from: number, to: number, op: string?)
	local buffer = ctx.buffer
	-- A linewise range at the end of the buffer starts with the break before it.
	if from < to and buffer:char_at(from) == "\n" then
		from += 1
	end
	local first, last = buffer:line_of(from), buffer:line_of(math.max(to - 1, from))
	local at = cursor(ctx)
	local line = buffer:line_of(at)
	local before = buffer:line_end(line) - buffer:line_start(line)
	ctx.view:set_selection({
		ranges = { { anchor = buffer:line_start(first), head = buffer:line_end(last) } },
		primary = 1,
	})
	kern.run(command)
	local grew = buffer:line_end(line) - buffer:line_start(line) - before
	if command == "toggle-comment" then
		at = math.clamp(at + grew, buffer:line_start(line), buffer:line_end(line))
	elseif op == "gw" then
		-- gw leaves the cursor where it was.
		at = math.min(at, buffer:len())
	else
		at = first_non_blank(buffer, math.min(first, buffer:line_count() - 1))
	end
	ctx.view:set_selection(point(on_char(buffer, at)))
end

-- Applies operator `op` (one of "d", "c", "y" or LINE_OPERATORS) to `from`..`to`.
local function apply(ctx: kern.Context, op: string, from: number, to: number, linewise: boolean)
	local buffer = ctx.buffer
	local line_command = LINE_OPERATORS[op]
	if line_command then
		on_lines(ctx, line_command, from, to, op)
		return
	end
	local case = CASE_OPERATORS[op]
	if case then
		local start, finish = from, to :: number
		local new = case(buffer:slice(start, finish))
		buffer:edit(function(e)
			e:replace(start, finish, new)
		end)
		ctx.view:set_selection(point(on_char(buffer, from)))
		return
	end
	local taken = { text = buffer:slice(from, to), linewise = linewise }
	-- Into the register picked with ", or the unnamed one and the clipboard.
	-- "_ keeps nothing, and an uppercase letter adds to its lowercase one.
	local name = core.registers.take()
	if name and string.match(name, "^%u$") then
		name = string.lower(name)
		local before = named[name]
		if before then
			taken = { text = before.text .. taken.text, linewise = before.linewise or linewise }
		end
	end
	-- Keeps `value` in register `into`, for p and for ctrl-r while typing.
	local function keep(into: string, value: { text: string, linewise: boolean })
		named[into] = value
		core.registers.set(into, { value.text })
	end
	if name == nil or name == "+" or name == "*" then
		register = taken
		kern.clipboard.set(taken.text)
		-- The numbered registers, as Vim keeps them: "0 the last yank, "1 to
		-- "9 the last deletes of lines (older ones moving down), "- the last
		-- smaller delete.
		if op == "y" then
			keep("0", taken)
		elseif linewise or string.find(taken.text, "\n", 1, true) then
			for n = 9, 2, -1 do
				local older = named[tostring(n - 1)]
				if older then
					keep(tostring(n), older)
				end
			end
			keep("1", taken)
		else
			keep("-", taken)
		end
	elseif name ~= "_" then
		keep(name, taken)
	end
	if op == "y" then
		-- Whole lines at the end start with the line break before them.
		local at = if linewise
				and to == buffer:len()
				and buffer:char_at(from) == "\n"
			then from + 1
			else from
		ctx.view:set_selection(point(on_char(buffer, at)))
		return
	end
	if op == "c" then
		kern.history.start_group()
		if linewise then
			-- Changing lines keeps one empty line to type on.
			local first = buffer:line_of(
				if from > 0 and buffer:char_at(from) == "\n" then buffer:next_char(from) else from
			)
			from, to =
				buffer:line_start(first), buffer:line_end(buffer:line_of(math.max(to - 1, from)))
		end
	end
	local start, finish = from, to :: number
	buffer:edit(function(e)
		e:delete(start, finish)
		e:select(point(start))
	end)
	if op == "c" then
		enter_insert(ctx, from)
	elseif linewise then
		ctx.view:set_selection(
			point(first_non_blank(buffer, buffer:line_of(math.min(from, buffer:len()))))
		)
	else
		ctx.view:set_selection(point(on_char(buffer, from)))
	end
end

-- Reads digits as a count, then returns the key after them and the count.
local function read_count(): (string, number?)
	local key = kern.next_key()
	local count: number? = nil
	while string.match(key, "^%d$") and (count or key ~= "0") do
		count = (count or 0) * 10 + (tonumber(key) :: number)
		key = kern.next_key()
	end
	return key, count
end

-- Runs operator `op` with the motion or object typed after it.
local function operate(ctx: kern.Context, op: string)
	local key, inner_count = read_count()
	local count = (ctx.count or 1) * (inner_count or 1)
	local buffer, pos = ctx.buffer, cursor(ctx)
	local from: number, to: number, linewise: boolean
	-- The operator's last key again (dd, >>, gcc) means whole lines.
	if key == string.sub(op, -1) then
		local line = buffer:line_of(pos)
		from, to, linewise = motion_range(
			buffer,
			pos,
			buffer:line_start(math.min(line + count - 1, buffer:line_count() - 1)),
			"line"
		)
	elseif key == "i" or key == "a" then
		local found_from, found_to, object_linewise =
			text_object(buffer, pos, kern.next_key(), key == "a")
		if found_from == nil or found_to == nil then
			return
		end
		from, to, linewise = found_from, found_to, object_linewise
	else
		if key == "g" then
			key = "g " .. kern.next_key()
		end
		local motion = motions[key]
		if motion == nil then
			return
		end
		local target, kind = motion(
			buffer,
			pos,
			if inner_count or ctx.count then count else (if COUNTLESS[key] then 0 else 1)
		)
		if target == nil then
			return
		end
		local big = key == "W"
		local of = word_class(buffer:char_at(pos), big)
		if (key == "w" or big) and op == "c" and (of == "word" or of == "punct") then
			-- "cw" changes to the end of the word, even from its last character.
			target, kind = pos, "inclusive"
			while word_class(buffer:char_at(buffer:next_char(target)), big) == of do
				target = buffer:next_char(target)
			end
			for _ = 2, count do
				target = word_end(buffer, target, big) or target
			end
		elseif key == "w" or big then
			-- When the last word moved over ends a line, the operator stops at
			-- the line's end rather than taking the line break too.
			local before = if count > 1 then motion(buffer, pos, count - 1) or pos else pos
			local line = buffer:line_of(before)
			if buffer:line_of(target) > line then
				target = buffer:line_end(line)
			end
		end
		from, to, linewise = motion_range(buffer, pos, target, kind)
	end
	apply(ctx, op, from, to, linewise)
end

-- Commands ----------------------------------------------------------------

local function command(name: string, doc: string, run: (ctx: kern.Context) -> ())
	kern.command({ name = "vim-" .. name, doc = doc, run = run })
end

-- The line V started on, which stays selected as other lines are added.
local visual_line = 0

-- Every line from `from` to `to`, whichever way round, as a selection.
local function lines_selection(buffer: Buffer, from: number, to: number): kern.Selection
	local range = if to >= from
		then { anchor = buffer:line_start(from), head = buffer:line_end(to) }
		else { anchor = buffer:line_end(from), head = buffer:line_start(to) }
	return { ranges = { range }, primary = 1 }
end

-- Motions move the cursor, or extend the selection in visual mode.
for key, motion in motions do
	command("motion-" .. string.gsub(key, " ", ""), "Vim motion " .. key, function(ctx)
		local selection = ctx.view:selection()
		local range = selection.ranges[selection.primary]
		local target =
			motion(ctx.buffer, cursor(ctx), ctx.count or (if COUNTLESS[key] then 0 else 1))
		if target == nil then
			return
		end
		local mode = kern.mode.get()
		if mode == "vim-visual-line" then
			ctx.view:set_selection(
				lines_selection(ctx.buffer, visual_line, ctx.buffer:line_of(target))
			)
		elseif mode == "vim-visual" then
			ctx.view:set_selection(visual(ctx.buffer, visual_start(ctx.buffer, range), target))
		else
			ctx.view:set_selection(point(on_char(ctx.buffer, target)))
		end
	end)
end

for _, op in { "d", "c", "y", ">", "<", "gc", "g~", "gu", "gU", "g?", "gq", "gw", "=", "!" } do
	command("operator-" .. op, "Vim operator " .. op .. ", followed by a motion", function(ctx)
		local mode = kern.mode.get()
		if mode == "vim-visual" or mode == "vim-visual-line" then
			local range = ctx.view:selection().ranges[1]
			local from, to = math.min(range.anchor, range.head), math.max(range.anchor, range.head)
			kern.mode.set("vim")
			if mode == "vim-visual-line" then
				apply(ctx, op, motion_range(ctx.buffer, from, to, "line"))
			else
				-- The selection already includes the cursor's character.
				apply(
					ctx,
					op,
					from,
					math.max(to, math.min(ctx.buffer:next_char(from), ctx.buffer:len())),
					false
				)
			end
			return
		end
		operate(ctx, op)
	end)
end

-- Shorthands for an operator and a motion: x is dl, D is d$, and so on.
local function shorthand(name: string, op: string, key: string, doc: string)
	command(name, doc, function(ctx)
		local buffer, pos = ctx.buffer, cursor(ctx)
		local target, kind = motions[key](buffer, pos, ctx.count or 1)
		if target == nil or (target == pos and kind == "exclusive") then
			return
		end
		apply(ctx, op, motion_range(buffer, pos, target :: number, kind))
	end)
end
shorthand("delete-char", "d", "l", "Delete the character under the cursor")
shorthand("delete-char-before", "d", "h", "Delete the character before the cursor")
shorthand("delete-to-end", "d", "$", "Delete to the end of the line")
shorthand("change-to-end", "c", "$", "Change to the end of the line")
shorthand("substitute", "c", "l", "Change the character under the cursor")

command("change-line", "Change the whole line", function(ctx)
	local buffer, pos = ctx.buffer, cursor(ctx)
	local line = buffer:line_of(pos)
	kern.history.start_group()
	local from, to = first_non_blank(buffer, line), buffer:line_end(line)
	buffer:edit(function(e)
		e:delete(from, to)
	end)
	enter_insert(ctx, from)
end)

-- What the unnamed register holds: the last yank or delete, unless
-- something newer was copied since, in another program or another style.
local function unnamed(): { text: string, linewise: boolean }
	local pieces = kern.clipboard.get()
	local text = if pieces then table.concat(pieces, "\n") else nil
	if text and text ~= register.text then
		return { text = text, linewise = string.sub(text, -1) == "\n" }
	end
	return register
end

local function paste(ctx: kern.Context, after: boolean)
	local name = core.registers.take()
	local from = unnamed()
	if name == "_" then
		return
	elseif name and name ~= "+" and name ~= "*" then
		name = string.lower(name)
		-- Text another style copied into it has no line information.
		local pieces = core.registers.get(name)
		from = named[name]
			or (pieces and { text = table.concat(pieces, "\n"), linewise = false })
			or { text = "", linewise = false }
	end
	local buffer, pos = ctx.buffer, cursor(ctx)
	local text = string.rep(from.text, ctx.count or 1)
	local at: number
	if from.linewise then
		local line = buffer:line_of(pos)
		if after then
			at = if line + 1 < buffer:line_count()
				then buffer:line_start(line + 1)
				else buffer:len()
			if
				at == buffer:len()
				and string.sub(text, -1) == "\n"
				and buffer:char_at(at - 1) ~= "\n"
			then
				text = "\n" .. string.sub(text, 1, -2)
			end
		else
			at = buffer:line_start(line)
		end
	else
		at = if after
			then math.min(buffer:next_char(pos), buffer:line_end(buffer:line_of(pos)))
			else pos
	end
	buffer:edit(function(e)
		e:insert(at, text)
	end)
	if from.linewise then
		ctx.view:set_selection(
			point(
				first_non_blank(
					buffer,
					buffer:line_of(if string.sub(text, 1, 1) == "\n" then at + 1 else at)
				)
			)
		)
	else
		ctx.view:set_selection(point(buffer:prev_char(at + #text)))
	end
end

command("paste-after", "Paste after the cursor, or below the line", function(ctx)
	paste(ctx, true)
end)
command("paste-before", "Paste before the cursor, or above the line", function(ctx)
	paste(ctx, false)
end)

command("insert", "Insert before the cursor", function(ctx)
	kern.history.start_group()
	enter_insert(ctx, cursor(ctx))
end)
command("append", "Insert after the cursor", function(ctx)
	kern.history.start_group()
	local buffer, pos = ctx.buffer, cursor(ctx)
	enter_insert(ctx, math.min(buffer:next_char(pos), buffer:line_end(buffer:line_of(pos))))
end)
command("insert-line-start", "Insert at the first non-blank of the line", function(ctx)
	kern.history.start_group()
	enter_insert(ctx, first_non_blank(ctx.buffer, ctx.buffer:line_of(cursor(ctx))))
end)
command("append-line-end", "Insert at the end of the line", function(ctx)
	kern.history.start_group()
	enter_insert(ctx, ctx.buffer:line_end(ctx.buffer:line_of(cursor(ctx))))
end)

local function open_line(ctx: kern.Context, below: boolean)
	kern.history.start_group()
	core.indent.open(ctx.view, below)
	enter_insert(ctx, cursor(ctx))
end
command("open-below", "Open a line below and insert", function(ctx)
	open_line(ctx, true)
end)
command("open-above", "Open a line above and insert", function(ctx)
	open_line(ctx, false)
end)

command("normal", "Back to normal mode", function(ctx)
	kern.history.end_group()
	local was_insert = kern.mode.get() == "vim-insert"
	kern.mode.set("vim")
	local buffer, pos = ctx.buffer, cursor(ctx)
	local _, start = line_bounds(buffer, pos)
	-- Leaving insert mode steps back onto the last character typed.
	if was_insert and pos > start then
		pos = buffer:prev_char(pos)
	end
	ctx.view:set_selection(point(on_char(buffer, pos)))
end)

command("visual", "Select characters, starting here", function(ctx)
	local at = cursor(ctx)
	ctx.view:set_selection(visual(ctx.buffer, at, at))
	kern.mode.set("vim-visual")
end)

-- The register the last macro played from, for @@.
local last_macro: string? = nil

command("macro", "Record a macro into the register typed next, or stop recording", function(ctx)
	if core.registers.recording() then
		core.registers.toggle_recording("", ctx.keys)
		return
	end
	local name = kern.next_key()
	if utf8.len(name) == 1 then
		core.registers.toggle_recording(name)
	end
end)

command(
	"play-macro",
	"Play the macro in the register typed next; @@ plays the last one again",
	function(ctx)
		local name = kern.next_key()
		if name == "@" then
			name = last_macro or ""
		end
		if utf8.len(name) ~= 1 then
			return
		end
		last_macro = name
		core.registers.play(name, ctx.count)
	end
)

command("visual-line", "Select whole lines, starting with this one", function(ctx)
	visual_line = ctx.buffer:line_of(cursor(ctx))
	ctx.view:set_selection(lines_selection(ctx.buffer, visual_line, visual_line))
	kern.mode.set("vim-visual-line")
end)

-- In visual mode, i and a select a text object: v i w, v a (.
for _, around in { false, true } do
	local word = if around then "around" else "inside"
	command(`visual-{word}`, `Select {word} the text object typed next`, function(ctx)
		local from, to = text_object(ctx.buffer, cursor(ctx), kern.next_key(), around)
		if from and to then
			ctx.view:set_selection({ ranges = { { anchor = from, head = to } }, primary = 1 })
		end
	end)
end

command(
	"replace-char",
	"Replace the character under the cursor with the next one typed",
	function(ctx)
		local char = kern.next_key()
		if utf8.len(char) ~= 1 then
			return
		end
		local buffer, pos = ctx.buffer, cursor(ctx)
		local count = ctx.count or 1
		local _, _, finish = line_bounds(buffer, pos)
		local to = pos
		for _ = 1, count do
			if to >= finish then
				return
			end
			to = buffer:next_char(to)
		end
		buffer:edit(function(e)
			e:replace(pos, to, string.rep(char, count))
		end)
		ctx.view:set_selection(point(pos + (count - 1) * #char))
	end
)

command(
	"switch-case",
	"Switch the case of the character under the cursor and move on",
	function(ctx)
		local buffer, pos = ctx.buffer, cursor(ctx)
		local _, _, finish = line_bounds(buffer, pos)
		local stop = pos
		for _ = 1, ctx.count or 1 do
			if stop < finish then
				stop = buffer:next_char(stop)
			end
		end
		-- One edit, so it undoes in one step.
		local swapped = string.gsub(buffer:slice(pos, stop), "%a", function(c)
			return if string.match(c, "%l") then string.upper(c) else string.lower(c)
		end)
		buffer:edit(function(e)
			e:replace(pos, stop, swapped)
		end)
		pos = stop
		ctx.view:set_selection(point(on_char(buffer, pos)))
	end
)

command("join", "Join the next line onto this one, with one space", function(ctx)
	local buffer = ctx.buffer
	local at = cursor(ctx)
	local line = buffer:line_of(at)
	-- One undo step however many lines it joins.
	kern.history.start_group()
	for _ = 1, math.max((ctx.count or 2) - 1, 1) do
		if line + 1 >= buffer:line_count() then
			break
		end
		local stop = buffer:line_end(line)
		local next_start = buffer:line_start(line + 1)
		local next_text = buffer:slice(next_start, buffer:line_end(line + 1))
		local lead = #(string.match(next_text, "^%s*") :: string)
		buffer:edit(function(e)
			e:replace(stop, next_start + lead, " ")
		end)
		at = stop
	end
	kern.history.end_group()
	ctx.view:set_selection(point(at))
end)

-- * and # search for the word under the cursor, forward or back.
for _, back in { false, true } do
	command(
		if back then "search-word-back" else "search-word",
		"Search for the word under the cursor",
		function(ctx)
			local from, to = word_object(ctx.buffer, cursor(ctx), false)
			ctx.view:set_selection({ ranges = { { anchor = from, head = to } }, primary = 1 })
			kern.run("search-selection")
			kern.run(if back then "search-prev" else "search-next")
			local range = ctx.view:selection().ranges[1]
			ctx.view:set_selection(point(math.min(range.anchor, range.head)))
		end
	)
end

command("undo", "Undo", function(ctx)
	for _ = 1, ctx.count or 1 do
		ctx.view:undo()
	end
	ctx.view:set_selection(point(on_char(ctx.buffer, cursor(ctx))))
end)
command("redo", "Redo", function(ctx)
	for _ = 1, ctx.count or 1 do
		ctx.view:redo()
	end
end)

-- `.` is core's, which types the last change's keys again.
core.again.ignore({ "vim-undo", "vim-redo", "vim-macro", "vim-play-macro" })
core.search.at_start.vim = true
for _, name in
	{ "vim-motion-G", "vim-motion-gg", "vim-motion-%", "vim-search-word", "vim-search-word-back" }
do
	core.jumps.add(name)
end

-- Keys --------------------------------------------------------------------

-- Panels like the file tree and help keep their keys.
kern.keymap.inherit_kinds("vim", "normal")
-- Keys other plugins put in normal mode that work the same here: the
-- space-leader keys, the command line, search, and going to definitions,
-- references and problems. Plugins loaded later get them too.
kern.keymap.inherit("vim", "normal", {
	"space",
	":",
	"/",
	"?",
	"n",
	"N",
	"g d",
	"g r",
	"]",
	"[",
	"ctrl-f",
	"ctrl-b",
	"ctrl-d",
	"ctrl-u",
	"pagedown",
	"pageup",
	"z z",
	"z a",
	"z t",
	"z b",
	"z o",
	"z R",
	"ctrl-o",
	"ctrl-i",
	"tab",
})
-- Insert mode as everyone has it, except that esc comes back here.
kern.keymap.inherit("vim-insert", "insert")
kern.keymap.fallback("vim-insert", "insert-char")
kern.mode.cursor("vim-insert", "bar")

local keys: { [string]: string } = {
	d = "vim-operator-d",
	c = "vim-operator-c",
	y = "vim-operator-y",
	x = "vim-delete-char",
	X = "vim-delete-char-before",
	D = "vim-delete-to-end",
	C = "vim-change-to-end",
	s = "vim-substitute",
	S = "vim-change-line",
	p = "vim-paste-after",
	P = "vim-paste-before",
	i = "vim-insert",
	a = "vim-append",
	I = "vim-insert-line-start",
	A = "vim-append-line-end",
	o = "vim-open-below",
	O = "vim-open-above",
	v = "vim-visual",
	V = "vim-visual-line",
	r = "vim-replace-char",
	["~"] = "vim-switch-case",
	J = "vim-join",
	[">"] = "vim-operator->",
	["<"] = "vim-operator-<",
	["g c"] = "vim-operator-gc",
	["g ~"] = "vim-operator-g~",
	["g u"] = "vim-operator-gu",
	["g U"] = "vim-operator-gU",
	["g ?"] = "vim-operator-g?",
	["g q"] = "vim-operator-gq",
	["g w"] = "vim-operator-gw",
	["="] = "vim-operator-=",
	["!"] = "vim-operator-!",
	["*"] = "vim-search-word",
	["#"] = "vim-search-word-back",
	q = "vim-macro",
	["@"] = "vim-play-macro",
	['"'] = "select-register",
	u = "vim-undo",
	["ctrl-r"] = "vim-redo",
	["."] = "repeat-change",
	enter = "press-button",
	["z c"] = "fold-close",
	["ctrl-e"] = "scroll-down",
	["ctrl-y"] = "scroll-up",
}
local visual: { [string]: string } = {
	d = "vim-operator-d",
	x = "vim-operator-d",
	c = "vim-operator-c",
	y = "vim-operator-y",
	esc = "vim-normal",
	v = "vim-normal",
	V = "vim-normal",
	[">"] = "vim-operator->",
	["<"] = "vim-operator-<",
	["g c"] = "vim-operator-gc",
	["g ~"] = "vim-operator-g~",
	["~"] = "vim-operator-g~",
	u = "vim-operator-gu",
	U = "vim-operator-gU",
	["g ?"] = "vim-operator-g?",
	["g q"] = "vim-operator-gq",
	["="] = "vim-operator-=",
	["!"] = "vim-operator-!",
	i = "vim-visual-inside",
	a = "vim-visual-around",
}
for key in motions do
	keys[key] = "vim-motion-" .. string.gsub(key, " ", "")
	visual[key] = keys[key]
end
kern.keymap.bind("vim", keys)
kern.keymap.bind("vim-visual", visual)
kern.keymap.bind("vim-insert", { esc = "vim-normal" })
kern.keymap.counts("vim")
kern.keymap.counts("vim-visual")
kern.keymap.inherit("vim-visual-line", "vim-visual")
kern.keymap.counts("vim-visual-line")

core.style.define({
	name = "vim",
	doc = "Vim's operators and motions, with a visual mode",
	mode = "vim",
	labels = {
		vim = "normal",
		["vim-insert"] = "insert",
		["vim-visual"] = "visual",
		["vim-visual-line"] = "visual line",
	},
	plugin = "vim",
})

return {}
