-- The mouse: a click focuses the view under it and puts the cursor there,
-- or runs the action of a mark's text (a button), dragging selects, a
-- double or triple click selects the word or line, shift extends and alt
-- adds a cursor, and the wheel scrolls the view under it. A plugin can
-- take the mouse in buffers of its own kind with `claim`, as the terminal
-- does to pass it on to the program in it.

local greed = require("@greed")
local text = require("./text")

local M = {}

--- How many lines a turn of the wheel scrolls.
M.lines = 3

export type Handler = (event: greed.MouseEvent) -> boolean

local claims: { [string]: Handler } = {}

--- Gives mouse events over buffers of `kind` to `handler` first; when it
--- returns true, nothing else is done with them.
function M.claim(kind: string, handler: Handler)
	claims[kind] = handler
end

local function point(view: greed.View, pos: number, anchor: number?)
	view:set_selection({ ranges = { { anchor = anchor or pos, head = pos } }, primary = 1 })
end

--- Scrolls `view` by `lines` (up when negative), bringing the cursor onto
--- the screen with it, since drawing would scroll back to the cursor.
function M.scroll(view: greed.View, lines: number)
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

--- Presses on the same place this close together (in milliseconds) make
--- a double or triple click.
M.double_click = 400

-- The last left press, to count clicks: 1, 2 or 3.
local last_click: { view: number, pos: number, at: number, count: number }? = nil

local function clicks(view: greed.View, pos: number): number
	local now = greed.now()
	local last = last_click
	local count = if last
			and last.view == view:id()
			and last.pos == pos
			and now - last.at <= M.double_click
		then last.count % 3 + 1
		else 1
	last_click = { view = view:id(), pos = pos, at = now, count = count }
	return count
end

-- A left press with the cursor at `pos`: shift extends the selection to
-- it, alt adds a cursor there, and a double or triple click selects the
-- word or the line.
local function press(view: greed.View, event: greed.MouseEvent, pos: number)
	local buffer = view:buffer()
	local selection = view:selection()
	local count = clicks(view, pos)
	if event.shift then
		local anchor = selection.ranges[selection.primary].anchor
		point(view, pos, anchor)
		pressed = { view = view:id(), pos = anchor }
	elseif event.alt then
		table.insert(selection.ranges, { anchor = pos, head = pos })
		selection.primary = #selection.ranges
		view:set_selection(selection)
	elseif count == 2 and pos < buffer:len() then
		local from, to = text.word_at(buffer, pos)
		point(view, to, from)
	elseif count == 3 then
		local line = buffer:line_of(pos)
		local to = if line + 1 < buffer:line_count()
			then buffer:line_start(line + 1)
			else buffer:line_end(line)
		point(view, to, buffer:line_start(line))
	else
		point(view, pos)
		pressed = { view = view:id(), pos = pos }
	end
end

greed.on("mouse", function(event: greed.MouseEvent)
	local view = event.view
	if view == nil then
		return
	end
	-- A mark's text with an action is a button: the click runs it.
	if event.kind == "press" and event.button == "left" and event.action and event.pos then
		view:focus()
		point(view, event.pos)
		greed.run(event.action)
		return
	end
	local claim = claims[view:buffer():kind()]
	if claim and claim(event) then
		return
	end
	if event.kind == "press" and event.button == "left" then
		if greed.view():id() ~= view:id() then
			view:focus()
		end
		if event.pos then
			press(view, event, event.pos)
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
