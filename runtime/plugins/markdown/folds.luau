-- Folding Markdown: core's `tab` and `z a` fold the innermost block around
-- the cursor of a fenced code block, a list item with lines under it (a
-- todo and its subtasks), or the section under a heading.

local greed = require("@greed")
local core = require("@core")
local structure = require("./structure")

type Structure = structure.Structure

-- The closed code block around `line`, from its opening fence to its
-- closing one.
local function fence(s: Structure, line: number): (number?, number)
	local block = s.code_at[line]
	if block and block.closed then
		return block.open, block.close
	end
	return nil, line
end

-- The innermost list item `line` is in that has lines under it.
local function item(s: Structure, line: number): (number?, number)
	local found: structure.Item? = nil
	for _, each in s.items do
		if each.line > line then
			break
		elseif each.last >= line and each.last > each.line then
			found = each
		end
	end
	if found then
		return found.line, found.last
	end
	return nil, line
end

-- The section around `line`: its heading to the line before the next
-- heading of the same level or higher.
local function section(s: Structure, line: number): (number?, number)
	local heading: structure.Heading? = nil
	local after: structure.Heading? = nil
	for _, each in s.headings do
		if each.line <= line then
			heading = each
		elseif heading and each.level <= heading.level then
			after = each
			break
		end
	end
	if heading == nil then
		return nil, line
	end
	local last = if after then after.line - 1 else #s.lines - 1
	if last <= heading.last then
		return nil, line
	end
	return heading.line, last
end

core.folds.provider("markdown", function(buffer: greed.Buffer, line: number): (number?, number)
	local s = structure.of(buffer)
	local first, last = fence(s, line)
	if first then
		return first, last
	end
	first, last = item(s, line)
	if first then
		return first, last
	end
	return section(s, line)
end)

return {}
