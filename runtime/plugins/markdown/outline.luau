-- Markdown's outline (core.outline): a list item with the items under it,
-- or else a heading with its section. Items beside one another in the
-- same list, at the same indent, and sections under the same heading at
-- the same level, are what moving an item or a section passes.

local core = require("@core")
local structure = require("./structure")

type Structure = structure.Structure
type Unit = core.OutlineUnit

local function blank(text: string?): boolean
	return text == nil or string.find(text, "^%s*$") ~= nil
end

-- `first` to `last` without the blank lines at its end.
local function unit(s: Structure, first: number, last: number, nests: boolean?): Unit
	while last > first and blank(s.lines[last + 1]) do
		last -= 1
	end
	return { first = first, last = last, nests = nests }
end

-- Whether items `a` and `b` (a before b) are in the same list: the same
-- indent, under the same item, with only blank lines between a's end and b.
local function beside(s: Structure, a: structure.Item, b: structure.Item): boolean
	if a.indent ~= b.indent then
		return false
	end
	for n = a.last + 1, b.line - 1 do
		if not blank(s.lines[n + 1]) then
			return false
		end
	end
	return true
end

-- The list item around `line` as a unit, with the items beside it.
local function in_list(s: Structure, line: number): (Unit?, Unit?, Unit?)
	local item = structure.item_around(s, line)
	if item == nil then
		return nil, nil, nil
	end
	local before: Unit? = nil
	local after: Unit? = nil
	for _, each in s.items do
		if each.last < item.line and beside(s, each, item) then
			before = unit(s, each.line, each.last, true)
		elseif each.line > item.last and after == nil and beside(s, item, each) then
			after = unit(s, each.line, each.last, true)
		end
	end
	return unit(s, item.line, item.last, true), before, after
end

-- The section around `line`, with those beside it under the same heading.
local function in_sections(s: Structure, line: number): (Unit?, Unit?, Unit?)
	local heading = structure.heading_around(s, line)
	if heading == nil then
		return nil, nil, nil
	end
	local level = heading.level
	local before: Unit? = nil
	local after: Unit? = nil
	for _, each in s.headings do
		if each.line < heading.line then
			-- A heading above at a higher level closes the run of siblings.
			if each.level < level then
				before = nil
			elseif each.level == level then
				before = unit(s, each.line, structure.section_end(s, each))
			end
		elseif each.line > heading.line then
			if each.level < level then
				break
			elseif each.level == level then
				after = unit(s, each.line, structure.section_end(s, each))
				break
			end
		end
	end
	return unit(s, heading.line, structure.section_end(s, heading)), before, after
end

core.outline.provider("markdown", function(buffer, line)
	local s = structure.of(buffer)
	if s.code_at[line] then
		return nil, nil, nil
	end
	local found, before, after = in_list(s, line)
	if found then
		return found, before, after
	end
	return in_sections(s, line)
end)

return {}
