-- Folding Markdown sections: in any Markdown file, core's `z a` folds the
-- section the cursor is in under its heading.

local kern = require("@kern")
local core = require("@core")

local function heading_level(buffer: kern.Buffer, line: number): number?
	local text = buffer:slice(buffer:line_start(line), buffer:line_end(line))
	local hashes = string.match(text, "^(#+)%s")
	return if hashes then #hashes else nil
end

-- The heading line the section around `line` starts with, and its last
-- line; nil without a heading above or anything under it.
core.folds.providers.markdown = function(buffer: kern.Buffer, line: number): (number?, number)
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

return {}
