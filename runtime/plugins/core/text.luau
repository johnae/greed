-- Text helpers shared by motions: character classes, word boundaries and
-- columns. Positions are byte offsets, as everywhere in the greed API.

local greed = require("@greed")

type Buffer = greed.Buffer

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

local function class_at(buffer: Buffer, pos: number): string?
	return M.class(buffer:char_at(pos))
end

-- The word (or run of punctuation or blanks) at `pos`, as a start and end.
function M.word_at(buffer: Buffer, pos: number): (number, number)
	local of = class_at(buffer, pos)
	local from, to = pos, pos
	while from > 0 and class_at(buffer, buffer:prev_char(from)) == of do
		from = buffer:prev_char(from)
	end
	while to < buffer:len() and class_at(buffer, to) == of do
		to = buffer:next_char(to)
	end
	return from, to
end

-- Skips forward over characters for which `keep(class)` holds.
local function skip_forward(buffer: Buffer, pos: number, keep: (string?) -> boolean): number
	local len = buffer:len()
	while pos < len and keep(class_at(buffer, pos)) do
		pos = buffer:next_char(pos)
	end
	return pos
end

-- The start of the next word after `pos`: past the rest of the current word
-- and any blanks after it.
function M.next_word_start(buffer: Buffer, pos: number): number
	local class = class_at(buffer, pos)
	if not blank(class) then
		pos = skip_forward(buffer, pos, function(c)
			return c == class
		end)
	end
	return skip_forward(buffer, pos, blank)
end

-- The start of the word before `pos`, skipping blanks in between.
function M.prev_word_start(buffer: Buffer, pos: number): number
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
function M.word_end(buffer: Buffer, pos: number): number
	pos = skip_forward(buffer, pos, blank)
	local class = class_at(buffer, pos)
	return skip_forward(buffer, pos, function(c)
		return c == class
	end)
end

-- WORDs are runs of anything but blanks, punctuation included.
local function non_blank(class: string?): boolean
	return not blank(class)
end

function M.next_big_word_start(buffer: Buffer, pos: number): number
	pos = skip_forward(buffer, pos, non_blank)
	return skip_forward(buffer, pos, blank)
end

function M.prev_big_word_start(buffer: Buffer, pos: number): number
	while pos > 0 and blank(class_at(buffer, buffer:prev_char(pos))) do
		pos = buffer:prev_char(pos)
	end
	while pos > 0 and non_blank(class_at(buffer, buffer:prev_char(pos))) do
		pos = buffer:prev_char(pos)
	end
	return pos
end

function M.big_word_end(buffer: Buffer, pos: number): number
	pos = skip_forward(buffer, pos, blank)
	return skip_forward(buffer, pos, non_blank)
end

-- The first character on `pos`'s line that isn't a space or tab.
function M.first_non_blank(buffer: Buffer, pos: number): number
	local line = buffer:line_of(pos)
	local at, stop = buffer:line_start(line), buffer:line_end(line)
	while at < stop and class_at(buffer, at) == "space" do
		at = buffer:next_char(at)
	end
	return at
end

local PAIRS = { ["("] = ")", ["["] = "]", ["{"] = "}", ["<"] = ">" }
local OPENERS = { [")"] = "(", ["]"] = "[", ["}"] = "{", [">"] = "<" }

-- Scans from the bracket `this` at `pos` for the `other` that balances it.
local function balance(
	buffer: Buffer,
	pos: number,
	this: string,
	other: string,
	forward: boolean
): number?
	local depth, at = 0, pos
	while true do
		local c = buffer:char_at(at)
		if c == this then
			depth += 1
		elseif c == other then
			depth -= 1
			if depth == 0 then
				return at
			end
		end
		if forward then
			at = buffer:next_char(at)
			if at >= buffer:len() then
				return nil
			end
		else
			if at == 0 then
				return nil
			end
			at = buffer:prev_char(at)
		end
	end
end

-- The bracket matching the one at `pos`, or if `pos` isn't on a bracket,
-- the closing bracket of the pair around it. Nil if there is none.
function M.matching_bracket(buffer: Buffer, pos: number): number?
	local ch = buffer:char_at(pos)
	if ch and PAIRS[ch] then
		return balance(buffer, pos, ch, PAIRS[ch], true)
	end
	if ch and OPENERS[ch] then
		return balance(buffer, pos, ch, OPENERS[ch], false)
	end
	-- Inside a pair: find the nearest unclosed opener before `pos`.
	local depth: { [string]: number } = {}
	local at = pos
	while at > 0 do
		at = buffer:prev_char(at)
		local c = buffer:char_at(at) :: string
		if OPENERS[c] then
			depth[c] = (depth[c] or 0) + 1
		elseif PAIRS[c] then
			local closer = PAIRS[c]
			if (depth[closer] or 0) == 0 then
				return balance(buffer, at, c, closer, true)
			end
			depth[closer] -= 1
		end
	end
	return nil
end

--- The screen column `pos` is drawn at in its line, so wide characters
--- count two and tabs reach the next tab stop.
function M.column(buffer: Buffer, pos: number): number
	return buffer:display_column(pos)
end

--- The position drawn at screen column `column` of `line`, or the line's
--- end if it is shorter.
function M.at_column(buffer: Buffer, line: number, column: number): number
	return buffer:at_display_column(line, column)
end

--- The text of lines `first` to `last`, without the last one's line break.
function M.lines(buffer: Buffer, first: number, last: number): string
	return buffer:slice(buffer:line_start(first), buffer:line_end(last))
end

--- The start and end of `range`, whichever way it points.
function M.span(range: greed.Range): (number, number)
	return math.min(range.anchor, range.head), math.max(range.anchor, range.head)
end

--- Whether any range of `selection` covers text, rather than being a cursor.
function M.anything_selected(selection: greed.Selection): boolean
	for _, range in selection.ranges do
		if range.anchor ~= range.head then
			return true
		end
	end
	return false
end

-- The line break the buffer uses: "\r\n" if its first line ends in one.
function M.line_break(buffer: Buffer): string
	if buffer:line_count() > 1 and buffer:char_at(buffer:line_end(0)) == "\r" then
		return "\r\n"
	end
	return "\n"
end

-- The start of the character before `pos`, counting "\r\n" as one.
function M.before(buffer: Buffer, pos: number): number
	local prev = buffer:prev_char(pos)
	if prev > 0 and buffer:char_at(prev) == "\n" then
		local cr = buffer:prev_char(prev)
		if buffer:char_at(cr) == "\r" then
			return cr
		end
	end
	return prev
end

-- The end of the character at `pos`, counting "\r\n" as one.
function M.after(buffer: Buffer, pos: number): number
	if buffer:char_at(pos) == "\r" and buffer:char_at(pos + 1) == "\n" then
		return pos + 2
	end
	return buffer:next_char(pos)
end

--- `lines` rewrapped so none is longer than `width` where words allow:
--- each paragraph (blank lines separate them) keeps its first line's
--- indent, and a final line break stays.
function M.reflow(lines: string, width: number): string
	local ends = string.sub(lines, -1) == "\n"
	local body = if ends then string.sub(lines, 1, -2) else lines
	local out: { string } = {}
	local paragraph: { string } = {}
	local indent: string? = nil
	local function flush()
		local lead = indent
		if lead == nil then
			return
		end
		local line, filled = lead, false
		for _, word in paragraph do
			if filled and #line + 1 + #word > width then
				table.insert(out, line)
				line = lead .. word
			else
				line = if filled then `{line} {word}` else line .. word
			end
			filled = true
		end
		table.insert(out, line)
		paragraph, indent = {}, nil
	end
	for _, line in string.split(body, "\n") do
		if string.match(line, "^%s*$") then
			flush()
			table.insert(out, "")
		else
			indent = indent or string.match(line, "^%s*") :: string
			for word in string.gmatch(line, "%S+") do
				table.insert(paragraph, word)
			end
		end
	end
	flush()
	return table.concat(out, "\n") .. (if ends then "\n" else "")
end

--- How many cells `text` takes on screen, as Greed draws it: wide
--- characters take two (`greed.text.width`).
M.width = greed.text.width

--- How many bytes `a` and `b` start with in common, in whole lines, each
--- with its line break: what an edit replacing `a` with `b` can leave be,
--- so the cursor and marks in those lines stay put.
function M.same_lines(a: string, b: string): number
	local at = 1
	while true do
		local stop = string.find(a, "\n", at, true)
		if stop == nil or string.sub(a, at, stop) ~= string.sub(b, at, stop) then
			return at - 1
		end
		at = stop + 1
	end
end

--- `text` cut to `width` cells, the last an ellipsis when it's longer.
function M.clip(text: string, width: number): string
	if M.width(text) <= width then
		return text
	end
	if utf8.len(text) == nil then
		return string.sub(text, 1, math.max(width - 1, 0)) .. "…"
	end
	-- Whole characters, while they and the ellipsis fit.
	local used, cut = 0, 0
	for at, code in utf8.codes(text) do
		local char = utf8.char(code)
		local cells = M.width(char)
		if used + cells > width - 1 then
			break
		end
		used += cells
		cut = at + #char - 1
	end
	return string.sub(text, 1, cut) .. "…"
end

--- `text`'s lines, without their breaks (`\n` or `\r\n`), and without the
--- empty one after a last break, which ends the last line rather than
--- starting another. No text has no lines.
function M.split_lines(text: string): { string }
	if text == "" then
		return {}
	end
	local lines = string.split(text, "\n")
	if lines[#lines] == "" then
		table.remove(lines)
	end
	for i, line in lines do
		if string.sub(line, -1) == "\r" then
			lines[i] = string.sub(line, 1, -2)
		end
	end
	return lines
end

--- `text` without blanks at its start and end.
function M.trim(text: string): string
	return string.match(text, "^%s*(.-)%s*$") or ""
end

--- `text` without the quotes around it, `"…"` or `'…'`, if it has them.
function M.unquote(text: string): string
	return string.match(text, '^"(.*)"$') or string.match(text, "^'(.*)'$") or text
end

--- A size in bytes as people read it: "899 B", "142.6 kB".
function M.bytes(n: number): string
	if n < 1000 then
		return `{n} B`
	end
	local units = { "kB", "MB", "GB", "TB", "PB" }
	local value, unit = n / 1000, 1
	while value >= 1000 and unit < #units do
		value /= 1000
		unit += 1
	end
	return string.format("%.1f %s", value, units[unit])
end

return M
