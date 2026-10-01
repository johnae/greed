-- Folding Markdown sections: `z a` folds the section the cursor is in under
-- its heading, or unfolds it. Works in any Markdown file.

local kern = require("@kern")

local function heading_level(buffer: kern.Buffer, line: number): number?
	local text = buffer:slice(buffer:line_start(line), buffer:line_end(line))
	local hashes = string.match(text, "^(#+)%s")
	return if hashes then #hashes else nil
end

-- The heading line the section around `line` starts with, and its last line.
local function section(buffer: kern.Buffer, line: number): (number?, number)
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
	return heading, last
end

kern.command({
	name = "fold-toggle",
	doc = "Fold the Markdown section the cursor is in under its heading, or unfold it",
	run = function(ctx)
		local buffer = ctx.buffer
		local selection = ctx.view:selection()
		local line = buffer:line_of(selection.ranges[selection.primary].head)
		local heading, last = section(buffer, line)
		if heading == nil then
			kern.echo("no heading above to fold under")
			return
		end
		local start = buffer:line_start(heading)
		-- Each fold is two marks starting at its heading: the fold and the
		-- summary after the heading.
		local kept, unfolded = {}, false
		for _, mark in buffer:decorations("folds") do
			if mark.from == start then
				unfolded = true
			else
				table.insert(kept, mark)
			end
		end
		if unfolded then
			buffer:decorate("folds", kept)
			return
		end
		if last == heading then
			kern.echo("nothing under this heading to fold")
			return
		end
		table.insert(
			kept,
			{ from = start, to = buffer:line_end(last), style = "fold", fold = true }
		)
		table.insert(kept, {
			from = start,
			to = buffer:line_end(heading),
			style = "comment",
			text = `⋯ {last - heading} lines`,
			eol = true,
		})
		buffer:decorate("folds", kept)
		ctx.view:set_selection({ ranges = { { anchor = start, head = start } }, primary = 1 })
	end,
})

return {}
