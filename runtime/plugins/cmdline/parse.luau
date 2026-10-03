-- Splitting a command line into words, and reading the line range before
-- a command.

local greed = require("@greed")

export type Parsed = {
	--- The command as typed, without a trailing "!".
	name: string,
	--- Whether the command ended in "!", as in `:q!`.
	force: boolean,
	args: { string },
}

local M = {}

-- Splits `line` into words at whitespace. Quotes ("..." or '...') keep
-- spaces inside a word, and a backslash takes the next character as is.
function M.words(line: string): { string }
	local words = {}
	local word: string? = nil
	local quote: string? = nil
	local i = 1
	while i <= #line do
		local c = string.sub(line, i, i)
		if c == "\\" and i < #line then
			i += 1
			word = (word or "") .. string.sub(line, i, i)
		elseif quote then
			if c == quote then
				quote = nil
			else
				word = (word or "") .. c
			end
		elseif c == '"' or c == "'" then
			quote = c
			word = word or ""
		elseif string.match(c, "%s") then
			if word then
				table.insert(words, word)
				word = nil
			end
		else
			word = (word or "") .. c
		end
		i += 1
	end
	if word then
		table.insert(words, word)
	end
	return words
end

-- Quotes `word` if it needs it to come back from `words` unchanged.
function M.quote(word: string): string
	if word ~= "" and not string.find(word, "[%s\"'\\]") then
		return word
	end
	return '"' .. string.gsub(word, '["\\]', "\\%0") .. '"'
end

--- What a range's addresses are measured from: the buffer, the cursor's
--- line and the selection's first and last line, all 0-based.
export type Lines = {
	buffer: greed.Buffer,
	current: number,
	first: number,
	last: number,
}

-- The address at `i` of `text`, Vim's way: a line number, `.` (the
-- cursor's line), `$` (the last), `'<` and `'>` (the selection's first and
-- last line), `/regex/` or `?regex?` (the next or previous line matching),
-- each with any `+n` and `-n` after it. Returns the 0-based line, or nil
-- when there's none, and the index after it.
local function address(text: string, i: number, lines: Lines): (number?, number)
	local buffer = lines.buffer
	local line: number? = nil
	local c, after = string.sub(text, i, i), string.sub(text, i + 1, i + 1)
	local digits = string.match(text, "^%d+", i)
	if digits then
		line, i = (tonumber(digits) :: number) - 1, i + #digits
	elseif c == "." then
		line, i = lines.current, i + 1
	elseif c == "$" then
		line, i = buffer:line_count() - 1, i + 1
	elseif c == "'" and (after == "<" or after == ">") then
		line = if after == "<" then lines.first else lines.last
		i += 2
	elseif c == "/" or c == "?" then
		local close = string.find(text, c, i + 1, true)
		local pattern = string.sub(text, i + 1, (close or #text + 1) - 1)
		i = (close or #text) + 1
		local back = c == "?"
		local from = if back
			then buffer:line_start(lines.current)
			else buffer:line_end(lines.current)
		local found = buffer:find(pattern, from, { backward = back, wrap = true })
		if found == nil then
			error(`pattern not found: {pattern}`, 0)
		end
		line = buffer:line_of(found)
	end
	while true do
		local sign, count = string.match(text, "^([+-])(%d*)", i)
		if sign == nil or count == nil then
			break
		end
		local step = (tonumber(count) or 1) * (if sign == "+" then 1 else -1)
		line = (line or lines.current) + step
		i += 1 + #count
	end
	return line, i
end

--- Reads the line range at the start of `text`: `%` for every line, one
--- address, or two with a comma between. Returns its first and last line
--- (nil without a range) and the rest of `text`. Errors on a pattern that
--- matches nothing.
function M.range(text: string, lines: Lines): (number?, number?, string)
	local i = (string.find(text, "%S") or #text + 1) :: number
	local first: number?, last: number? = nil, nil
	if string.sub(text, i, i) == "%" then
		first, last, i = 0, lines.buffer:line_count() - 1, i + 1
	else
		first, i = address(text, i, lines)
		last = first
		if string.sub(text, i, i) == "," then
			last, i = address(text, i + 1, lines)
			first = first or lines.current
			last = last or lines.current
		end
	end
	if first == nil or last == nil then
		return nil, nil, text
	end
	local count = lines.buffer:line_count()
	local a, b = math.clamp(first :: number, 0, count - 1), math.clamp(last :: number, 0, count - 1)
	return math.min(a, b), math.max(a, b), string.sub(text, i)
end

-- The command and its arguments, or nil for a blank line.
function M.parse(line: string): Parsed?
	local words = M.words(line)
	local first = table.remove(words, 1)
	if first == nil then
		return nil
	end
	local force = #first > 1 and string.sub(first, -1) == "!"
	return {
		name = if force then string.sub(first, 1, -2) else first,
		force = force,
		args = words,
	}
end

return M
