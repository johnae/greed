-- Motions, as one table saying for each key where it goes and how an
-- operator takes its range, and marks.

local greed = require("@greed")
local core = require("@core")
local common = require("./common")

type Buffer = greed.Buffer
type Kind = common.Kind
type Motion = common.Motion

local class, is_blank, line_bounds = common.class, common.is_blank, common.line_bounds

-- The column j and k aim for, kept while moving through shorter lines.
local wanted: number? = nil

local function wanted_column(buffer: Buffer, pos: number): number
	local column = wanted or core.text.column(buffer, pos)
	wanted = column
	return column
end

-- Any command other than j and k forgets the column.
greed.on("command.run", function(event: greed.CommandRun)
	if event.name ~= "vim-motion-j" and event.name ~= "vim-motion-k" then
		wanted = nil
	end
end)

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
			pos = core.text.after(buffer, pos)
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
		local find = { forward = forward, before = before, char = greed.next_key() }
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
		return core.text.first_non_blank(buffer, buffer:line_start(line)), "line"
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
		local first, last = greed.view():visible()
		local top, bottom = buffer:line_of(first), buffer:line_of(math.max(first, last - 1))
		local line = if where == "top"
			then math.min(top + count - 1, bottom)
			elseif where == "bottom" then math.max(bottom - count + 1, top)
			else (top + bottom) // 2
		return core.text.first_non_blank(buffer, buffer:line_start(line)), "line"
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
		return core.text.at_column(buffer, line, wanted_column(buffer, pos)), "line"
	end,
	k = function(buffer, pos, count)
		local line = math.max(buffer:line_of(pos) - count, 0)
		return core.text.at_column(buffer, line, wanted_column(buffer, pos)), "line"
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
		return core.text.at_column(buffer, buffer:line_of(pos), count - 1), "exclusive"
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
		return core.text.first_non_blank(buffer, pos), "exclusive"
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

-- Marks: a to z in each buffer, by its id, tracked so they move with edits;
-- A to Z across files, by path and place.
local buffer_marks: { [number]: { [string]: greed.Anchor } } = {}
local file_marks: { [string]: { path: string, pos: number } } = {}

local function set_mark(buffer: Buffer, name: string, pos: number)
	if string.match(name, "^%u$") then
		local path = buffer:path()
		if path then
			file_marks[name] = { path = path, pos = pos }
		end
		return
	end
	local marks = buffer_marks[buffer:id()] or {}
	buffer_marks[buffer:id()] = marks
	local old = marks[name]
	if old then
		old:forget()
	end
	marks[name] = buffer:track(pos)
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
			greed.open(mark.path)
			buffer = greed.view():buffer()
		end
		return math.min(mark.pos, buffer:len())
	end
	local marks = buffer_marks[buffer:id()]
	local mark = marks and marks[name]
	return if mark then mark:pos() else nil
end

-- ' and `: to a mark's line, or to the mark itself.
local function to_mark(exact: boolean): Motion
	return function(buffer, _, _)
		local name = greed.next_key()
		local pos = mark_place(buffer, name)
		if pos == nil then
			greed.echo(`no mark {name}`)
			return nil, "exclusive"
		end
		-- An uppercase mark may have opened another file.
		buffer = greed.view():buffer()
		if exact then
			return pos, "exclusive"
		end
		return core.text.first_non_blank(buffer, pos), "line"
	end
end

-- G goes to line `count`, or the last line; gg to line `count`, or the first.
local function goto_line(first: boolean): Motion
	return function(buffer, _, count)
		local last = buffer:line_count() - 1
		local line = if count > 0 then math.min(count - 1, last) elseif first then 0 else last
		return core.text.first_non_blank(buffer, buffer:line_start(line)), "line"
	end
end
motions.G = goto_line(false)
motions["g g"] = goto_line(true)
motions["'"] = to_mark(false)
motions["`"] = to_mark(true)
-- The brackets % looks for, as Vim's 'matchpairs' has them.
local BRACKETS = "[%(%)%[%]{}]"

-- % goes to the bracket matching the one under the cursor, or else the
-- next one on the line, as Vim does; with a count, that percentage of the
-- way down the file.
motions["%"] = function(buffer: Buffer, pos: number, count: number): (number?, Kind)
	if count > 0 then
		local line =
			math.clamp((count * buffer:line_count() + 99) // 100 - 1, 0, buffer:line_count() - 1)
		return core.text.first_non_blank(buffer, buffer:line_start(line)), "line"
	end
	local stop = buffer:line_end(buffer:line_of(pos))
	local at = pos
	while at < stop and not string.match(buffer:char_at(at) or "", BRACKETS) do
		at = buffer:next_char(at)
	end
	if at >= stop then
		return nil, "inclusive"
	end
	return core.text.matching_bracket(buffer, at), "inclusive"
end

-- Motions whose count, left out, is 0 rather than 1: G and % act
-- differently without one.
local COUNTLESS: { [string]: boolean } = { G = true, ["%"] = true }

greed.on("buffer.closed", function(event: greed.BufferClosed)
	buffer_marks[event.id] = nil
end)

return {
	motions = motions,
	COUNTLESS = COUNTLESS,
	word_class = word_class,
	word_end = word_end,
	set_mark = set_mark,
	mark_place = mark_place,
}
