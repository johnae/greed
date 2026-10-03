-- Placing a new pane by eye: a frame over the panes shows where it would
-- go, beside any pane or along an edge of the whole tab. h j k l (or the
-- arrows) move the frame, enter opens a pane there with this file, t a
-- terminal, and esc puts things back.

local greed = require("@greed")
local terminal = require("@terminal")

type Direction = "left" | "right" | "up" | "down"
type Rect = { x: number, y: number, width: number, height: number }

-- Where a new pane can go: beside `pane` on its `side`, or with no pane,
-- along that edge of the tab. `rect` is the room it would take; a tab
-- edge is steered to by `x` and `y`, on the edge.
type Spot = { pane: greed.View?, side: Direction, rect: Rect, x: number?, y: number? }

local MODE = "pane-place"
local SIDES: { Direction } = { "right", "down", "left", "up" }

local M = {}

type Placing = { spots: { Spot }, at: number, frame: greed.View, from: greed.View, back: string }

local placing: Placing? = nil

-- The `share` of `r` on its `side`.
local function part(r: Rect, side: Direction, share: number): Rect
	local w = math.max(math.floor(r.width * share), 3)
	local h = math.max(math.floor(r.height * share), 3)
	if side == "left" then
		return { x = r.x, y = r.y, width = w, height = r.height }
	elseif side == "right" then
		return { x = r.x + r.width - w, y = r.y, width = w, height = r.height }
	elseif side == "up" then
		return { x = r.x, y = r.y, width = r.width, height = h }
	end
	return { x = r.x, y = r.y + r.height - h, width = r.width, height = h }
end

-- Every spot in the shown tab: each side of each pane, then each edge of
-- the tab when it has more than one pane.
local function spots(): { Spot }
	local list: { Spot } = {}
	local whole: Rect? = nil
	local tab = greed.tab.current()
	for _, pane in tab.panes do
		local area = pane:area()
		if area then
			for _, side in SIDES do
				table.insert(list, { pane = pane, side = side, rect = part(area, side, 1 / 2) })
			end
			local w = whole
			if w == nil then
				whole = table.clone(area)
			else
				local right = math.max(w.x + w.width, area.x + area.width)
				local bottom = math.max(w.y + w.height, area.y + area.height)
				w.x, w.y = math.min(w.x, area.x), math.min(w.y, area.y)
				w.width, w.height = right - w.x, bottom - w.y
			end
		end
	end
	local w = whole
	if w and #tab.panes > 1 then
		for _, side in SIDES do
			-- It shows the third the pane gets, but is steered to as the
			-- edge itself, past every pane's own half beside it.
			local x = if side == "left"
				then w.x
				elseif side == "right" then w.x + w.width
				else w.x + w.width / 2
			local y = if side == "up"
				then w.y
				elseif side == "down" then w.y + w.height
				else w.y + w.height / 2
			table.insert(list, { side = side, rect = part(w, side, 1 / 3), x = x, y = y })
		end
	end
	return list
end

-- Where the frame is steered by: its middle, or for a tab edge the edge.
local function center(spot: Spot): (number, number)
	if spot.x and spot.y then
		return spot.x, spot.y
	end
	local r = spot.rect
	return r.x + r.width / 2, r.y + r.height / 2
end

-- The spot nearest `from` toward `dir`, counting distance across twice, so
-- the frame goes the way the key points.
local function nearest(list: { Spot }, from: Spot, dir: Direction): Spot?
	local fx, fy = center(from)
	local best, score = nil, math.huge
	for _, spot in list do
		local x, y = center(spot)
		local along = if dir == "right"
			then x - fx
			elseif dir == "left" then fx - x
			elseif dir == "down" then y - fy
			else fy - y
		local across = if dir == "left" or dir == "right"
			then math.abs(y - fy)
			else math.abs(x - fx)
		-- Cells are about twice as tall as wide.
		if dir == "up" or dir == "down" then
			across /= 2
		else
			across *= 2
		end
		local s = along + across * 2
		if spot ~= from and along > 0 and s < score then
			best, score = spot, s
		end
	end
	return best
end

local function show(p: Placing)
	local r = p.spots[p.at].rect
	p.frame:configure({ x = r.x, y = r.y, width = r.width, height = r.height })
end

local function finish()
	local p = placing
	if p == nil then
		return
	end
	placing = nil
	p.frame:close()
	p.from:focus()
	greed.mode.set(p.back)
end

--- Shows the frame on the focused pane's right, where a split there would
--- go, to move and open a pane at.
function M.start(from: greed.View)
	finish()
	local list = spots()
	if #list == 0 then
		greed.echo("the panes haven't been drawn yet")
		return
	end
	local at = 1
	for i, spot in list do
		if spot.pane and spot.pane:id() == from:id() and spot.side == "right" then
			at = i
		end
	end
	local buffer = greed.create_buffer("pane-place", "new pane", { readonly = true })
	local r = list[at].rect
	local frame = greed.float(buffer, {
		title = "enter: here  t: terminal  esc",
		x = r.x,
		y = r.y,
		width = r.width,
		height = r.height,
		focus = false,
	})
	placing = { spots = list, at = at, frame = frame, from = from, back = greed.mode.get() }
	greed.mode.set(MODE)
end

--- Moves the frame to the next spot toward `dir`.
function M.move(dir: Direction)
	local p = placing
	if p == nil then
		return
	end
	local next = nearest(p.spots, p.spots[p.at], dir)
	if next then
		p.at = table.find(p.spots, next) :: number
		show(p)
	end
end

-- `node` without pane `id`, a split left with one child becoming it.
local function without(node: any, id: number): any
	if type(node) ~= "table" then
		return if node:id() == id then nil else node
	end
	local children, sizes = {}, {}
	for i, child in node.children do
		local kept = without(child, id)
		if kept ~= nil then
			table.insert(children, kept)
			table.insert(sizes, node.sizes[i])
		end
	end
	if #children == 1 then
		return children[1]
	end
	return { split = node.split, children = children, sizes = sizes }
end

-- Moves `new` (just opened) to the `side` edge of the whole tab, taking a
-- third of it.
local function to_edge(new: greed.View, side: Direction)
	local rest = without(greed.tab.layout(), new:id())
	local first = side == "left" or side == "up"
	greed.tab.set_layout({
		split = if side == "left" or side == "right" then "row" else "column",
		children = if first then { new, rest } else { rest, new },
		sizes = if first then { 1, 2 } else { 2, 1 },
	})
end

--- Opens the pane where the frame is: this file, or with `with_terminal`
--- a terminal.
function M.open(with_terminal: boolean?)
	local p = placing
	if p == nil then
		return
	end
	local spot = p.spots[p.at]
	finish()
	local target = spot.pane or p.from
	local new: greed.View
	if with_terminal then
		terminal.open(nil, { split = spot.side, from = target })
		new = greed.view()
	else
		new = target:split(spot.side)
		new:focus()
	end
	if spot.pane == nil then
		to_edge(new, spot.side)
	end
	terminal.settle(new)
end

--- Puts things back without opening a pane.
M.cancel = finish

greed.keymap.isolate(MODE)
greed.mode.cursor(MODE, "block")

return M
