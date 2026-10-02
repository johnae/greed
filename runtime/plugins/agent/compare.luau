-- Proposed changes side by side: `space o d` shows (or hides), beside the
-- file, the file as it would be with every waiting change in, the new
-- text picked out. The two scroll together, line for line where they
-- match, and the side view follows edits and decisions.

local kern = require("@kern")
local proposals = require("./proposals")

-- Where one change is, in lines: from `old` for `old_lines` in the file,
-- to `new` for `new_lines` in the side view.
type Block = { old: number, old_lines: number, new: number, new_lines: number }

type Compare = {
	-- The file's buffer and the view the side view is beside.
	source: kern.Buffer,
	beside: kern.View,
	view: kern.View,
	shown: kern.Buffer,
	blocks: { Block },
	-- The line each view was just scrolled to from the other, so its own
	-- scroll event for it doesn't send the other back.
	expected: { [number]: number },
}

local open: Compare? = nil

local function count_lines(text: string): number
	local _, n = string.gsub(text, "\n", "")
	return n
end

-- The file's text with the waiting changes in, the new text's ranges in
-- it, and where each change is in lines.
local function proposed(buffer: kern.Buffer): (string, { { from: number, to: number } }, { Block })
	local text = buffer:text()
	local parts, added, blocks = {}, {}, {}
	local at, length, shift = 0, 0, 0
	for _, change in proposals.changes(buffer) do
		local kept = string.sub(text, at + 1, change.from)
		table.insert(parts, kept)
		length += #kept
		table.insert(parts, change.text)
		table.insert(added, { from = length, to = length + #change.text })
		length += #change.text
		local old_line = buffer:line_of(change.from)
		local old_lines = count_lines(buffer:slice(change.from, change.to))
		local new_lines = count_lines(change.text)
		table.insert(blocks, {
			old = old_line,
			old_lines = old_lines,
			new = old_line + shift,
			new_lines = new_lines,
		})
		shift += new_lines - old_lines
		at = change.to
	end
	table.insert(parts, string.sub(text, at + 1))
	return table.concat(parts), added, blocks
end

-- Line `line` of one side as a line of the other: the same line outside
-- the changes, the start of a change's other side inside one.
local function across(blocks: { Block }, line: number, from_old: boolean): number
	local shift = 0
	for _, block in blocks do
		local start = if from_old then block.old else block.new
		local lines = if from_old then block.old_lines else block.new_lines
		local other = if from_old then block.new else block.old
		local other_lines = if from_old then block.new_lines else block.old_lines
		if line < start then
			break
		elseif line < start + lines then
			return other + math.min(line - start, math.max(other_lines - 1, 0))
		end
		shift += other_lines - lines
	end
	return line + shift
end

local function close()
	local c = open
	open = nil
	if c then
		pcall(c.view.close, c.view)
	end
end

-- Fills the side view in from the file's waiting changes, or closes it
-- once there are none.
local function refresh(c: Compare)
	local text, added, blocks = proposed(c.source)
	if #blocks == 0 then
		close()
		return
	end
	c.blocks = blocks
	c.shown:edit(function(e)
		e:replace(0, c.shown:len(), text)
	end)
	local marks: { kern.Mark } = {}
	for _, range in added do
		table.insert(marks, { from = range.from, to = range.to, style = "diff.plus" })
	end
	c.shown:decorate("compare", marks)
end

-- Scrolls `view` to `line`, moving its cursor only if it would be off
-- screen, since drawing keeps the cursor in view.
local function scroll_to(view: kern.View, line: number)
	local buffer = view:buffer()
	line = math.clamp(line, 0, buffer:line_count() - 1)
	local rows = view:size() or 1
	local selection = view:selection()
	local cursor = buffer:line_of(selection.ranges[selection.primary].head)
	if cursor < line or cursor >= line + rows then
		local at = buffer:line_start(line)
		view:set_selection({ ranges = { { anchor = at, head = at } }, primary = 1 })
	end
	view:set_scroll(line)
end

kern.on("view.scrolled", function(event: kern.ViewScrolled)
	local c = open
	if c == nil then
		return
	end
	local id = event.view:id()
	local from_old = id == c.beside:id()
	if not from_old and id ~= c.view:id() then
		return
	end
	if c.expected[id] == event.line then
		c.expected[id] = nil
		return
	end
	local other = if from_old then c.view else c.beside
	local line = across(c.blocks, event.line, from_old)
	if other:scroll() ~= line then
		c.expected[other:id()] = line
		scroll_to(other, line)
	end
end)

kern.on("view.closed", function(event)
	local c = open
	if c and (event.view == c.view:id() or event.view == c.beside:id()) then
		close()
	end
end)

-- Deciding on changes and editing the file both change what the side
-- view shows.
local function follow(buffer: kern.Buffer)
	local c = open
	if c and buffer:id() == c.source:id() then
		refresh(c)
	end
end

proposals.on_change(follow)

kern.on("buffer.changed", function(event: kern.BufferChanged)
	follow(event.buffer)
end)

kern.command({
	name = "proposal-compare",
	doc = "Show the file with its proposed changes in, side by side",
	run = function(ctx)
		if open then
			close()
			return
		end
		local source = ctx.buffer
		if #proposals.changes(source) == 0 then
			kern.echo("no proposed changes here")
			return
		end
		local shown =
			kern.create_buffer("proposal", "", { readonly = true, language = source:language() })
		local view = ctx.view:split("right", shown)
		local c: Compare = {
			source = source,
			beside = ctx.view,
			view = view,
			shown = shown,
			blocks = {},
			expected = {},
		}
		open = c
		refresh(c)
		scroll_to(view, across(c.blocks, ctx.view:scroll(), true))
		ctx.view:focus()
	end,
})

kern.keymap.bind("normal", { ["space o d"] = "proposal-compare" })

return {}
