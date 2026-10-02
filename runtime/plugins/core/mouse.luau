-- The mouse: a click focuses the view under it and puts the cursor there,
-- or runs the action of a mark's text (a button), dragging selects, and
-- the wheel scrolls the view under it. A plugin can take the mouse in
-- buffers of its own kind with `claim`, as the terminal does to pass it on
-- to the program in it.

local kern = require("@kern")

local M = {}

--- How many lines a turn of the wheel scrolls.
M.lines = 3

export type Handler = (event: kern.MouseEvent) -> boolean

local claims: { [string]: Handler } = {}

--- Gives mouse events over buffers of `kind` to `handler` first; when it
--- returns true, nothing else is done with them.
function M.claim(kind: string, handler: Handler)
	claims[kind] = handler
end

local function point(view: kern.View, pos: number, anchor: number?)
	view:set_selection({ ranges = { { anchor = anchor or pos, head = pos } }, primary = 1 })
end

--- Scrolls `view` by `lines` (up when negative), bringing the cursor onto
--- the screen with it, since drawing would scroll back to the cursor.
function M.scroll(view: kern.View, lines: number)
	local buffer = view:buffer()
	local last = math.max(buffer:line_count() - 1, 0)
	local top = math.clamp(view:scroll() + lines, 0, last)
	view:set_scroll(top)
	local rows = view:size() or 1
	local selection = view:selection()
	local line = buffer:line_of(selection.ranges[selection.primary].head)
	local bottom = math.min(top + rows - 1, last)
	if line < top then
		point(view, buffer:line_start(top))
	elseif line > bottom then
		point(view, buffer:line_start(bottom))
	end
end

-- Where the left button went down, while it's down: the view and the
-- place in its buffer, which a drag selects from.
local pressed: { view: number, pos: number }? = nil

kern.on("mouse", function(event: kern.MouseEvent)
	local view = event.view
	if view == nil then
		return
	end
	-- A mark's text with an action is a button: the click runs it.
	if event.kind == "press" and event.button == "left" and event.action and event.pos then
		view:focus()
		point(view, event.pos)
		kern.run(event.action)
		return
	end
	local claim = claims[view:buffer():kind()]
	if claim and claim(event) then
		return
	end
	if event.kind == "press" and event.button == "left" then
		if kern.view():id() ~= view:id() then
			view:focus()
		end
		if event.pos then
			point(view, event.pos)
			pressed = { view = view:id(), pos = event.pos }
		end
	elseif event.kind == "drag" and event.button == "left" then
		if pressed and pressed.view == view:id() and event.pos then
			point(view, event.pos, pressed.pos)
		end
	elseif event.kind == "release" then
		pressed = nil
	elseif event.kind == "scroll" and (event.dir == "up" or event.dir == "down") then
		M.scroll(view, if event.dir == "up" then -M.lines else M.lines)
	end
end)

return M
