-- Cursor movement and selection commands in the style of Helix normal mode.
--
-- Every motion runs once per range, so multiple selections just work. A
-- cursor is an empty range; a motion like `next-word` selects the text it
-- moves over, with the anchor where it started.

local kern = require("@kern")
local text = require("./text")

type Buffer = kern.Buffer
type Range = kern.Range
type Selection = kern.Selection

-- Finds a new position from a cursor's head.
type Target = (buffer: Buffer, head: number) -> number

local M = {}

-- Replaces every range with `f(buffer, range)` and sets the result as the
-- view's selection.
local function each_range(ctx: kern.Context, f: (buffer: Buffer, range: Range) -> Range)
	local sel = ctx.view:selection()
	for i, range in sel.ranges do
		sel.ranges[i] = f(ctx.buffer, range)
	end
	ctx.view:set_selection(sel)
end

local function point(pos: number): Range
	return { anchor = pos, head = pos }
end

-- `target` applied `count` times (once without a count).
local function repeated(target: Target, count: number?): Target
	return function(buffer, head)
		for _ = 1, count or 1 do
			head = target(buffer, head)
		end
		return head
	end
end

-- Registers a command that moves each cursor to `target(buffer, head)`.
local function move(name: string, doc: string, target: Target)
	kern.command({
		name = name,
		doc = doc,
		run = function(ctx)
			local to = repeated(target, ctx.count)
			each_range(ctx, function(buffer, range)
				return point(to(buffer, range.head))
			end)
		end,
	})
end

-- Registers a command that moves each head to `target(buffer, head)` and
-- keeps the anchor where it is, growing or shrinking the selection.
local function extend(name: string, doc: string, target: Target)
	kern.command({
		name = name,
		doc = doc,
		run = function(ctx)
			local to = repeated(target, ctx.count)
			each_range(ctx, function(buffer, range)
				return { anchor = range.anchor, head = to(buffer, range.head) }
			end)
		end,
	})
end

-- Registers a command that selects from each head to `target(buffer, head)`.
local function select_to(name: string, doc: string, target: Target)
	kern.command({
		name = name,
		doc = doc,
		run = function(ctx)
			local skip = repeated(target, (ctx.count or 1) - 1)
			each_range(ctx, function(buffer, range)
				local head = skip(buffer, range.head)
				return { anchor = head, head = target(buffer, head) }
			end)
		end,
	})
end

-- Vertical moves aim for the column each cursor started from, so moving
-- through a short line doesn't lose it. The goal columns are kept while
-- nothing but vertical moves has touched the selection.
local goal: { view: number?, buffer: number?, selection: Selection?, columns: { number } } = {
	columns = {},
}

local function same_selection(a: Selection, b: Selection?): boolean
	if b == nil or #a.ranges ~= #b.ranges then
		return false
	end
	for i, r in a.ranges do
		if r.anchor ~= b.ranges[i].anchor or r.head ~= b.ranges[i].head then
			return false
		end
	end
	return true
end

local function vertical(name: string, doc: string, delta: number, keep_anchor: boolean)
	kern.command({
		name = name,
		doc = doc,
		run = function(ctx)
			local sel = ctx.view:selection()
			local buffer = ctx.buffer
			local same_place = goal.view == ctx.view:id() and goal.buffer == buffer:id()
			if not same_place or not same_selection(sel, goal.selection) then
				goal.columns = {}
				for i, range in sel.ranges do
					goal.columns[i] = text.column(buffer, range.head)
				end
			end
			-- Folded lines are stepped over, like the one line they look like.
			local hidden = ctx.view:hidden_lines()
			local function is_hidden(line: number): boolean
				for _, lines in hidden do
					if line >= lines.from and line <= lines.to then
						return true
					end
				end
				return false
			end
			local last_line = buffer:line_count() - 1
			for i, range in sel.ranges do
				local line = buffer:line_of(range.head)
				for _ = 1, ctx.count or 1 do
					local next = line + delta
					while next >= 0 and next <= last_line and is_hidden(next) do
						next += delta
					end
					if next < 0 or next > last_line then
						break
					end
					line = next
				end
				local head = text.at_column(buffer, line, goal.columns[i])
				sel.ranges[i] = { anchor = if keep_anchor then range.anchor else head, head = head }
			end
			ctx.view:set_selection(sel)
			goal.view = ctx.view:id()
			goal.buffer = buffer:id()
			goal.selection = ctx.view:selection()
		end,
	})
end

local function left(buffer: Buffer, head: number): number
	return math.max(buffer:line_start(buffer:line_of(head)), buffer:prev_char(head))
end

local function right(buffer: Buffer, head: number): number
	return math.min(buffer:line_end(buffer:line_of(head)), buffer:next_char(head))
end

local function line_start(buffer: Buffer, head: number): number
	return buffer:line_start(buffer:line_of(head))
end

local function line_end(buffer: Buffer, head: number): number
	return buffer:line_end(buffer:line_of(head))
end

local function buffer_start(): number
	return 0
end

local function buffer_end(buffer: Buffer): number
	return buffer:len()
end

move("move-left", "Move one character left", left)
move("move-right", "Move one character right", right)
vertical("move-up", "Move one line up", -1, false)
vertical("move-down", "Move one line down", 1, false)
move("line-start", "Move to the start of the line", line_start)
move("line-end", "Move to the end of the line", line_end)
move("goto-end", "Move to the end of the buffer", buffer_end)
move("move-word-right", "Move to the start of the next word", text.next_word_start)
move("move-word-left", "Move to the start of the previous word", text.prev_word_start)

-- The same moves, keeping the anchor: shift-arrows in most editors.
extend("extend-left", "Extend the selection one character left", left)
extend("extend-right", "Extend the selection one character right", right)
vertical("extend-up", "Extend the selection one line up", -1, true)
vertical("extend-down", "Extend the selection one line down", 1, true)
extend("extend-line-start", "Extend the selection to the start of the line", line_start)
extend("extend-line-end", "Extend the selection to the end of the line", line_end)
extend("extend-start", "Extend the selection to the start of the buffer", buffer_start)
extend("extend-end", "Extend the selection to the end of the buffer", buffer_end)
extend("extend-word-right", "Extend the selection to the next word", text.next_word_start)
extend("extend-word-left", "Extend the selection to the previous word", text.prev_word_start)

select_to("next-word", "Select to the start of the next word", text.next_word_start)
select_to("prev-word", "Select to the start of the previous word", text.prev_word_start)
select_to("word-end", "Select to the end of the word", text.word_end)
select_to(
	"next-big-word",
	"Select to the start of the next WORD (punctuation included)",
	text.next_big_word_start
)
select_to("prev-big-word", "Select to the start of the previous WORD", text.prev_big_word_start)
select_to("big-word-end", "Select to the end of the WORD", text.big_word_end)
move(
	"first-non-blank",
	"Move to the first character on the line that isn't a space",
	text.first_non_blank
)

-- Moves every cursor to the start of 1-based `line`, kept inside the buffer.
local function goto_line(ctx: kern.Context, line: number)
	local buffer = ctx.buffer
	local at = buffer:line_start(math.clamp(line - 1, 0, buffer:line_count() - 1))
	ctx.view:set_selection({ ranges = { point(at) }, primary = 1 })
end

kern.command({
	name = "goto-start",
	doc = "Move to the start of the buffer, or with a count, to that line",
	run = function(ctx)
		goto_line(ctx, ctx.count or 1)
	end,
})

kern.command({
	name = "goto-line",
	doc = "Move to the line given as a count, or the last line",
	run = function(ctx)
		goto_line(ctx, ctx.count or ctx.buffer:line_count())
	end,
})

-- Where the `count`-th `char` after (or before) `head` on its line is, or
-- nil. With `till`, the place next to it instead.
local function find_char(
	buffer: Buffer,
	head: number,
	char: string,
	forward: boolean,
	till: boolean,
	count: number
): number?
	local line = buffer:line_of(head)
	local start, stop = buffer:line_start(line), buffer:line_end(line)
	local at = head
	for _ = 1, count do
		repeat
			if forward then
				at = buffer:next_char(at)
				if at >= stop then
					return nil
				end
			else
				if at <= start then
					return nil
				end
				at = buffer:prev_char(at)
			end
		until buffer:char_at(at) == char
	end
	if forward then
		return if till then at else buffer:next_char(at)
	end
	return if till then buffer:next_char(at) else at
end

local function find_command(
	name: string,
	doc: string,
	forward: boolean,
	till: boolean,
	keep_anchor: boolean?
)
	kern.command({
		name = name,
		doc = doc,
		run = function(ctx)
			local char = kern.next_key()
			if utf8.len(char) ~= 1 then
				return
			end
			each_range(ctx, function(buffer, range)
				local to = find_char(buffer, range.head, char, forward, till, ctx.count or 1)
				local anchor = if keep_anchor then range.anchor else range.head
				return if to then { anchor = anchor, head = to } else range
			end)
		end,
	})
end

find_command("find-next-char", "Select up to and including the next character typed", true, false)
find_command("till-next-char", "Select up to the next character typed", true, true)
find_command("find-prev-char", "Select back to the previous character typed", false, false)
find_command(
	"till-prev-char",
	"Select back to just after the previous character typed",
	false,
	true
)
find_command(
	"extend-find-next-char",
	"Extend to and including the next character typed",
	true,
	false,
	true
)
find_command("extend-till-next-char", "Extend up to the next character typed", true, true, true)
find_command(
	"extend-find-prev-char",
	"Extend back to the previous character typed",
	false,
	false,
	true
)
find_command(
	"extend-till-prev-char",
	"Extend back to just after the previous character typed",
	false,
	true,
	true
)

extend("extend-word-end", "Extend the selection to the end of the word", text.word_end)
extend("extend-big-word-right", "Extend the selection to the next WORD", text.next_big_word_start)
extend(
	"extend-big-word-left",
	"Extend the selection to the previous WORD",
	text.prev_big_word_start
)
extend("extend-big-word-end", "Extend the selection to the end of the WORD", text.big_word_end)
extend(
	"extend-first-non-blank",
	"Extend the selection to the first character that isn't a space",
	text.first_non_blank
)

kern.command({
	name = "extend-goto-line",
	doc = "Extend the selection to the line given as a count, or the last line",
	run = function(ctx)
		local buffer = ctx.buffer
		local line = math.clamp((ctx.count or buffer:line_count()) - 1, 0, buffer:line_count() - 1)
		each_range(ctx, function(_, range)
			return { anchor = range.anchor, head = buffer:line_start(line) }
		end)
	end,
})

kern.command({
	name = "match-bracket",
	doc = "Move to the matching bracket, or the closing one of the pair around the cursor",
	run = function(ctx)
		each_range(ctx, function(buffer, range)
			local to = text.matching_bracket(buffer, range.head)
			return if to then point(to) else range
		end)
	end,
})

kern.command({
	name = "select-line",
	doc = "Select the whole line, including its line break; again, the next line too",
	run = function(ctx)
		for _ = 1, ctx.count or 1 do
			each_range(ctx, function(buffer, range)
				local first = buffer:line_of(math.min(range.anchor, range.head))
				local last = buffer:line_of(math.max(range.anchor, range.head))
				local stop = buffer:len()
				if last + 1 < buffer:line_count() then
					stop = buffer:line_start(last + 1)
				end
				return { anchor = buffer:line_start(first), head = stop }
			end)
		end
	end,
})

kern.command({
	name = "select-all",
	doc = "Select the whole buffer",
	run = function(ctx)
		ctx.view:set_selection({ ranges = { { anchor = 0, head = ctx.buffer:len() } }, primary = 1 })
	end,
})

kern.command({
	name = "collapse",
	doc = "Collapse each selection to a cursor at its head",
	run = function(ctx)
		each_range(ctx, function(_, range)
			return point(range.head)
		end)
	end,
})

kern.command({
	name = "flip",
	doc = "Swap the anchor and head of each selection",
	run = function(ctx)
		each_range(ctx, function(_, range)
			return { anchor = range.head, head = range.anchor }
		end)
	end,
})

-- The lines each selection touches, each once, in order.
function M.selected_lines(ctx: kern.Context): { number }
	local buffer = ctx.buffer
	local seen, lines = {}, {}
	for _, range in ctx.view:selection().ranges do
		local to = math.max(range.anchor, range.head)
		local first, last = buffer:line_of(math.min(range.anchor, range.head)), buffer:line_of(to)
		-- A selection ending at a line's start, like `x` makes, stops before it.
		if last > first and to == buffer:line_start(last) then
			last -= 1
		end
		for line = first, last do
			if not seen[line] then
				seen[line] = true
				table.insert(lines, line)
			end
		end
	end
	table.sort(lines)
	return lines
end

-- Inserts `text` at each of `points`, moving the selections along so that
-- ones that began at a point keep the new text inside them.
function M.insert_at(ctx: kern.Context, points: { number }, text: string)
	local function moved(pos: number): number
		local before = 0
		for _, p in points do
			if p < pos then
				before += 1
			end
		end
		return pos + before * #text
	end
	local selection = ctx.view:selection()
	for i, range in selection.ranges do
		selection.ranges[i] = { anchor = moved(range.anchor), head = moved(range.head) }
	end
	ctx.buffer:edit(function(e)
		for _, p in points do
			e:insert(p, text)
		end
		e:select(selection)
	end)
end

M.each_range = each_range
M.point = point
return M
