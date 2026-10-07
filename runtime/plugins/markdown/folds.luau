-- Folding Markdown: core's `tab` and `z a` fold the innermost block around
-- the cursor of a fenced code block, a list item with lines under it (a
-- todo and its subtasks), or the section under a heading.

local greed = require("@greed")
local core = require("@core")

-- A fence line's ticks or tildes, and whether nothing but spaces follows,
-- as on a closing fence.
local function fence_of(text: string): (string?, boolean)
	local ticks, rest = string.match(text, "^%s*(```+)(.*)$")
	if ticks == nil then
		ticks, rest = string.match(text, "^%s*(~~~+)(.*)$")
	end
	return ticks, rest ~= nil and string.match(rest, "^%s*$") ~= nil
end

-- The fenced block around `line`, from its opening fence to its closing one.
local function fence(buffer: greed.Buffer, line: number): (number?, number)
	local open, ticks = nil :: number?, ""
	for n = 0, buffer:line_count() - 1 do
		local found, bare = fence_of(buffer:line_text(n))
		if open == nil then
			if n > line then
				break
			elseif found then
				open, ticks = n, found
			end
		elseif
			found
			and bare
			and string.sub(found, 1, 1) == string.sub(ticks, 1, 1)
			and #found >= #ticks
		then
			if line <= n then
				return open, n
			end
			open = nil
		end
	end
	return nil, line
end

-- How far a line is indented, or nil when it's blank.
local function indent_of(text: string): number?
	local spaces = string.match(text, "^(%s*)%S")
	return if spaces then #spaces else nil
end

-- How far a list item's marker is indented, or nil when it isn't one.
local function item_of(text: string): number?
	local spaces = string.match(text, "^(%s*)[-*+] ") or string.match(text, "^(%s*)%d+[.)] ")
	return if spaces then #spaces else nil
end

-- The list item `line` is in, with the lines indented under it.
local function item(buffer: greed.Buffer, line: number): (number?, number)
	local count = buffer:line_count()
	for top = line, 0, -1 do
		local text = buffer:line_text(top)
		local depth = item_of(text)
		if depth then
			local last = top
			for n = top + 1, count - 1 do
				local indent = indent_of(buffer:line_text(n))
				if indent and indent <= depth then
					break
				elseif indent then
					last = n
				end
			end
			if last > top and line <= last then
				return top, last
			end
		elseif indent_of(text) == 0 then
			-- A paragraph or heading: the list, if any, ended above.
			break
		end
	end
	return nil, line
end

local function heading_level(buffer: greed.Buffer, line: number): number?
	local hashes = string.match(buffer:line_text(line), "^(#+)%s")
	return if hashes then #hashes else nil
end

-- The section around `line`: its heading to the line before the next
-- heading of the same level or higher.
local function section(buffer: greed.Buffer, line: number): (number?, number)
	local heading = line
	while heading >= 0 and heading_level(buffer, heading) == nil do
		heading -= 1
	end
	if heading < 0 then
		return nil, line
	end
	local level = heading_level(buffer, heading) :: number
	local last = buffer:line_count() - 1
	for next = heading + 1, last do
		local other = heading_level(buffer, next)
		if other and other <= level then
			last = next - 1
			break
		end
	end
	if last == heading then
		return nil, line
	end
	return heading, last
end

core.folds.provider("markdown", function(buffer: greed.Buffer, line: number): (number?, number)
	local first, last = fence(buffer, line)
	if first then
		return first, last
	end
	first, last = item(buffer, line)
	if first then
		return first, last
	end
	return section(buffer, line)
end)

return {}
