-- Moving by the screenful: a page or half a page down or up, cursors and
-- all, and centering the view on the cursor.

local kern = require("@kern")
local motions = require("./motions")
local text = require("./text")

-- How many lines the view showed when it was last drawn.
local function rows(view: kern.View): number
	local buffer = view:buffer()
	local first, last = view:visible()
	return buffer:line_of(last) - buffer:line_of(first) + 1
end

-- Moves the view and every cursor `lines` down (up if negative), keeping
-- their columns.
local function scroll_by(ctx: kern.Context, lines: number)
	local view, buffer = ctx.view, ctx.buffer
	local last = buffer:line_count() - 1
	view:set_scroll(math.clamp(view:scroll() + lines, 0, last))
	motions.each_range(ctx, function(_, range)
		local line = math.clamp(buffer:line_of(range.head) + lines, 0, last)
		return motions.point(text.at_column(buffer, line, text.column(buffer, range.head)))
	end)
end

local function command(name: string, doc: string, lines: (rows: number) -> number)
	kern.command({
		name = name,
		doc = doc,
		run = function(ctx)
			scroll_by(ctx, lines(rows(ctx.view)))
		end,
	})
end

command("page-down", "Move a screen down", function(n)
	return n
end)
command("page-up", "Move a screen up", function(n)
	return -n
end)
command("half-page-down", "Move half a screen down", function(n)
	return n // 2
end)
command("half-page-up", "Move half a screen up", function(n)
	return -(n // 2)
end)

kern.command({
	name = "center-view",
	doc = "Scroll so the cursor's line is in the middle of the screen",
	run = function(ctx)
		local selection = ctx.view:selection()
		local line = ctx.buffer:line_of(selection.ranges[selection.primary].head)
		ctx.view:set_scroll(math.max(line - rows(ctx.view) // 2, 0))
	end,
})

return {}
