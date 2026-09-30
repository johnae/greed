-- Cursor movement and selection commands in the style of Helix normal mode.
--
-- Every motion runs once per range, so multiple selections just work. A
-- cursor is an empty range; a motion like `next-word` selects the text it
-- moves over, with the anchor where it started.

local kern = require("kern")
local text = require("./text")

local M = {}

-- Replaces every range with `f(buffer, range)` and sets the result as the
-- view's selection.
local function each_range(ctx, f)
	local sel = ctx.view:selection()
	for i, range in sel.ranges do
		sel.ranges[i] = f(ctx.buffer, range)
	end
	ctx.view:set_selection(sel)
end

local function point(pos)
	return { anchor = pos, head = pos }
end

-- Registers a command that moves each cursor to `target(buffer, head)`.
local function move(name, doc, target)
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

-- Registers a command that selects from each head to `target(buffer, head)`.
local function select_to(name, doc, target)
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
local goal = { selection = nil :: any, columns = {} :: { number } }

local function same_selection(a, b): boolean
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

local function vertical(name, doc, delta)
	kern.command({
		name = name,
		doc = doc,
		run = function(ctx)
			local sel = ctx.view:selection()
			local buffer = ctx.buffer
			if not same_selection(sel, goal.selection) then
				goal.columns = {}
				for i, range in sel.ranges do
					goal.columns[i] = text.column(buffer, range.head)
				end
			end
			for i, range in sel.ranges do
				local last_line = buffer:line_count() - 1
				local line = math.clamp(buffer:line_of(range.head) + delta, 0, last_line)
				sel.ranges[i] = point(text.at_column(buffer, line, goal.columns[i]))
			end
			ctx.view:set_selection(sel)
			goal.selection = ctx.view:selection()
		end,
	})
end

move("move-left", "Move one character left", function(buffer, head)
	return math.max(buffer:line_start(buffer:line_of(head)), buffer:prev_char(head))
end)

move("move-right", "Move one character right", function(buffer, head)
	return math.min(buffer:line_end(buffer:line_of(head)), buffer:next_char(head))
end)

vertical("move-up", "Move one line up", -1)
vertical("move-down", "Move one line down", 1)

move("line-start", "Move to the start of the line", function(buffer, head)
	return buffer:line_start(buffer:line_of(head))
end)

move("line-end", "Move to the end of the line", function(buffer, head)
	return buffer:line_end(buffer:line_of(head))
end)

move("goto-start", "Move to the start of the buffer", function()
	return 0
end)

move("goto-end", "Move to the end of the buffer", function(buffer)
	return buffer:len()
end)

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
