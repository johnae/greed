-- Vim-style editing, written only against the plugin API. It has modes of
-- its own (vim, vim-insert, vim-replace and the three visual modes), so it
-- sits beside Helix's normal mode instead of replacing it, and borrows the
-- space-leader keys, search, paging, the jumplist and the language server
-- keys from normal mode.
--
-- Switch to it with `:style vim`, or put this in ~/.config/kern/init.luau:
--
--     require("@kern").option.set("editing-style", "vim")
--
-- The file runs top to bottom as: text helpers; motions (one table, each
-- saying how an operator takes its range) and marks; ranges and text
-- objects; operators, applied through `apply` and the line and case
-- tables; then commands for the visual modes (block mode keeps a selection
-- per line), insert, replace, the change list and U; keys last. Ex
-- commands (:s, :g, ranges) are the command line plugin's, and `.` is
-- core's.

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

-- `repeat_step`, landing on the character it stops at.
local function inclusive_step(step: (Buffer, number, boolean?) -> number?, big: boolean?): Motion
	local motion = repeat_step(step, big)
	return function(buffer, pos, count)
		return (motion(buffer, pos, count)), "inclusive"
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
		local step = if forward then 1 else -1
		for _ = 1, count do
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
	e = inclusive_step(word_end),
	W = repeat_step(next_word_start, true),
	B = repeat_step(prev_word_start, true),
	E = inclusive_step(word_end, true),
	["g e"] = inclusive_step(prev_word_end),
	["g E"] = inclusive_step(prev_word_end, true),
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

-- Marks: a to z in the buffer, kept as decorations so they move with edits;
-- A to Z across files, by path and place.
local file_marks: { [string]: { path: string, pos: number } } = {}

local function set_mark(buffer: Buffer, name: string, pos: number)
	if string.match(name, "^%u$") then
		local path = buffer:path()
		if path then
			file_marks[name] = { path = path, pos = pos }
		end
		return
	end
	local marks = {}
	for _, mark in buffer:decorations("vim-marks") do
		if mark.style ~= name then
			table.insert(marks, mark)
		end
	end
	-- The style names the mark; nothing in the theme draws it.
	table.insert(marks, { from = pos, to = pos, style = name })
	buffer:decorate("vim-marks", marks)
end

-- Where mark `name` is in `buffer`, or nil. An uppercase mark in another
-- file opens it first.
local function mark_place(buffer: Buffer, name: string): number?
	if string.match(name, "^%u$") then
		local mark = file_marks[name]
		if mark == nil then
			return nil
		end
		if buffer:path() ~= mark.path then
			kern.open(mark.path)
			buffer = kern.view():buffer()
		end
		return math.min(mark.pos, buffer:len())
	end
	for _, mark in buffer:decorations("vim-marks") do
		if mark.style == name then
			return mark.from
		end
	end
	return nil
end

-- ' and `: to a mark's line, or to the mark itself.
local function to_mark(exact: boolean): Motion
	return function(buffer, _, _)
		local name = kern.next_key()
		local pos = mark_place(buffer, name)
		if pos == nil then
			kern.echo(`no mark {name}`)
			return nil, "exclusive"
		end
		-- An uppercase mark may have opened another file.
		buffer = kern.view():buffer()
		if exact then
			return pos, "exclusive"
		end
		return first_non_blank(buffer, buffer:line_of(pos)), "line"
	end
end

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
motions["'"] = to_mark(false)
motions["`"] = to_mark(true)
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
	elseif key == "s" then
		local from, to = buffer:sentence(pos)
		-- a sentence takes the blanks after it too.
		while around and to < buffer:len() and class(buffer:char_at(to)) == "space" do
			to = buffer:next_char(to)
		end
		return from, to, false
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
	elseif key == "i" then
		local from, to = core.objects.indent(buffer, pos, around)
		return motion_range(buffer, from, math.max(from, to - 1), "line")
	elseif key == "d" then
		local from, to = core.objects.number(buffer, pos, around)
		return from, to, false
	elseif key == "n" or key == "l" then
		-- The next or last pair: c i n ( changes inside the next parens.
		local open, close = core.objects.next_pair(buffer, pos, kern.next_key(), key == "l")
		if open == nil or close == nil then
			return nil, nil, false
		end
		if around then
			return open, buffer:next_char(close), false
		end
		return buffer:next_char(open), close, false
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

-- What 3i and 3o type again when insert mode ends: the count, where typing
-- began, and whether it opened a line.
local insert_repeat = { count = 1, start = 0, open = false }

local function enter_insert(ctx: kern.Context, pos: number)
	ctx.view:set_selection(point(pos))
	kern.mode.set("vim-insert")
	insert_repeat = { count = 1, start = pos, open = false }
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
	["zf"] = "fold-selection",
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

-- Keeps `value` in register `into`, for p and for ctrl-r while typing.
local function keep(into: string, value: { text: string, linewise: boolean })
	named[into] = value
	core.registers.set(into, { value.text })
end

-- Keeps what operator `op` took in the register picked with ", or the
-- unnamed one and the clipboard. "_ keeps nothing, and an uppercase letter
-- adds to its lowercase one.
local function store(op: string, taken: { text: string, linewise: boolean })
	local name = core.registers.take()
	if name and string.match(name, "^%u$") then
		name = string.lower(name)
		local before = named[name]
		if before then
			taken =
				{ text = before.text .. taken.text, linewise = before.linewise or taken.linewise }
		end
	end
	if name == nil or name == "+" or name == "*" then
		register = taken
		kern.clipboard.set(taken.text)
		-- The numbered registers, as Vim keeps them: "0 the last yank, "1 to
		-- "9 the last deletes of lines (older ones moving down), "- the last
		-- smaller delete.
		if op == "y" then
			keep("0", taken)
		elseif taken.linewise or string.find(taken.text, "\n", 1, true) then
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
end

-- What ys and visual S wrap text in for each key, as vim-surround has it:
-- an opening bracket adds spaces inside, a closing one doesn't, and b B r a
-- stand for ( { [ <. Any other character goes on both sides.
local SURROUND: { [string]: { string } } = {
	["("] = { "( ", " )" },
	[")"] = { "(", ")" },
	b = { "(", ")" },
	["["] = { "[ ", " ]" },
	["]"] = { "[", "]" },
	r = { "[", "]" },
	["{"] = { "{ ", " }" },
	["}"] = { "{", "}" },
	B = { "{", "}" },
	["<"] = { "<", ">" },
	[">"] = { "<", ">" },
	a = { "<", ">" },
}
-- The brackets b B r a stand for in ds and cs.
local PAIR_ALIASES: { [string]: string } = { b = "(", B = "{", r = "[", a = "<" }

local function pair_for(char: string): { string }
	return SURROUND[char] or { char, char }
end

-- Wraps `from`..`to` in the pair for the key typed next; whole lines wrap
-- from their first non-blank to their end.
local function surround(ctx: kern.Context, from: number, to: number, linewise: boolean)
	local char = kern.next_key()
	if utf8.len(char) ~= 1 then
		return
	end
	local buffer = ctx.buffer
	if linewise then
		local first =
			buffer:line_of(if buffer:char_at(from) == "\n" and from < to then from + 1 else from)
		local last = buffer:line_of(math.max(from, to - 1))
		from, to = first_non_blank(buffer, first), buffer:line_end(last)
	end
	local pair = pair_for(char)
	local start, finish = from, to :: number
	buffer:edit(function(e)
		e:insert(start, pair[1])
		e:insert(finish, pair[2])
	end)
	ctx.view:set_selection(point(from))
end

-- Applies operator `op` (one of "d", "c", "y", "ys" or LINE_OPERATORS) to `from`..`to`.
local function apply(ctx: kern.Context, op: string, from: number, to: number, linewise: boolean)
	local buffer = ctx.buffer
	if op == "ys" then
		surround(ctx, from, to, linewise)
		return
	end
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
	store(op, { text = buffer:slice(from, to), linewise = linewise })
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

-- The match of the last search that `pos` is in, or the next one round the
-- end: what gn takes.
local function search_match(buffer: Buffer, pos: number): (number?, number?)
	local last = core.search.last()
	if last == nil then
		return nil, nil
	end
	local pattern = core.search.smart_case(last)
	local start = buffer:line_start(buffer:line_of(pos))
	while start <= pos do
		local from, to = buffer:find(pattern, start)
		if from == nil or from > pos then
			break
		elseif to > pos then
			return from, to
		end
		local next = math.max(to, buffer:next_char(from))
		if next <= start then
			break
		end
		start = next
	end
	return buffer:find(pattern, pos, { wrap = true })
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
	-- vim-surround's keys: ds( deletes a pair, cs"' changes one, and ys
	-- takes a motion or object and then the pair to wrap it in.
	if (op == "d" or op == "c") and key == "s" then
		local char = kern.next_key()
		local with = if op == "c" then kern.next_key() else nil
		local open, close = core.objects.around(buffer, pos, PAIR_ALIASES[char] or char)
		if open == nil or close == nil then
			return
		end
		local pair = if with then pair_for(with) else { "", "" }
		local start, finish = open :: number, close :: number
		buffer:edit(function(e)
			e:replace(start, buffer:next_char(start), pair[1])
			e:replace(finish, buffer:next_char(finish), pair[2])
		end)
		ctx.view:set_selection(point(on_char(buffer, start)))
		return
	elseif op == "y" and key == "s" then
		operate(ctx, "ys")
		return
	end
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
		if key == "g n" then
			local found_from, found_to = search_match(buffer, pos)
			if found_from and found_to then
				apply(ctx, op, found_from, found_to, false)
			end
			return
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

-- Visual block mode: a rectangle of columns across lines, kept as one
-- selection per line, so what's typed after I, A or c goes on every line.
-- The corner it started from, where the cursor is, and whether $ took it
-- to the end of every line.
local block = { line = 0, column = 0, cursor = 0, to_end = false }

-- The selection for the block from its corner to `block.cursor`, both
-- columns included.
local function block_selection(buffer: Buffer): kern.Selection
	local line, column = buffer:line_of(block.cursor), column_of(buffer, block.cursor)
	local top, bottom = math.min(block.line, line), math.max(block.line, line)
	local left, right = math.min(block.column, column), math.max(block.column, column)
	local ranges: { kern.Range } = {}
	local primary = 1
	for row = top, bottom do
		local head = if block.to_end
			then buffer:line_end(row)
			else at_column(buffer, row, right + 1)
		table.insert(ranges, { anchor = at_column(buffer, row, left), head = head })
		if row == line then
			primary = #ranges
		end
	end
	return { ranges = ranges, primary = primary }
end

-- Motions move the cursor, or extend the selection in visual mode.
for key, motion in motions do
	command("motion-" .. string.gsub(key, " ", ""), "Vim motion " .. key, function(ctx)
		local selection = ctx.view:selection()
		local range = selection.ranges[selection.primary]
		local mode = kern.mode.get()
		local from = if mode == "vim-visual-block" then block.cursor else cursor(ctx)
		local target = motion(ctx.buffer, from, ctx.count or (if COUNTLESS[key] then 0 else 1))
		if target == nil then
			return
		end
		if mode == "vim-visual-block" then
			block.cursor, block.to_end = target, key == "$"
			ctx.view:set_selection(block_selection(ctx.buffer))
		elseif mode == "vim-visual-line" then
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

-- Operator `op` on the visual block, each line's piece on its own. What c
-- types goes on every line.
local function block_operate(ctx: kern.Context, op: string)
	local buffer = ctx.buffer
	local ranges = ctx.view:selection().ranges
	local top = ranges[1].anchor
	kern.mode.set("vim")
	local line_command = LINE_OPERATORS[op]
	if line_command then
		on_lines(ctx, line_command, top, ranges[#ranges].head, op)
		return
	end
	local case = CASE_OPERATORS[op]
	if case == nil then
		local pieces = {}
		for _, range in ranges do
			table.insert(pieces, buffer:slice(range.anchor, range.head))
		end
		store(op, { text = table.concat(pieces, "\n"), linewise = false })
		if op == "y" then
			ctx.view:set_selection(point(on_char(buffer, top)))
			return
		end
	end
	if op == "c" then
		kern.history.start_group()
	end
	buffer:edit(function(e)
		for _, range in ranges do
			if case then
				e:replace(range.anchor, range.head, case(buffer:slice(range.anchor, range.head)))
			else
				e:delete(range.anchor, range.head)
			end
		end
	end)
	if op ~= "c" then
		ctx.view:set_selection(point(on_char(buffer, top)))
		return
	end
	local points, removed = {}, 0
	for _, range in ranges do
		local pos = range.anchor - removed
		table.insert(points, { anchor = pos, head = pos })
		removed += range.head - range.anchor
	end
	ctx.view:set_selection({ ranges = points, primary = 1 })
	kern.mode.set("vim-insert")
end

for _, op in { "d", "c", "y", ">", "<", "gc", "g~", "gu", "gU", "g?", "gq", "gw", "=", "!", "zf" } do
	command("operator-" .. op, "Vim operator " .. op .. ", followed by a motion", function(ctx)
		local mode = kern.mode.get()
		if mode == "vim-visual-block" then
			block_operate(ctx, op)
			return
		elseif mode == "vim-visual" or mode == "vim-visual-line" then
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

-- What p pastes: the register picked with ", or the unnamed one. Nil for "_.
local function to_paste(): { text: string, linewise: boolean }?
	local name = core.registers.take()
	if name == "_" then
		return nil
	elseif name and name ~= "+" and name ~= "*" then
		name = string.lower(name)
		-- Text another style copied into it has no line information.
		local pieces = core.registers.get(name)
		return named[name]
			or (pieces and { text = table.concat(pieces, "\n"), linewise = false })
			or { text = "", linewise = false }
	end
	return unnamed()
end

local function paste(ctx: kern.Context, after: boolean)
	local from = to_paste()
	if from == nil then
		return
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

-- Starts typing at `pos` as one undo step, typed the count's times over.
local function start_insert(ctx: kern.Context, pos: number)
	kern.history.start_group()
	enter_insert(ctx, pos)
	insert_repeat.count = ctx.count or 1
end

command("insert", "Insert before the cursor", function(ctx)
	start_insert(ctx, cursor(ctx))
end)
command("append", "Insert after the cursor", function(ctx)
	local buffer, pos = ctx.buffer, cursor(ctx)
	start_insert(ctx, math.min(buffer:next_char(pos), buffer:line_end(buffer:line_of(pos))))
end)
command("insert-line-start", "Insert at the first non-blank of the line", function(ctx)
	start_insert(ctx, first_non_blank(ctx.buffer, ctx.buffer:line_of(cursor(ctx))))
end)
command("append-line-end", "Insert at the end of the line", function(ctx)
	start_insert(ctx, ctx.buffer:line_end(ctx.buffer:line_of(cursor(ctx))))
end)
command("insert-last", "Insert where insert mode was last left", function(ctx)
	start_insert(ctx, mark_place(ctx.buffer, "^") or cursor(ctx))
end)

local function open_line(ctx: kern.Context, below: boolean)
	kern.history.start_group()
	core.indent.open(ctx.view, below)
	enter_insert(ctx, cursor(ctx))
	insert_repeat.count, insert_repeat.open = ctx.count or 1, true
end
command("open-below", "Open a line below and insert", function(ctx)
	open_line(ctx, true)
end)
command("open-above", "Open a line above and insert", function(ctx)
	open_line(ctx, false)
end)

command("insert-one", "Run one normal mode command, then go on typing", function(ctx)
	local before = ctx.view:selection()
	kern.mode.set("vim")
	local keys: string?, count: number? = nil, nil
	while true do
		local key = kern.next_key()
		if keys == nil and string.match(key, "^%d$") and (count or key ~= "0") then
			count = (count or 0) * 10 + (tonumber(key) :: number)
		else
			keys = if keys then keys .. " " .. key else key
			local name, more = kern.keymap.resolve(keys :: string)
			if name then
				kern.run(name, { count = count })
				break
			elseif not more then
				break
			end
		end
	end
	-- Back to typing, unless the command went to another mode. A command that
	-- didn't move leaves the cursor where typing was, even past the line's end.
	if kern.mode.get() == "vim" then
		local after = ctx.view:selection()
		local moved = after.ranges[1].head ~= before.ranges[1].head
			or after.ranges[1].anchor ~= before.ranges[1].anchor
		kern.mode.set("vim-insert")
		ctx.view:set_selection(if moved then point(cursor(ctx)) else before)
	end
end)

-- R's replace mode: what each typed character took the place of, put back
-- by backspace.
local replaced: { { pos: number, text: string } } = {}

command("replace-mode", "Type over the text", function(ctx)
	kern.history.start_group()
	replaced = {}
	ctx.view:set_selection(point(cursor(ctx)))
	kern.mode.set("vim-replace")
end)

command("replace-typed", "Type over the character under the cursor", function(ctx)
	local char = ctx.char
	if char == nil then
		return
	end
	local buffer, pos = ctx.buffer, cursor(ctx)
	local _, _, finish = line_bounds(buffer, pos)
	local to = if pos < finish then buffer:next_char(pos) else pos
	table.insert(replaced, { pos = pos, text = buffer:slice(pos, to) })
	buffer:edit(function(e)
		e:replace(pos, to, char)
		e:select(point(pos + #char))
	end)
end)

command("replace-back", "Put back the character typed over last, or move left", function(ctx)
	local buffer, pos = ctx.buffer, cursor(ctx)
	local last = table.remove(replaced)
	if last == nil then
		local _, start = line_bounds(buffer, pos)
		if pos > start then
			ctx.view:set_selection(point(buffer:prev_char(pos)))
		end
		return
	end
	buffer:edit(function(e)
		e:replace(last.pos, pos, last.text)
		e:select(point(last.pos))
	end)
end)

-- U puts back the line changes were last made on as it was before them.
-- Before each command the cursor's line is noted; a change that keeps to
-- that line, after others on it, keeps the first note.
type LineNote = { buffer: number, line: number, text: string, lines: number }
local before: LineNote? = nil
local line_undo: LineNote? = nil
-- Set while U changes the line, which isn't a change for it to note.
local undoing_line = false

local function cursor_line_note(view: kern.View): LineNote
	local buffer = view:buffer()
	local selection = view:selection()
	local line = buffer:line_of(math.min(selection.ranges[selection.primary].head, buffer:len()))
	return {
		buffer = buffer:id(),
		line = line,
		text = buffer:slice(buffer:line_start(line), buffer:line_end(line)),
		lines = buffer:line_count(),
	}
end

kern.on("command.run", function()
	before = cursor_line_note(kern.view())
end)

kern.on("buffer.changed", function(event: kern.BufferChanged)
	local view = kern.view()
	if undoing_line or view:buffer():id() ~= event.buffer:id() then
		return
	end
	local now = cursor_line_note(view)
	local b = before
	if b == nil or b.buffer ~= now.buffer or b.line ~= now.line or b.lines ~= now.lines then
		line_undo = nil
	elseif line_undo == nil or line_undo.buffer ~= b.buffer or line_undo.line ~= b.line then
		line_undo = b
	end
end)

command("undo-line", "Put back the line last changed as it was before (U)", function(ctx)
	local u, buffer = line_undo, ctx.buffer
	if u == nil or u.buffer ~= buffer:id() or u.line >= buffer:line_count() then
		return
	end
	local from, to = buffer:line_start(u.line), buffer:line_end(u.line)
	-- U again puts the changes back.
	line_undo = { buffer = u.buffer, line = u.line, text = buffer:slice(from, to), lines = u.lines }
	undoing_line = true
	buffer:edit(function(e)
		e:replace(from, to, u.text)
	end)
	undoing_line = false
	ctx.view:set_selection(point(from))
end)

-- The change list for g; and g,: where the last changes in each buffer
-- were, kept as marks so they move with edits, numbered oldest first.
local CHANGES = 100
local changes_made = 0
-- How far back g; has gone in each buffer, by its id; 0 is past the newest.
local changes_back: { [number]: number } = {}

local function changes(buffer: Buffer): { kern.Mark }
	local marks = buffer:decorations("vim-changes")
	table.sort(marks, function(a: kern.Mark, b: kern.Mark)
		return (tonumber(a.style) :: number) < (tonumber(b.style) :: number)
	end)
	return marks
end

kern.on("buffer.changed", function(event: kern.BufferChanged)
	local view = kern.view()
	local buffer = event.buffer
	if view:buffer():id() ~= buffer:id() then
		return
	end
	local selection = view:selection()
	local pos = math.min(selection.ranges[selection.primary].head, buffer:len())
	local marks = changes(buffer)
	-- Another change on the same line takes the place of the last one.
	local newest = marks[#marks]
	if newest and buffer:line_of(newest.from) == buffer:line_of(pos) then
		table.remove(marks)
	elseif #marks >= CHANGES then
		table.remove(marks, 1)
	end
	changes_made += 1
	table.insert(marks, { from = pos, to = pos, style = tostring(changes_made) })
	buffer:decorate("vim-changes", marks)
	changes_back[buffer:id()] = 0
end)

-- g; and g,: to an older change, or back to a newer one.
for _, newer in { false, true } do
	command(
		if newer then "change-newer" else "change-older",
		if newer
			then "Go to a newer place in the change list"
			else "Go to an older place in the change list",
		function(ctx)
			local buffer = ctx.buffer
			local marks = changes(buffer)
			local back = (changes_back[buffer:id()] or 0)
				+ (ctx.count or 1) * (if newer then -1 else 1)
			local mark = marks[#marks - back + 1]
			if back < 1 or mark == nil then
				kern.echo(if newer then "at the newest change" else "at the oldest change")
				return
			end
			changes_back[buffer:id()] = back
			ctx.view:set_selection(point(on_char(buffer, mark.from)))
		end
	)
end

-- Types what 3i or 3o typed twice more, ending at `pos`. Returns where the
-- cursor goes.
local function repeat_insert(buffer: Buffer, pos: number): number
	local times, start = insert_repeat.count - 1, insert_repeat.start
	insert_repeat.count = 1
	if times < 1 or pos <= start then
		return pos
	end
	local text = if insert_repeat.open
		then "\n" .. buffer:slice(buffer:line_start(buffer:line_of(start)), pos)
		else buffer:slice(start, pos)
	local typed = string.rep(text, times)
	buffer:edit(function(e)
		e:insert(pos, typed)
	end)
	return pos + #typed
end

command("normal", "Back to normal mode", function(ctx)
	local mode = kern.mode.get()
	local buffer = ctx.buffer
	local pos = if mode == "vim-visual-block" then block.cursor else cursor(ctx)
	if mode == "vim-insert" or mode == "vim-replace" then
		if mode == "vim-insert" then
			pos = repeat_insert(buffer, pos)
		end
		set_mark(buffer, "^", pos)
		-- Leaving insert mode steps back onto the last character typed.
		local _, start = line_bounds(buffer, pos)
		if pos > start then
			pos = buffer:prev_char(pos)
		end
	end
	kern.history.end_group()
	kern.mode.set("vim")
	ctx.view:set_selection(point(on_char(buffer, pos)))
end)

-- The last visual selection and its mode, for gv.
local last_visual: { mode: string, selection: kern.Selection, block: typeof(block) }? = nil

kern.on("mode.changed", function(event: kern.ModeChanged)
	local visual_mode = "^vim%-visual"
	if string.match(event.from, visual_mode) and not string.match(event.to, visual_mode) then
		last_visual = {
			mode = event.from,
			selection = kern.view():selection(),
			block = table.clone(block),
		}
	end
end)

command(
	"command-line",
	"Open the command line, with the selected lines (or the count's) as its range",
	function(ctx)
		local mode = kern.mode.get()
		local text = ""
		if string.match(mode, "^vim%-visual") then
			-- A block's lines, as one range for '<,'> to read.
			local ranges = ctx.view:selection().ranges
			ctx.view:set_selection({
				ranges = { { anchor = ranges[1].anchor, head = ranges[#ranges].head } },
				primary = 1,
			})
			kern.mode.set("vim")
			text = "'<,'>"
		elseif ctx.count then
			text = if ctx.count == 1 then "." else `.,.+{ctx.count - 1}`
		end
		kern.run("command-line", { args = { text } })
	end
)

command("visual-surround", "Wrap the selection in the pair typed next", function(ctx)
	local mode = kern.mode.get()
	local range = ctx.view:selection().ranges[1]
	local from, to = math.min(range.anchor, range.head), math.max(range.anchor, range.head)
	kern.mode.set("vim")
	surround(ctx, from, to, mode == "vim-visual-line")
end)

-- alt-o and alt-i: Helix's growing and shrinking by syntax node, which
-- goes on in visual mode.
for _, grow in { true, false } do
	command(
		if grow then "expand-selection" else "shrink-selection",
		if grow
			then "Select the syntax node around the cursor or selection, in visual mode"
			else "Shrink the selection back, or to the first syntax node inside it",
		function()
			kern.run(if grow then "expand-selection" else "shrink-selection")
			if kern.mode.get() == "vim" then
				kern.mode.set("vim-visual")
			end
		end
	)
end

command("jump-to-word", "Label every word on screen and jump to the one typed", function(ctx)
	local from = core.jump.pick(ctx.view)
	if from then
		ctx.view:set_selection(point(from))
	end
end)

-- ctrl-n's multiple cursors, as vim-visual-multi has them: ctrl-n selects
-- the word under the cursor, then adds its next match each time; c d y i a
-- I A act on every selection, and esc goes back to one cursor.
command("multi-next", "Select the word under the cursor, or add its next match", function(ctx)
	if kern.mode.get() ~= "vim-multi" then
		local from, to = word_object(ctx.buffer, cursor(ctx), false)
		ctx.view:set_selection({ ranges = { { anchor = from, head = to } }, primary = 1 })
		kern.run("search-selection")
		kern.mode.set("vim-multi")
		return
	end
	kern.run("search-next-add")
end)

command("multi-skip", "Drop this match and add the next one instead", function(ctx)
	local skipped = ctx.view:selection()
	local old = skipped.ranges[skipped.primary]
	kern.run("search-next-add")
	local selection = ctx.view:selection()
	if #selection.ranges == #skipped.ranges then
		return
	end
	for i, range in selection.ranges do
		if range.anchor == old.anchor and range.head == old.head then
			table.remove(selection.ranges, i)
			if selection.primary > i then
				selection.primary -= 1
			end
			break
		end
	end
	ctx.view:set_selection(selection)
end)

command("multi-back", "Drop the match added last", function(ctx)
	if #ctx.view:selection().ranges == 1 then
		kern.run("vim-normal")
		return
	end
	kern.run("remove-primary")
end)

-- Back to one cursor, at the primary selection's start.
local function leave_multi(ctx: kern.Context)
	local selection = ctx.view:selection()
	local range = selection.ranges[selection.primary]
	kern.mode.set("vim")
	ctx.view:set_selection(point(on_char(ctx.buffer, math.min(range.anchor, range.head))))
end

command("multi-change", "Delete every selection and type in each place", function()
	kern.history.start_group()
	kern.run("delete")
	kern.mode.set("vim-insert")
end)
command("multi-delete", "Delete every selection", function(ctx)
	kern.run("delete")
	leave_multi(ctx)
end)
command("multi-copy", "Copy every selection", function(ctx)
	kern.run("copy")
	leave_multi(ctx)
end)

for _, at_end in { false, true } do
	command(
		if at_end then "multi-append" else "multi-insert",
		if at_end then "Type after every selection" else "Type before every selection",
		function(ctx)
			local selection = ctx.view:selection()
			for i, range in selection.ranges do
				local pos = if at_end
					then math.max(range.anchor, range.head)
					else math.min(range.anchor, range.head)
				selection.ranges[i] = { anchor = pos, head = pos }
			end
			kern.history.start_group()
			ctx.view:set_selection(selection)
			kern.mode.set("vim-insert")
		end
	)
end

command("reselect", "Select the last visual selection again", function(ctx)
	if last_visual == nil then
		return
	end
	local len = ctx.buffer:len()
	local ranges = {}
	for _, range in last_visual.selection.ranges do
		table.insert(
			ranges,
			{ anchor = math.min(range.anchor, len), head = math.min(range.head, len) }
		)
	end
	if last_visual.mode == "vim-visual-block" then
		block = table.clone(last_visual.block)
	elseif last_visual.mode == "vim-visual-line" then
		visual_line = ctx.buffer:line_of(ranges[1].anchor)
	end
	kern.mode.set(last_visual.mode)
	ctx.view:set_selection({ ranges = ranges, primary = last_visual.selection.primary })
end)

command("select-match", "Select the search match under the cursor, or the next one", function(ctx)
	local from, to = search_match(ctx.buffer, cursor(ctx))
	if from == nil or to == nil then
		kern.echo("no match")
		return
	end
	kern.mode.set("vim-visual")
	ctx.view:set_selection({ ranges = { { anchor = from, head = to } }, primary = 1 })
end)

-- ctrl-a and ctrl-x: core's, leaving the cursor on the number's last digit.
for _, down in { false, true } do
	local name = if down then "decrement" else "increment"
	local doc = if down
		then "Subtract the count (or 1) from the number at or after the cursor"
		else "Add the count (or 1) to the number at or after the cursor"
	command(name, doc, function(ctx)
		kern.run(name, { count = ctx.count })
		local range = ctx.view:selection().ranges[1]
		local to = math.max(range.anchor, range.head)
		if to > math.min(range.anchor, range.head) then
			ctx.view:set_selection(point(ctx.buffer:prev_char(to)))
		end
	end)
end

command("quit-unsaved", "Close without saving (ZQ)", function()
	kern.run("quit", { force = true })
end)

command(
	"mark",
	"Set the mark typed next (a to z here, A to Z across files) at the cursor",
	function(ctx)
		local name = kern.next_key()
		if string.match(name, "^%a$") then
			set_mark(ctx.buffer, name, cursor(ctx))
		end
	end
)

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

command("visual-block", "Select a block of columns across lines", function(ctx)
	local at = cursor(ctx)
	block.line, block.column, block.cursor = ctx.buffer:line_of(at), column_of(ctx.buffer, at), at
	block.to_end = false
	ctx.view:set_selection(block_selection(ctx.buffer))
	kern.mode.set("vim-visual-block")
end)

-- I and A: type at the start (or, `at_end`, the end) of each of the block's
-- lines. I skips lines too short to reach the block, as Vim does.
local function block_insert(at_end: boolean): (ctx: kern.Context) -> ()
	return function(ctx)
		local all = ctx.view:selection().ranges
		local ranges = {}
		for _, range in all do
			if at_end or range.anchor < range.head then
				local pos = if at_end then range.head else range.anchor
				table.insert(ranges, { anchor = pos, head = pos })
			end
		end
		if #ranges == 0 then
			ranges = { { anchor = all[1].anchor, head = all[1].anchor } }
		end
		kern.history.start_group()
		ctx.view:set_selection({ ranges = ranges, primary = 1 })
		kern.mode.set("vim-insert")
	end
end

command("block-insert", "Type before the block on each of its lines", block_insert(false))
command("block-append", "Type after the block on each of its lines", block_insert(true))

command("visual-swap", "Go to the other end of the selection", function(ctx)
	local mode = kern.mode.get()
	local buffer = ctx.buffer
	if mode == "vim-visual-block" then
		local corner = at_column(buffer, block.line, block.column)
		block.line, block.column, block.cursor =
			buffer:line_of(block.cursor), column_of(buffer, block.cursor), corner
		ctx.view:set_selection(block_selection(buffer))
	elseif mode == "vim-visual-line" then
		local line = buffer:line_of(cursor(ctx))
		ctx.view:set_selection(lines_selection(buffer, line, visual_line))
		visual_line = line
	else
		local range = ctx.view:selection().ranges[1]
		ctx.view:set_selection(visual(buffer, cursor(ctx), visual_start(buffer, range)))
	end
end)

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

-- Joins `times` lines onto `line`, each with one space, or as they are
-- with `raw` (gJ).
local function join(ctx: kern.Context, line: number, times: number, raw: boolean?)
	local buffer = ctx.buffer
	local at = cursor(ctx)
	-- One undo step however many lines it joins.
	kern.history.start_group()
	for _ = 1, times do
		if line + 1 >= buffer:line_count() then
			break
		end
		local stop = buffer:line_end(line)
		local next_start = buffer:line_start(line + 1)
		local next_text = buffer:slice(next_start, buffer:line_end(line + 1))
		local lead = if raw then 0 else #(string.match(next_text, "^%s*") :: string)
		buffer:edit(function(e)
			e:replace(stop, next_start + lead, if raw then "" else " ")
		end)
		at = stop
	end
	kern.history.end_group()
	ctx.view:set_selection(point(at))
end

for _, raw in { false, true } do
	command(
		if raw then "join-raw" else "join",
		if raw
			then "Join the next line onto this one as it is"
			else "Join the next line onto this one, with one space",
		function(ctx)
			join(ctx, ctx.buffer:line_of(cursor(ctx)), math.max((ctx.count or 2) - 1, 1), raw)
		end
	)
end

-- The first and last line the selection touches.
local function selected_lines(ctx: kern.Context): (number, number)
	local buffer, ranges = ctx.buffer, ctx.view:selection().ranges
	local first, last = ranges[1], ranges[#ranges]
	local from, to = math.min(first.anchor, first.head), math.max(last.anchor, last.head)
	return buffer:line_of(from), buffer:line_of(math.max(from, to - 1))
end

command("visual-join", "Join the selected lines, with one space", function(ctx)
	local first, last = selected_lines(ctx)
	kern.mode.set("vim")
	join(ctx, first, math.max(last - first, 1))
end)

command("visual-replace", "Replace every selected character with the next one typed", function(ctx)
	local char = kern.next_key()
	if utf8.len(char) ~= 1 then
		return
	end
	local buffer, ranges = ctx.buffer, ctx.view:selection().ranges
	local top = math.min(ranges[1].anchor, ranges[1].head)
	kern.mode.set("vim")
	buffer:edit(function(e)
		for _, range in ranges do
			local from, to = math.min(range.anchor, range.head), math.max(range.anchor, range.head)
			local text = string.gsub(buffer:slice(from, to), utf8.charpattern, function(c)
				return if c == "\n" then c else char
			end)
			e:replace(from, to, text)
		end
	end)
	ctx.view:set_selection(point(on_char(buffer, top)))
end)

command("visual-paste", "Replace the selection with what's in the register", function(ctx)
	local from = to_paste()
	if from == nil then
		return
	end
	local mode = kern.mode.get()
	local buffer = ctx.buffer
	if mode == "vim-visual-block" then
		-- The block goes first, then what's pasted goes where it started.
		block_operate(ctx, "d")
	end
	local range = ctx.view:selection().ranges[1]
	local start, stop = math.min(range.anchor, range.head), math.max(range.anchor, range.head)
	kern.mode.set("vim")
	local lines = mode == "vim-visual-line"
	local text = from.text
	if lines then
		-- Whole lines take their line break, except the last line's.
		if stop < buffer:len() then
			stop += 1
			if not from.linewise then
				text ..= "\n"
			end
		elseif from.linewise then
			text = string.gsub(text, "\n$", "")
		end
	elseif from.linewise then
		text = "\n" .. text
	end
	-- What it replaces goes in the unnamed register, as a delete would (the
	-- block's delete already did).
	if stop > start then
		store("d", { text = buffer:slice(start, stop), linewise = lines })
	end
	buffer:edit(function(e)
		e:replace(start, stop, text)
	end)
	if lines or from.linewise then
		local first = if lines then start else start + 1
		ctx.view:set_selection(point(first_non_blank(buffer, buffer:line_of(first))))
	else
		ctx.view:set_selection(point(on_char(buffer, buffer:prev_char(start + #text))))
	end
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
core.again.ignore({ "vim-undo", "vim-redo", "vim-undo-line", "vim-macro", "vim-play-macro" })
core.search.at_start.vim = true
for _, name in
	{
		"vim-motion-G",
		"vim-motion-gg",
		"vim-motion-%",
		"vim-motion-'",
		"vim-motion-`",
		"vim-search-word",
		"vim-search-word-back",
	}
do
	core.jumps.add(name)
end

-- Keys --------------------------------------------------------------------

-- Panels like the file tree and help keep their keys.
kern.keymap.inherit_kinds("vim", "normal")
-- Keys other plugins put in normal mode that work the same here: the
-- space-leader keys, search, and going to definitions and problems.
-- Plugins loaded later get them too.
kern.keymap.inherit("vim", "normal", {
	"space",
	"/",
	"?",
	"n",
	"N",
	"g d",
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
	["ctrl-v"] = "vim-visual-block",
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
	m = "vim-mark",
	["@"] = "vim-play-macro",
	['"'] = "select-register",
	u = "vim-undo",
	["ctrl-r"] = "vim-redo",
	["."] = "repeat-change",
	enter = "press-button",
	["z c"] = "fold-close",
	["ctrl-e"] = "scroll-down",
	["ctrl-y"] = "scroll-up",
	["ctrl-a"] = "vim-increment",
	["ctrl-x"] = "vim-decrement",
	["g J"] = "vim-join-raw",
	["g i"] = "vim-insert-last",
	["g v"] = "vim-reselect",
	["g n"] = "vim-select-match",
	["Z Z"] = "save-quit",
	["Z Q"] = "vim-quit-unsaved",
	R = "vim-replace-mode",
	U = "vim-undo-line",
	["ctrl-n"] = "vim-multi-next",
	K = "hover",
	["g r n"] = "rename",
	["g r a"] = "code-action",
	["g r r"] = "goto-references",
	["g r i"] = "goto-implementation",
	["g r t"] = "goto-type-definition",
	["g O"] = "pick-outline",
	["g s"] = "vim-jump-to-word",
	["alt-o"] = "vim-expand-selection",
	["alt-i"] = "vim-shrink-selection",
	["alt-shift-right"] = "swap-node-next",
	["alt-shift-left"] = "swap-node-prev",
	[":"] = "vim-command-line",
	["g ;"] = "vim-change-older",
	["g ,"] = "vim-change-newer",
	["z f"] = "vim-operator-zf",
	["z M"] = "fold-close-all",
	["z j"] = "fold-next",
	["z k"] = "fold-prev",
	["z d"] = "fold-open",
	["z E"] = "fold-open-all",
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
	["z f"] = "vim-operator-zf",
	[":"] = "vim-command-line",
	S = "vim-visual-surround",
	["alt-o"] = "vim-expand-selection",
	["alt-i"] = "vim-shrink-selection",
	["alt-shift-right"] = "swap-node-next",
	["alt-shift-left"] = "swap-node-prev",
	i = "vim-visual-inside",
	a = "vim-visual-around",
	o = "vim-visual-swap",
	r = "vim-visual-replace",
	J = "vim-visual-join",
	p = "vim-visual-paste",
	P = "vim-visual-paste",
	["ctrl-v"] = "vim-visual-block",
}
for key in motions do
	keys[key] = "vim-motion-" .. string.gsub(key, " ", "")
	visual[key] = keys[key]
end
kern.keymap.bind("vim", keys)
kern.keymap.bind("vim-visual", visual)
kern.keymap.bind("vim-insert", {
	esc = "vim-normal",
	["ctrl-o"] = "vim-insert-one",
	["ctrl-t"] = "indent",
	["ctrl-d"] = "dedent",
	["ctrl-n"] = "completion-words",
	["ctrl-p"] = "completion-words-back",
})
kern.keymap.bind("vim-multi", {
	["ctrl-n"] = "vim-multi-next",
	["ctrl-x"] = "vim-multi-skip",
	["ctrl-p"] = "vim-multi-back",
	c = "vim-multi-change",
	s = "vim-multi-change",
	d = "vim-multi-delete",
	x = "vim-multi-delete",
	y = "vim-multi-copy",
	i = "vim-multi-insert",
	I = "vim-multi-insert",
	a = "vim-multi-append",
	A = "vim-multi-append",
	esc = "vim-normal",
})
kern.keymap.inherit("vim-replace", "vim-insert")
kern.keymap.bind("vim-replace", { backspace = "vim-replace-back" })
kern.keymap.fallback("vim-replace", "vim-replace-typed")
kern.mode.cursor("vim-replace", "underline")
kern.keymap.counts("vim")
kern.keymap.counts("vim-visual")
kern.keymap.inherit("vim-visual-line", "vim-visual")
kern.keymap.counts("vim-visual-line")
kern.keymap.inherit("vim-visual-block", "vim-visual")
kern.keymap.bind("vim-visual-block", {
	I = "vim-block-insert",
	A = "vim-block-append",
	["ctrl-v"] = "vim-normal",
})
kern.keymap.counts("vim-visual-block")

core.style.define({
	name = "vim",
	doc = "Vim's operators and motions, with a visual mode",
	mode = "vim",
	labels = {
		vim = "normal",
		["vim-insert"] = "insert",
		["vim-visual"] = "visual",
		["vim-visual-line"] = "visual line",
		["vim-visual-block"] = "visual block",
		["vim-replace"] = "replace",
		["vim-multi"] = "multi",
	},
	plugin = "vim",
})

return {}
