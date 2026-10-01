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

-- Registers a command that moves each cursor to `target(buffer, head)`.
local function move(name: string, doc: string, target: Target)
	kern.command({
		name = name,
		doc = doc,
		run = function(ctx)
			each_range(ctx, function(buffer, range)
				return point(target(buffer, range.head))
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
			each_range(ctx, function(buffer, range)
				return { anchor = range.anchor, head = target(buffer, range.head) }
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
			each_range(ctx, function(buffer, range)
				return { anchor = range.head, head = target(buffer, range.head) }
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
			for i, range in sel.ranges do
				local last_line = buffer:line_count() - 1
				local line = math.clamp(buffer:line_of(range.head) + delta, 0, last_line)
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
move("goto-start", "Move to the start of the buffer", buffer_start)
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

kern.command({
	name = "select-line",
	doc = "Select the whole line, including its line break",
	run = function(ctx)
		each_range(ctx, function(buffer, range)
			local first = buffer:line_of(math.min(range.anchor, range.head))
			local last = buffer:line_of(math.max(range.anchor, range.head))
			local stop = buffer:len()
			if last + 1 < buffer:line_count() then
				stop = buffer:line_start(last + 1)
			end
			return { anchor = buffer:line_start(first), head = stop }
		end)
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

M.each_range = each_range
M.point = point
return M
