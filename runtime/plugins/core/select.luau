-- Working with many selections at once, like Helix:
--
--   s        select every match of a regex inside the selections
--   S        split the selections at every match of a regex
--   alt-s    split the selections into lines
--   K        keep the selections that match a regex; alt-K removes them
--   C        add a selection on the next line; alt-C on the line above
--   ,        keep only the primary selection; alt-, removes it
--   ( and )  make the previous or next selection the primary one
--   X        extend to whole lines; alt-x shrink to the whole lines inside
--   alt-_    merge selections that touch
--   _ and &  trim spaces off the selections, line them up at one column
--   alt-( )  rotate what the selections hold
--   ctrl-a   add to the number at each cursor; ctrl-x subtract
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

-- The start of `line`, or the end of the buffer past its last line.
local function line_start(buffer: kern.Buffer, line: number): number
	return if line < buffer:line_count() then buffer:line_start(line) else buffer:len()
end

-- The lines `range` touches: its first, and the one its last character is on.
local function lines_of(buffer: kern.Buffer, range: kern.Range): (number, number)
	local from, to = span(range)
	return buffer:line_of(from), buffer:line_of(if to > from then buffer:prev_char(to) else to)
end

command("extend-to-line-bounds", "Extend each selection to whole lines", function(ctx)
	local buffer, selection = ctx.buffer, ctx.view:selection()
	for i, range in selection.ranges do
		local first, last = lines_of(buffer, range)
		selection.ranges[i] =
			{ anchor = buffer:line_start(first), head = line_start(buffer, last + 1) }
	end
	ctx.view:set_selection(selection)
end)

command("shrink-to-line-bounds", "Shrink each selection to the whole lines inside it", function(ctx)
	local buffer, selection = ctx.buffer, ctx.view:selection()
	for i, range in selection.ranges do
		local from, to = span(range)
		local first, last = lines_of(buffer, range)
		if buffer:line_start(first) < from then
			first += 1
		end
		if line_start(buffer, last + 1) > to then
			last -= 1
		end
		if first <= last then
			selection.ranges[i] =
				{ anchor = buffer:line_start(first), head = line_start(buffer, last + 1) }
		end
	end
	ctx.view:set_selection(selection)
end)

command(
	"merge-selections",
	"Merge all selections into one, from the first to the last",
	function(ctx)
		local ranges = ctx.view:selection().ranges
		local from, _ = span(ranges[1])
		local _, to = span(ranges[#ranges])
		set(ctx.view, { { anchor = from, head = to } })
	end
)

command("merge-consecutive-selections", "Merge selections that touch or overlap", function(ctx)
	local merged: Ranges = {}
	for _, range in ctx.view:selection().ranges do
		local from, to = span(range)
		local last = merged[#merged]
		if last and from <= last.head then
			last.head = math.max(last.head, to)
		else
			table.insert(merged, { anchor = from, head = to })
		end
	end
	set(ctx.view, merged)
end)

-- Replaces the text of each selection with `change(i, text)` in one edit,
-- keeping each selection around its new text.
local function replace_each(ctx: kern.Context, change: (number, string) -> string)
	local buffer, selection = ctx.buffer, ctx.view:selection()
	buffer:edit(function(e)
		local shift = 0
		for i, range in selection.ranges do
			local from, to = span(range)
			local new = change(i, buffer:slice(from, to))
			e:replace(from, to, new)
			selection.ranges[i] = { anchor = from + shift, head = from + shift + #new }
			shift += #new - (to - from)
		end
		e:select(selection)
	end)
end

command(
	"trim-selections",
	"Trim the spaces and line breaks off both ends of each selection",
	function(ctx)
		local buffer, selection = ctx.buffer, ctx.view:selection()
		local kept: Ranges = {}
		for _, range in selection.ranges do
			local from, to = span(range)
			local text = buffer:slice(from, to)
			local lead = #(string.match(text, "^%s*") :: string)
			local trail = #(string.match(text, "%s*$") :: string)
			if lead < #text then
				table.insert(kept, { anchor = from + lead, head = to - trail })
			end
		end
		set(ctx.view, kept)
	end
)

command(
	"align-selections",
	"Line the selections up at one column, with spaces before them",
	function(ctx)
		local buffer = ctx.buffer
		local ranges = ctx.view:selection().ranges
		local widest = 0
		for _, range in ranges do
			widest = math.max(widest, column(buffer, (span(range))))
		end
		buffer:edit(function(e)
			local seen: { [number]: boolean } = {}
			for _, range in ranges do
				local from = span(range)
				local line = buffer:line_of(from)
				-- One selection per line moves; Helix aligns columns, not every selection.
				if not seen[line] then
					seen[line] = true
					local pad = widest - column(buffer, from)
					if pad > 0 then
						e:insert(from, string.rep(" ", pad))
					end
				end
			end
		end)
	end
)

for _, back in { false, true } do
	command(
		if back then "rotate-contents-back" else "rotate-contents",
		if back
			then "Move each selection's text to the selection before it, the first's to the last"
			else "Move each selection's text to the selection after it, the last's to the first",
		function(ctx)
			local buffer, ranges = ctx.buffer, ctx.view:selection().ranges
			local texts = {}
			for i, range in ranges do
				texts[i] = buffer:slice(span(range))
			end
			local n = #texts
			replace_each(ctx, function(i)
				return texts[if back then i % n + 1 else (i - 2) % n + 1]
			end)
		end
	)
end

-- The number at or after `pos` on its line, as Helix's ctrl-a finds it:
-- where it starts and ends, and its value. Decimal, with a sign, or hex.
local function number_at(buffer: kern.Buffer, pos: number): (number?, number?, number?, boolean?)
	local line = buffer:line_of(pos)
	local start = buffer:line_start(line)
	local text = buffer:slice(start, buffer:line_end(line))
	local at = pos - start + 1
	local init = 1
	while true do
		local from, to = string.find(text, "%-?0[xX]%x+", init)
		local dfrom, dto = string.find(text, "%-?%d+", init)
		if dfrom and (from == nil or dfrom < from) then
			from, to = dfrom, dto
		end
		if from == nil or to == nil then
			return nil, nil, nil, nil
		end
		local first, last = from :: number, to :: number
		if last >= at then
			local literal = string.sub(text, first, last)
			local hex = string.find(literal, "[xX]") ~= nil
			local sign = if string.sub(literal, 1, 1) == "-" then -1 else 1
			local value = if hex
				then sign * (tonumber(string.match(literal, "%x+$"), 16) :: number)
				else tonumber(literal)
			return start + first - 1, start + last, value, hex
		end
		init = last + 1
	end
end

local function format_number(value: number, hex: boolean?): string
	if not hex then
		return tostring(value)
	end
	return (if value < 0 then "-" else "") .. string.format("0x%x", math.abs(value))
end

for _, down in { false, true } do
	command(
		if down then "decrement" else "increment",
		if down
			then "Subtract the count (or 1) from the number at each cursor"
			else "Add the count (or 1) to the number at each cursor",
		function(ctx)
			local buffer, selection = ctx.buffer, ctx.view:selection()
			local step = (ctx.count or 1) * (if down then -1 else 1)
			buffer:edit(function(e)
				local shift = 0
				for i, range in selection.ranges do
					local from, to, value, hex = number_at(buffer, (span(range)))
					if from and to and value then
						local text = format_number(value + step, hex)
						e:replace(from, to, text)
						selection.ranges[i] = { anchor = from + shift, head = from + shift + #text }
						shift += #text - (to - from)
					end
				end
				e:select(selection)
			end)
		end
	)
end

return {}
