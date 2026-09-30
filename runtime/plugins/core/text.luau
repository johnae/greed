-- Text helpers shared by motions: character classes, word boundaries and
-- columns. Positions are byte offsets, as everywhere in the kern API.

local M = {}

-- "space", "eol", "word" or "punct"; nil past the end of the buffer.
function M.class(ch: string?): string?
	if ch == nil then
		return nil
	elseif ch == " " or ch == "\t" then
		return "space"
	elseif ch == "\n" or ch == "\r" then
		return "eol"
	elseif #ch > 1 or ch:match("[%w_]") then
		return "word"
	else
		return "punct"
	end
end

local function blank(class: string?): boolean
	return class == "space" or class == "eol"
end

local function class_at(buffer, pos: number): string?
	return M.class(buffer:char_at(pos))
end

-- Skips forward over characters for which `keep(class)` holds.
local function skip_forward(buffer, pos: number, keep: (string?) -> boolean): number
	local len = buffer:len()
	while pos < len and keep(class_at(buffer, pos)) do
		pos = buffer:next_char(pos)
	end
	return pos
end

-- The start of the next word after `pos`: past the rest of the current word
-- and any blanks after it.
function M.next_word_start(buffer, pos: number): number
	local class = class_at(buffer, pos)
	if not blank(class) then
		pos = skip_forward(buffer, pos, function(c)
			return c == class
		end)
	end
	return skip_forward(buffer, pos, blank)
end

-- The start of the word before `pos`, skipping blanks in between.
function M.prev_word_start(buffer, pos: number): number
	while pos > 0 and blank(class_at(buffer, buffer:prev_char(pos))) do
		pos = buffer:prev_char(pos)
	end
	if pos == 0 then
		return 0
	end
	local class = class_at(buffer, buffer:prev_char(pos))
	while pos > 0 and class_at(buffer, buffer:prev_char(pos)) == class do
		pos = buffer:prev_char(pos)
	end
	return pos
end

-- The end (exclusive) of the next word at or after `pos`.
function M.word_end(buffer, pos: number): number
	pos = skip_forward(buffer, pos, blank)
	local class = class_at(buffer, pos)
	return skip_forward(buffer, pos, function(c)
		return c == class
	end)
end

-- How many characters `pos` is from the start of its line.
function M.column(buffer, pos: number): number
	local p = buffer:line_start(buffer:line_of(pos))
	local column = 0
	while p < pos do
		p = buffer:next_char(p)
		column += 1
	end
	return column
end

-- The position `column` characters into `line`, or the line's end if it is
-- shorter.
function M.at_column(buffer, line: number, column: number): number
	local p = buffer:line_start(line)
	local stop = buffer:line_end(line)
	for _ = 1, column do
		if p >= stop then
			break
		end
		p = buffer:next_char(p)
	end
	return p
end

return M
