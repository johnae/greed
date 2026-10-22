-- The mouse: a click focuses the view under it and puts the cursor there,
-- or runs the action of a mark's text or a status line piece (a button),
-- dragging selects, a double or triple click selects the word or line,
-- shift extends and alt adds a cursor, and the wheel scrolls the view
-- under it. A plugin can take the mouse in buffers of its own kind with
-- `claim`, as the terminal does to pass it on to the program in it.

local greed = require("@greed")
local text = require("./text")
local registry = require("./registry")

local M = {}

--- How many lines a turn of the wheel scrolls.
M.lines = 3

export type Handler = (event: greed.MouseEvent) -> boolean

local claims: { [string]: Handler } = {}

--- Gives mouse events over buffers of `kind` to `handler` first; when it
--- returns true, nothing else is done with them. It goes when the plugin
--- that claimed them does.
function M.claim(kind: string, handler: Handler)
	greed.plugin.tie(registry.set(claims, kind, handler))
end

-- Runs a button's action: a command's name, then any arguments to it.
local function act(action: string)
	local args = string.split(action, " ")
	local name = table.remove(args, 1) :: string
	greed.run(name, if #args > 0 then { args = args } else nil)
end

local function point(view: greed.View, pos: number, anchor: number?)
	view:set_selection({ ranges = { { anchor = anchor or pos, head = pos } }, primary = 1 })
end

-- The last line surely on screen in `view` with `top` the first. Long lines
-- wrap onto several rows; counting each as a row more than its width needs
-- leaves room for where words break, so the line found is in sight and
-- drawing doesn't scroll back down to a cursor put on it.
local function bottom_line(view: greed.View, top: number): number
	local buffer = view:buffer()
	local last = math.max(buffer:line_count() - 1, 0)
	local size_rows, size_cols = view:size()
	local rows, cols = size_rows or 1, math.max(size_cols or 80, 1)
	local used = 0
	local line = top
	while line <= last do
		local width = text.width(buffer:slice(buffer:line_start(line), buffer:line_end(line)))
		local takes = if width <= cols then 1 else width // cols + 2
		if used + takes > rows then
			break
		end
		used += takes
		line += 1
	end
	return math.max(line - 1, top)
end

--- Scrolls the lines of `view` that don't wrap (a wide table) by `columns`
--- (left when negative). A cursor on such a line comes along into sight,
--- since drawing would scroll back to it.
function M.side_scroll(view: greed.View, columns: number)
	local from = math.max(view:side_scroll() + columns, 0)
	view:set_side_scroll(from)
	local buffer = view:buffer()
	local pos = view:cursor()
	local nowrap = false
	for _, mark in buffer:marks_at(pos) do
		if
			(mark.view == nil or mark.view == view:id())
			and (mark.client == nil or mark.client == greed.client.id())
		then
			nowrap = nowrap or mark.nowrap == true
		end
	end
	local _, width = view:size()
	if not nowrap or width == nil then
		return
	end
	local col = buffer:display_column(pos)
	if col < from or col >= from + width then
		local line = buffer:line_of(pos)
		point(view, buffer:at_display_column(line, math.clamp(col, from, from + width - 1)))
	end
end

--- Scrolls `view` by `lines` (up when negative), bringing the cursor onto
--- the screen with it, since drawing would scroll back to the cursor.
function M.scroll(view: greed.View, lines: number)
	local buffer = view:buffer()
	local last = math.max(buffer:line_count() - 1, 0)
	local top = math.clamp(view:scroll() + lines, 0, last)
	view:set_scroll(top)
	local line = buffer:line_of(view:cursor())
	local bottom = bottom_line(view, top)
	if line < top then
		point(view, buffer:line_start(top))
	elseif line > bottom then
		point(view, buffer:line_start(bottom))
	end
end

-- Where the left button went down for each client, while it's down: the
-- view and the place in its buffer, which a drag selects from.
local pressed: { [number]: { view: number, pos: number } } = {}

--- Presses on the same place this close together (in milliseconds) make
--- a double or triple click.
M.double_click = 400

-- Each client's last left press, to count clicks: 1, 2 or 3.
local last_click: { [number]: { view: number, pos: number, at: number, count: number } } = {}

local function clicks(view: greed.View, pos: number): number
	local now = greed.now()
	local client = greed.client.id()
	local last = last_click[client]
	local count = if last
			and last.view == view:id()
			and last.pos == pos
			and now - last.at <= M.double_click
		then last.count % 3 + 1
		else 1
	last_click[client] = { view = view:id(), pos = pos, at = now, count = count }
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
		pressed[greed.client.id()] = { view = view:id(), pos = anchor }
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
		pressed[greed.client.id()] = { view = view:id(), pos = pos }
	end
end

-- What a click over `view` does: run a button, go to a plugin that
-- claimed its kind of buffer, or move the cursor, select or scroll.
local function handle(event: greed.MouseEvent, view: greed.View)
	local action, pos = event.action, event.pos
	if event.kind == "press" and event.button == "left" and action then
		-- A part of a float's border with one, like a label's arrows.
		if event.border then
			act(action)
			return
		end
		-- A mark's text with one is a button: the click runs it.
		if pos then
			view:focus()
			point(view, pos)
			act(action)
			return
		end
	end
	local claim = claims[view:buffer():kind()]
	if claim and claim(event) then
		return
	end
	local left = event.button == "left"
	if event.kind == "press" and left then
		if greed.view() ~= view then
			view:focus()
		end
		if event.pos then
			press(view, event, event.pos)
		end
	elseif event.kind == "drag" and left then
		local held = pressed[event.client]
		if held and held.view == view:id() and event.pos then
			point(view, event.pos, held.pos)
		end
	elseif event.kind == "release" then
		pressed[event.client] = nil
	elseif event.kind == "scroll" and (event.dir == "up" or event.dir == "down") then
		M.scroll(view, if event.dir == "up" then -M.lines else M.lines)
	elseif event.kind == "scroll" and (event.dir == "left" or event.dir == "right") then
		M.side_scroll(view, if event.dir == "left" then -M.lines * 2 else M.lines * 2)
	end
end

greed.on("mouse", function(event: greed.MouseEvent)
	local view = event.view
	if view == nil then
		if event.kind == "press" and event.button == "left" and event.action then
			act(event.action)
		end
		return
	end
	handle(event, view)
	-- A click can close its view, like a page's Close button: the handlers
	-- after this one then hear of a click over no view.
	if not view:valid() then
		(event :: any).view = nil
	end
end)

return M
