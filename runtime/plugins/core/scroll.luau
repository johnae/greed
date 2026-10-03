-- Moving by the screenful: a page or half a page down or up, cursors and
-- all; Helix's view keys (z z, z t, z b, z j, z k, and Z to keep them going);
-- and going to the top, middle or bottom line on the screen.

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
		local at = motions.cursor(buffer, range)
		local line = math.clamp(buffer:line_of(at) + lines, 0, last)
		return motions.point(text.at_column(buffer, line, text.column(buffer, at)))
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

-- The line the primary cursor is on.
local function cursor_line(ctx: kern.Context): number
	local selection = ctx.view:selection()
	return ctx.buffer:line_of(motions.cursor(ctx.buffer, selection.ranges[selection.primary]))
end

-- Scrolls so the cursor's line is `from_top` rows below the top of the view.
local function align(name: string, doc: string, from_top: (rows: number) -> number)
	kern.command({
		name = name,
		doc = doc,
		run = function(ctx)
			ctx.view:set_scroll(math.max(cursor_line(ctx) - from_top(rows(ctx.view)), 0))
		end,
	})
end

align("center-view", "Scroll so the cursor's line is in the middle of the screen", function(n)
	return n // 2
end)
align("align-view-top", "Scroll so the cursor's line is at the top of the screen", function()
	return 0
end)
align("align-view-bottom", "Scroll so the cursor's line is at the bottom of the screen", function(n)
	return n - 1
end)

-- Scrolls the view `lines` down (up if negative) without moving the
-- cursor, unless that would take it off the screen.
local function scroll_view(ctx: kern.Context, lines: number)
	local view, buffer = ctx.view, ctx.buffer
	local last = buffer:line_count() - 1
	local top = math.clamp(view:scroll() + lines, 0, last)
	local shown = rows(view)
	view:set_scroll(top)
	local line = cursor_line(ctx)
	local inside = math.clamp(line, top, top + shown - 1)
	if inside ~= line then
		motions.each_range(ctx, function(_, range)
			local at = motions.cursor(buffer, range)
			local moved = math.clamp(buffer:line_of(at) + inside - line, 0, last)
			return motions.point(text.at_column(buffer, moved, text.column(buffer, at)))
		end)
	end
end

for _, up in { false, true } do
	kern.command({
		name = if up then "scroll-up" else "scroll-down",
		doc = if up then "Scroll the view a line up" else "Scroll the view a line down",
		run = function(ctx)
			scroll_view(ctx, (ctx.count or 1) * (if up then -1 else 1))
		end,
	})
end

-- Puts the cursor on the line `at(top, rows)` of the view, at its first
-- character that isn't a space.
local function to_window(name: string, doc: string, at: (top: number, rows: number) -> number)
	kern.command({
		name = name,
		doc = doc,
		run = function(ctx)
			local buffer = ctx.buffer
			local line =
				math.clamp(at(ctx.view:scroll(), rows(ctx.view)), 0, buffer:line_count() - 1)
			ctx.view:set_selection({
				ranges = { motions.point(text.first_non_blank(buffer, buffer:line_start(line))) },
				primary = 1,
			})
		end,
	})
end

to_window("goto-window-top", "Move to the top line on the screen", function(top)
	return top
end)
to_window("goto-window-center", "Move to the middle line on the screen", function(top, n)
	return top + (n - 1) // 2
end)
to_window("goto-window-bottom", "Move to the bottom line on the screen", function(top, n)
	return top + n - 1
end)

-- The view keys after z, and in the sticky view mode Z starts, where they
-- act until esc.
local VIEW_KEYS: { [string]: string } = {
	z = "center-view",
	c = "center-view",
	t = "align-view-top",
	b = "align-view-bottom",
	j = "scroll-down",
	k = "scroll-up",
	down = "scroll-down",
	up = "scroll-up",
	["ctrl-f"] = "page-down",
	["ctrl-b"] = "page-up",
	["ctrl-d"] = "half-page-down",
	["ctrl-u"] = "half-page-up",
}

kern.command({
	name = "view-mode",
	doc = "Keys for the view until esc: center, top, bottom, scroll",
	run = function()
		kern.mode.set("view")
		kern.echo("z c center  t top  b bottom  j k scroll  esc")
	end,
})

kern.command({
	name = "view-mode-leave",
	doc = "Back from the view mode",
	run = function()
		kern.mode.set("normal")
	end,
})

local M = { keys = {} :: { [string]: string } }
for key, command in VIEW_KEYS do
	M.keys[`z {key}`] = command
end
M.keys.Z = "view-mode"
kern.keymap.bind("view", VIEW_KEYS)
kern.keymap.bind("view", { esc = "view-mode-leave" })
kern.keymap.isolate("view")
kern.keymap.fallback("view", "view-mode-leave")

return M
