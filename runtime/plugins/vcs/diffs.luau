-- Diffs as text: read-only buffers showing one, and the patch for a single
-- hunk of one, to apply on its own.
local greed = require("@greed")

local M = {}

-- The style of a line of a diff, if it has one.
local function style_of(line: string): string?
	if
		string.match(line, "^%+%+%+")
		or string.match(line, "^%-%-%-")
		or string.match(line, "^diff ")
	then
		return "markup.heading"
	elseif string.match(line, "^@@") then
		return "comment"
	elseif string.match(line, "^%+") then
		return "diff.plus"
	elseif string.match(line, "^%-") then
		return "diff.minus"
	end
	return nil
end

--- Shows `text`, a diff, in `buffer`, with headers, added and removed lines
--- styled.
function M.fill(buffer: greed.Buffer, text: string)
	buffer:set_readonly(false)
	buffer:edit(function(e)
		e:replace(0, buffer:len(), text)
	end)
	buffer:set_readonly(true)
	local marks: { greed.Mark } = {}
	local at = 0
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		local style = style_of(line)
		if style then
			table.insert(marks, { from = at, to = at + #line, style = style })
		end
		at += #line + 1
	end
	buffer:decorate("diff", marks)
end

--- A read-only buffer of kind `kind` showing `text`, a diff.
function M.buffer(kind: string, text: string): greed.Buffer
	local buffer = greed.create_buffer(kind, "", { readonly = true })
	M.fill(buffer, text)
	return buffer
end

--- The patch for the hunk on `line` (0-based) of the git-style diff `text`:
--- its file's header and that hunk alone. Nil off a hunk.
function M.hunk_patch(text: string, line: number): string?
	local lines = string.split((string.gsub(text, "\n$", "")), "\n")
	local at = line + 1
	if lines[at] == nil then
		return nil
	end
	-- Up to the hunk's @@ line; a file's header ends the search.
	local start = at
	while start >= 1 and not string.match(lines[start], "^@@") do
		if string.match(lines[start], "^diff ") or string.match(lines[start], "^%+%+%+ ") then
			return nil
		end
		start -= 1
	end
	if start < 1 then
		return nil
	end
	local header = start
	while header >= 1 and not string.match(lines[header], "^diff ") do
		header -= 1
	end
	if header < 1 then
		return nil
	end
	local stop = start + 1
	while
		lines[stop]
		and not string.match(lines[stop], "^@@")
		and not string.match(lines[stop], "^diff ")
	do
		stop += 1
	end
	-- The file's header is what comes before its first hunk.
	local first = header
	while not string.match(lines[first], "^@@") do
		first += 1
	end
	local patch = { table.unpack(lines, header, first - 1) }
	for i = start, stop - 1 do
		table.insert(patch, lines[i])
	end
	return table.concat(patch, "\n") .. "\n"
end

return M
