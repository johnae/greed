-- Helix's word motions for block cursors (helix-core's `word_move`), so
-- `w`, `b` and `e` select exactly what they do in Helix, counts and line
-- breaks included. Positions are byte offsets; a range's cursor is on its
-- last character going forward.

local greed = require("@greed")
local text = require("./text")

type Buffer = greed.Buffer
type Range = greed.Range

--- What a word motion goes to.
export type Target =
	"next-word-start"
	| "next-word-end"
	| "prev-word-start"
	| "next-long-word-start"
	| "next-long-word-end"
	| "prev-long-word-start"

local PREV: { [Target]: boolean } = { ["prev-word-start"] = true, ["prev-long-word-start"] = true }

local function is_eol(ch: string): boolean
	return ch == "\n" or ch == "\r"
end

local function is_space(ch: string): boolean
	return ch == " " or ch == "\t" or is_eol(ch)
end

local function word_boundary(a: string, b: string): boolean
	return text.class(a) ~= text.class(b)
end

-- Between words and punctuation isn't a boundary for long words (WORDs).
local function long_word_boundary(a: string, b: string): boolean
	local x, y = text.class(a), text.class(b)
	if (x == "word" and y == "punct") or (x == "punct" and y == "word") then
		return false
	end
	return x ~= y
end

local function reached(target: Target, prev: string, next: string): boolean
	local long = target == "next-long-word-start"
		or target == "next-long-word-end"
		or target == "prev-long-word-start"
	local boundary = if long then long_word_boundary(prev, next) else word_boundary(prev, next)
	if target == "next-word-start" or target == "next-long-word-start" then
		return boundary and (is_eol(next) or not is_space(next))
	end
	return boundary and (not is_space(prev) or is_eol(next))
end

-- One step of the motion from `origin`, which only moves its anchor when the
-- head starts on a boundary (Helix's `range_to_target`).
local function step(buffer: Buffer, target: Target, origin: Range): Range
	local back = PREV[target] == true
	local len = buffer:len()
	-- The character the head would move over next, and moving past it.
	local function ahead(head: number): string?
		if back then
			return if head > 0 then buffer:char_at(buffer:prev_char(head)) else nil
		end
		return if head < len then buffer:char_at(head) else nil
	end
	local function advance(head: number): number
		return if back then buffer:prev_char(head) else buffer:next_char(head)
	end
	local anchor, head = origin.anchor, origin.head
	local prev: string?
	if back then
		prev = if head < len then buffer:char_at(head) else nil
	else
		prev = if head > 0 then buffer:char_at(buffer:prev_char(head)) else nil
	end
	-- Line breaks right ahead are skipped.
	local ch = ahead(head)
	while ch and is_eol(ch) do
		prev = ch
		head = advance(head)
		ch = ahead(head)
	end
	if prev and is_eol(prev) then
		anchor = head
	end
	local start = head
	local next = ahead(head)
	while next do
		if prev == nil or reached(target, prev :: string, next) then
			if head == start then
				anchor = head
			else
				break
			end
		end
		prev = next
		head = advance(head)
		next = ahead(head)
	end
	return { anchor = anchor, head = head }
end

local M = {}

--- `range` after the word motion `target`, `count` times.
function M.move(buffer: Buffer, range: Range, count: number, target: Target): Range
	local back = PREV[target] == true
	if (back and range.head == 0) or (not back and range.head == buffer:len()) then
		return range
	end
	-- Block-cursor semantics: start from the cursor's character, whichever
	-- way the range went.
	local current: Range
	if back then
		current = if range.anchor < range.head
			then { anchor = range.head, head = buffer:prev_char(range.head) }
			else { anchor = buffer:next_char(range.head), head = range.head }
	else
		current = if range.anchor < range.head
			then { anchor = buffer:prev_char(range.head), head = range.head }
			else { anchor = range.head, head = buffer:next_char(range.head) }
	end
	for _ = 1, count do
		local moved = step(buffer, target, current)
		if moved.anchor == current.anchor and moved.head == current.head then
			break
		end
		current = moved
	end
	return current
end

return M
