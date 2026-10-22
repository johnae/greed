-- Text helpers shared by motions: character classes, word boundaries and
-- columns. Positions are byte offsets, as everywhere in the greed API.

local greed = require("@greed")
local style = require("./style")

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

-- The view to measure `buffer` in as it's drawn: `view`, or the focused
-- one when it shows `buffer`.
local function drawn_in(buffer: Buffer, view: greed.View?): greed.View?
	local shown = view or greed.view()
	return if shown:buffer():id() == buffer:id() then shown else nil
end

--- The column `pos` is drawn at in `view` (the focused one unless given):
--- hidden text, like a table's pipes, takes no room. As `column` counts
--- where no view shows `buffer`. Vertical moves aim for it.
function M.drawn_column(buffer: Buffer, pos: number, view: greed.View?): number
	local shown = drawn_in(buffer, view)
	return if shown then shown:drawn_column(pos) else M.column(buffer, pos)
end

--- The position drawn at `column` of `line` in `view` (the focused one
--- unless given), past text that's hidden or only drawn; as `at_column`
--- finds it where no view shows `buffer`.
function M.at_drawn_column(buffer: Buffer, line: number, column: number, view: greed.View?): number
	local shown = drawn_in(buffer, view)
	return if shown then shown:at_drawn_column(line, column) else M.at_column(buffer, line, column)
end

-- Whether `pos` is inside markup hidden in `buffer` that shows as written
-- once the cursor is there, like a field's brackets in normal mode.
local function opens(view: greed.View, pos: number): boolean
	for _, mark in view:marks_at(pos) do
		if mark.conceal and pos > mark.from and pos < mark.to then
			local how = if mark.reveal == "auto"
				then style.reveal()
				elseif mark.reveal == "typing" then style.typing_reveal()
				else mark.reveal
			if how == "cursor" then
				return true
			end
		end
	end
	return false
end

--- Whether `pos` is drawn in `view` (the focused one unless given), rather
--- than in text the look hides there, like a table's pipes, or hidden
--- markup that shows as written once the cursor steps inside. Moves left
--- and right step over what isn't. Always where no view shows `buffer`.
function M.drawn(buffer: Buffer, pos: number, view: greed.View?): boolean
	local shown = drawn_in(buffer, view)
	if shown == nil then
		return true
	end
	return shown:at_drawn_column(buffer:line_of(pos), shown:drawn_column(pos)) == pos
		or opens(shown, pos)
end

--- One character left (`by` -1) or right (1) from `pos` in its line, past
--- what isn't drawn (`drawn`), so a cursor stays on what's shown; `pos`
--- itself when nothing drawn is left that way.
function M.step(buffer: Buffer, pos: number, by: number): number
	local line = buffer:line_of(pos)
	local first, last = buffer:line_start(line), buffer:line_end(line)
	local at = pos
	while true do
		local next = if by < 0
			then math.max(first, buffer:prev_char(at))
			else math.min(last, buffer:next_char(at))
		if next == at then
			return pos
		end
		at = next
		if M.drawn(buffer, at) then
			return at
		end
	end
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

--- A whole number as people read a big one: "143,691".
function M.count(n: number): string
	local digits = tostring(math.floor(math.abs(n)))
	local grouped = string.reverse((string.gsub(string.reverse(digits), "(%d%d%d)", "%1,")))
	grouped = string.gsub(grouped, "^,", "") :: string
	return if n < 0 then `-{grouped}` else grouped
end

-- `line` without a `\r` its break left at its end.
local function without_cr(line: string): string
	return if string.sub(line, -1) == "\r" then string.sub(line, 1, -2) else line
end

--- `text`'s lines as a buffer has them, without their breaks (an empty
--- last one after a last break too), and the byte (0-based) each starts at.
function M.buffer_lines(text: string): ({ string }, { number })
	local lines, starts = {}, {}
	local at = 1
	while true do
		local nl = string.find(text, "\n", at, true)
		table.insert(lines, without_cr(string.sub(text, at, (nl or #text + 1) - 1)))
		table.insert(starts, at - 1)
		if nl == nil then
			break
		end
		at = nl + 1
	end
	return lines, starts
end

--- `buffer`'s lines and where each starts (as `buffer_lines` has them),
--- which were `lines` and `starts` until lines `from` to `to` (0-based, as
--- they are now; as "buffer.changed" says) changed: those read from the
--- buffer, the rest taken from before and moved. What a change costs is
--- what it changed, for anything that keeps a buffer's lines. Nil when the
--- lines after them don't line up with the buffer's, as when the change
--- was wider than said.
function M.relines(
	buffer: Buffer,
	lines: { string },
	starts: { number },
	from: number,
	to: number
): ({ string }?, { number }?)
	local count = buffer:line_count()
	local delta = count - #lines
	if from < 0 or to < from or to >= count or to - delta < from - 1 then
		return nil, nil
	end
	local now: { string } = table.move(lines, 1, from, 1, table.create(count) :: { string })
	local at: { number } = table.move(starts, 1, from, 1, table.create(count) :: { number })
	for n = from, to do
		local start = buffer:line_start(n)
		now[n + 1], at[n + 1] = without_cr(buffer:slice(start, buffer:line_end(n))), start
	end
	if to + 1 < count then
		local bytes = buffer:line_start(to + 1) - starts[to - delta + 2]
		table.move(lines, to - delta + 2, #lines, to + 2, now)
		for n = to + 2, count do
			at[n] = starts[n - delta] + bytes
		end
		-- The line after the change is where it was, moved.
		local check = without_cr(buffer:slice(buffer:line_start(to + 1), buffer:line_end(to + 1)))
		if check ~= now[to + 2] then
			return nil, nil
		end
	end
	return now, at
end

--- `text` with every byte but letters, digits and `-._~` (and the ones
--- `keep` lists, like "/" for a path) as `%XX`, as URLs and links have it.
function M.percent_encode(text: string, keep: string?): string
	local unsafe = `[^%w%-%._~{string.gsub(keep or "", "%p", "%%%0")}]`
	return (
		string.gsub(text, unsafe, function(c: string): string
			return string.format("%%%02X", string.byte(c))
		end)
	)
end

--- `text` with each `%XX` as the byte it stands for.
function M.percent_decode(text: string): string
	return (
		string.gsub(text, "%%(%x%x)", function(hex: string): string
			return string.char(tonumber(hex, 16) :: number)
		end)
	)
end

return M
