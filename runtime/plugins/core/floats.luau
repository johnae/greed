-- Floating views move and resize with the mouse: drag the top border (where
-- the title is) to move one, an edge or a corner to resize it. Pressing on
-- a float's border brings it to the front.

local greed = require("@greed")

local M = {}

--- The smallest a float gets by dragging, border included.
M.min_width = 10
M.min_height = 3

type Area = { x: number, y: number, width: number, height: number }

-- The float being dragged: which part was pressed, where, and the box it
-- had then, border included.
local dragging: { view: greed.View, part: string, col: number, row: number, box: Area }? = nil

--- Where `box` would go after dragging its `part` by `dx` and `dy`
--- cells: the top border moves it, the other edges and the corners resize it.
function M.dragged(box: Area, part: string, dx: number, dy: number): Area
	local x, y, width, height = box.x, box.y, box.width, box.height
	if part == "top" then
		return { x = math.max(0, x + dx), y = math.max(0, y + dy), width = width, height = height }
	end
	if string.find(part, "left", 1, true) then
		dx = math.min(dx, width - M.min_width)
		x += dx
		width -= dx
	elseif string.find(part, "right", 1, true) then
		width += dx
	end
	if string.find(part, "top", 1, true) then
		dy = math.min(dy, height - M.min_height)
		y += dy
		height -= dy
	elseif string.find(part, "bottom", 1, true) then
		height += dy
	end
	return {
		x = math.max(0, x),
		y = math.max(0, y),
		width = math.max(M.min_width, width),
		height = math.max(M.min_height, height),
	}
end

--- Whether `view` is floating.
function M.is_float(view: greed.View): boolean
	return view:float_spec() ~= nil
end

-- `view`'s box as last drawn, border included; nil before it's drawn.
local function box_of(view: greed.View): Area?
	local area = view:area()
	if area == nil then
		return nil
	end
	return { x = area.x - 1, y = area.y - 1, width = area.width + 2, height = area.height + 2 }
end

local function place(view: greed.View, box: Area)
	view:configure({ x = box.x, y = box.y, width = box.width, height = box.height })
end

--- Grows the float `view` by `cells` toward `side` ("left", "right", "up"
--- or "down"), or shrinks it from that side with negative `cells`.
function M.grow(view: greed.View, side: string, cells: number)
	local box = box_of(view)
	if box == nil then
		return
	end
	-- The top border moves a float, so growing up takes the top-left corner
	-- with no change across.
	local part = if side == "up" then "top-left" elseif side == "down" then "bottom" else side
	local dx = if side == "left" then -cells elseif side == "right" then cells else 0
	local dy = if side == "up" then -cells elseif side == "down" then cells else 0
	place(view, M.dragged(box, part, dx, dy))
end

--- Moves the float `view` by `dx` columns and `dy` rows.
function M.move(view: greed.View, dx: number, dy: number)
	local box = box_of(view)
	if box then
		place(view, M.dragged(box, "top", dx, dy))
	end
end

greed.on("mouse", function(event: greed.MouseEvent)
	if event.kind == "press" and event.button == "left" and event.border and event.view then
		local view = event.view
		local box = box_of(view)
		if box == nil then
			return
		end
		local part: string = event.border
		view:raise()
		view:focus()
		dragging = { view = view, part = part, col = event.col, row = event.row, box = box }
	elseif event.kind == "drag" and dragging then
		local drag = dragging
		local box = M.dragged(drag.box, drag.part, event.col - drag.col, event.row - drag.row)
		-- The float may have closed under the mouse.
		if not pcall(place, drag.view, box) then
			dragging = nil
		end
	elseif event.kind == "release" then
		dragging = nil
	end
end)

return M
