-- The floating views that belong to a tab (floating terminals, panes taken
-- out to float): more of them, hiding and showing them all, laying them out
-- side by side or in a cascade, and turning a pane into a float and back.
-- Floats are placed by hand otherwise; nothing moves them on its own.

local kern = require("@kern")
local terminal = require("@terminal")

local M = {}

type Area = { x: number, y: number, width: number, height: number }

--- The shown tab's own floating views, the one in front last.
function M.list(): { kern.View }
	local out = {}
	for _, view in kern.floats() do
		local spec = view:float_spec()
		if spec and spec.tab then
			table.insert(out, view)
		end
	end
	return out
end

-- The room the tab's panes take, where its floats go.
local function room(): Area
	local left, top, right, bottom = math.huge, math.huge, 0, 0
	for _, pane in kern.tab.current().panes do
		local area = pane:area()
		if area then
			left = math.min(left, area.x)
			top = math.min(top, area.y)
			right = math.max(right, area.x + area.width)
			bottom = math.max(bottom, area.y + area.height)
		end
	end
	if right == 0 then
		return { x = 0, y = 0, width = 80, height = 24 }
	end
	return { x = left, y = top, width = right - left, height = bottom - top }
end

--- Lays the tab's floats out side by side in a grid over its panes.
function M.tile()
	local floats = M.list()
	if #floats == 0 then
		return
	end
	local area = room()
	local cols = math.ceil(math.sqrt(#floats))
	local rows = math.ceil(#floats / cols)
	local width, height = area.width // cols, area.height // rows
	for i, view in floats do
		local col, row = (i - 1) % cols, (i - 1) // cols
		view:configure({
			x = area.x + col * width,
			y = area.y + row * height,
			width = width,
			height = height,
		})
	end
end

--- Stacks the tab's floats in a cascade, each a step down and right from
--- the one behind it.
function M.cascade()
	local area = room()
	local width, height = area.width * 3 // 5, area.height * 3 // 5
	for i, view in M.list() do
		local step = i - 1
		view:configure({
			x = math.min(area.x + 2 + step * 4, area.x + area.width - width),
			y = math.min(area.y + 1 + step * 2, area.y + area.height - height),
			width = width,
			height = height,
		})
	end
end

-- Where a new float goes: a step down and right from the one in front, at
-- its size (its area is inside the border), or nil when there's none.
local function cascaded(): kern.FloatSpec?
	local front = M.list()
	local last = front[#front]
	local area = last and last:area()
	if area == nil then
		return nil
	end
	return { x = area.x + 3, y = area.y + 1, width = area.width + 2, height = area.height + 2 }
end

--- Opens another floating terminal in the tab, a step down and right from
--- the float in front, if there is one.
function M.new_terminal()
	terminal.open(nil, { float = cascaded() or true })
end

--- Opens `buffer` in a new floating view over the tab, a little down and
--- right of the one in front.
function M.open(buffer: kern.Buffer): kern.View
	local spec: kern.FloatSpec = cascaded() or { width = "80%", height = "80%" }
	spec.tab = true
	local path = buffer:path()
	spec.title = if path then string.match(path, "[^/]+$") else nil
	return kern.float(buffer, spec)
end

-- What each tab hid, to show again: the buffer, how its float was shown,
-- its selection and whether the buffer was kept before.
type Hidden =
	{ buffer: kern.Buffer, spec: kern.FloatSpec, selection: kern.Selection, kept: boolean }
local hidden: { [number]: { Hidden } } = {}

--- Hides the tab's floats, or shows the ones it hid, as zellij's alt-f
--- does; with none, opens a floating terminal. Hidden terminals keep
--- running, and floats come back where they were.
function M.toggle()
	local tab = kern.tab.current().id
	local stored = hidden[tab]
	if stored then
		hidden[tab] = nil
		for _, float in stored do
			local view = kern.float(float.buffer, float.spec)
			view:set_selection(float.selection)
			float.buffer:set_kept(float.kept)
		end
		terminal.settle(kern.view())
		return
	end
	local floats = M.list()
	if #floats == 0 then
		M.new_terminal()
		return
	end
	local list: { Hidden } = {}
	for _, view in floats do
		local buffer = view:buffer()
		table.insert(list, {
			buffer = buffer,
			spec = view:float_spec() :: kern.FloatSpec,
			selection = view:selection(),
			kept = buffer:kept(),
		})
		-- Kept while hidden, so a scratch buffer doesn't go with its view.
		buffer:set_kept(true)
		view:close()
	end
	hidden[tab] = list
	terminal.settle(kern.view())
end

--- Takes the focused pane out of the tab to float over it, or puts the
--- focused float back in as a pane beside the active one.
function M.flip(view: kern.View)
	local buffer, selection = view:buffer(), view:selection()
	local moved: kern.View
	if view:float_spec() then
		local active = kern.tab.current().active
		local rows, cols = active:size()
		moved = active:split(if (cols or 80) > (rows or 24) * 2 then "right" else "down", buffer)
	elseif #kern.tab.current().panes > 1 then
		local path = buffer:path()
		local title = if path then string.match(path, "[^/]+$") else buffer:kind()
		moved = kern.float(buffer, { title = title, width = "70%", height = "70%", tab = true })
	else
		kern.echo("the last pane stays in the tab")
		return
	end
	moved:set_selection(selection)
	view:close()
	moved:focus()
	terminal.settle(moved)
end

return M
