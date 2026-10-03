-- Working with many selections at once, like Helix:
--
--   s        select every match of a regex inside the selections
--   S        split the selections at every match of a regex
--   alt-s    split the selections into lines
--   K        keep the selections that match a regex; alt-K removes them
--   C        add a selection on the next line; alt-C on the line above
--   ,        keep only the primary selection; alt-, removes it
--   ( and )  make the previous or next selection the primary one
--
-- s, S, K and alt-K show the result as you type the regex. Typing, deleting
-- and pasting then work on every selection.

local kern = require("@kern")
local prompt = require("./prompt")
local search = require("./search")

type Ranges = { kern.Range }

local function span(range: kern.Range): (number, number)
	return math.min(range.anchor, range.head), math.max(range.anchor, range.head)
end

local function set(view: kern.View, ranges: Ranges, primary: number?)
	if #ranges > 0 then
		view:set_selection({ ranges = ranges, primary = math.clamp(primary or 1, 1, #ranges) })
	end
end

-- The matches of `pattern` inside `range`; errors on a bad pattern.
local function matches(
	buffer: kern.Buffer,
	pattern: string,
	range: kern.Range
): { { from: number, to: number } }
	local from, to = span(range)
	local found, err = buffer:find_all(pattern, from, to)
	if found == nil then
		error(err, 0)
	end
	return found
end

-- Asks for a regex, showing what `apply` makes of the selections as it's
-- typed. A pattern that doesn't parse yet, or leaves nothing selected,
-- shows the selections as they were.
local function with_regex(ctx: kern.Context, title: string, apply: (Ranges, string) -> Ranges)
	local view = ctx.view
	local origin = view:selection()
	local function preview(pattern: string)
		view:set_selection(origin)
		if pattern ~= "" then
			local ok, ranges = pcall(apply, origin.ranges, search.smart_case(pattern))
			if ok then
				set(view, ranges)
			end
		end
	end
	prompt.open({
		title = title,
		on_change = preview,
		-- Nothing typed means the last search, so `*` then `s` works.
		on_submit = function(pattern)
			preview(if pattern == "" then search.last() or "" else pattern)
		end,
		on_cancel = function()
			view:set_selection(origin)
		end,
	})
end

-- The pieces of each range between matches of `pattern`.
local function split(buffer: kern.Buffer, ranges: Ranges, pattern: string): Ranges
	local out = {}
	for _, range in ranges do
		local start, finish = span(range)
		for _, m in matches(buffer, pattern, range) do
			if m.from > start then
				table.insert(out, { anchor = start, head = m.from })
			end
			start = math.max(start, m.to)
		end
		if finish > start then
			table.insert(out, { anchor = start, head = finish })
		end
	end
	return out
end

local function keep(ctx: kern.Context, keep_matching: boolean)
	with_regex(ctx, if keep_matching then "keep" else "remove", function(ranges, pattern)
		local out = {}
		for _, range in ranges do
			if (#matches(ctx.buffer, pattern, range) > 0) == keep_matching then
				table.insert(out, range)
			end
		end
		return out
	end)
end

-- The column of `pos` on its line, in characters.
local function column(buffer: kern.Buffer, pos: number): number
	local at, n = buffer:line_start(buffer:line_of(pos)), 0
	while at < pos do
		at = buffer:next_char(at)
		n += 1
	end
	return n
end

-- The position `n` characters into `line`, or its end if it's shorter.
local function at_column(buffer: kern.Buffer, line: number, n: number): number
	local pos, finish = buffer:line_start(line), buffer:line_end(line)
	for _ = 1, n do
		if pos >= finish then
			break
		end
		pos = buffer:next_char(pos)
	end
	return pos
end

-- Adds a copy of each selection on the next lines `delta` away (1 is down,
-- -1 up) that are long enough for it, at the same columns. The copy of the
-- primary selection becomes primary, so repeating goes on.
local function copy_lines(ctx: kern.Context, delta: number)
	local buffer, selection = ctx.buffer, ctx.view:selection()
	local ranges = table.clone(selection.ranges)
	local new = selection.ranges[selection.primary]
	local function fits(line: number, col: number): boolean
		return 0 <= line
			and line < buffer:line_count()
			and col <= column(buffer, buffer:line_end(line))
	end
	for i, range in selection.ranges do
		local anchor_col, head_col = column(buffer, range.anchor), column(buffer, range.head)
		local anchor_line, head_line = buffer:line_of(range.anchor), buffer:line_of(range.head)
		local found = false
		repeat
			anchor_line += delta
			head_line += delta
			found = fits(anchor_line, anchor_col) and fits(head_line, head_col)
			local inside = math.min(anchor_line, head_line) >= 0
				and math.max(anchor_line, head_line) < buffer:line_count()
		until found or not inside
		if found then
			local copy = {
				anchor = at_column(buffer, anchor_line, anchor_col),
				head = at_column(buffer, head_line, head_col),
			}
			table.insert(ranges, copy)
			if i == selection.primary then
				new = copy
			end
		end
	end
	-- Setting the selection sorts and merges it, so look the copy up after.
	ctx.view:set_selection({ ranges = ranges, primary = 1 })
	local sorted = ctx.view:selection().ranges
	local new_from, new_to = span(new)
	for i, range in sorted do
		local from, to = span(range)
		if from <= new_from and new_to <= to then
			set(ctx.view, sorted, i)
			return
		end
	end
end

local function rotate(ctx: kern.Context, delta: number)
	local selection = ctx.view:selection()
	set(ctx.view, selection.ranges, (selection.primary - 1 + delta) % #selection.ranges + 1)
end

local function command(name: string, doc: string, run: (ctx: kern.Context) -> ())
	kern.command({ name = name, doc = doc, run = run })
end

command("select-regex", "Select every match of a regex inside the selections", function(ctx)
	with_regex(ctx, "select", function(ranges, pattern)
		local out = {}
		for _, range in ranges do
			for _, m in matches(ctx.buffer, pattern, range) do
				if m.to > m.from then
					table.insert(out, { anchor = m.from, head = m.to })
				end
			end
		end
		return out
	end)
end)

command("split-regex", "Split the selections at every match of a regex", function(ctx)
	with_regex(ctx, "split", function(ranges, pattern)
		return split(ctx.buffer, ranges, pattern)
	end)
end)

command("split-lines", "Split the selections into lines", function(ctx)
	set(ctx.view, split(ctx.buffer, ctx.view:selection().ranges, "\\r?\\n"))
end)

command("keep-matching", "Keep the selections that match a regex", function(ctx)
	keep(ctx, true)
end)

command("remove-matching", "Remove the selections that match a regex", function(ctx)
	keep(ctx, false)
end)

command(
	"copy-selection-down",
	"Add a selection on the next line, at the same columns",
	function(ctx)
		for _ = 1, ctx.count or 1 do
			copy_lines(ctx, 1)
		end
	end
)

command("copy-selection-up", "Add a selection on the line above, at the same columns", function(ctx)
	for _ = 1, ctx.count or 1 do
		copy_lines(ctx, -1)
	end
end)

command("keep-primary", "Keep only the primary selection", function(ctx)
	local selection = ctx.view:selection()
	set(ctx.view, { selection.ranges[selection.primary] })
end)

command("remove-primary", "Remove the primary selection", function(ctx)
	local selection = ctx.view:selection()
	if #selection.ranges > 1 then
		local ranges = table.clone(selection.ranges)
		table.remove(ranges, selection.primary)
		set(ctx.view, ranges, selection.primary)
	end
end)

command("rotate-primary-back", "Make the previous selection the primary one", function(ctx)
	rotate(ctx, -1)
end)

command("rotate-primary", "Make the next selection the primary one", function(ctx)
	rotate(ctx, 1)
end)

return {}
