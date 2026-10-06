-- Layout managers: how a tab arranges its panes as they open and close.
--
-- Each tab keeps its panes in an order, and its layout is a function of
-- that order: `main-stack` gives the first pane the main area and stacks
-- the rest beside it, `columns` puts them all side by side, `spiral`
-- halves the room again for each one, and `manual` leaves the panes where
-- you split them. You change a layout by reordering its panes (swap one
-- into main, rotate) or by picking another layout; resizing a pane by hand
-- switches the tab to `manual`, keeping the shape it has.
--
-- A layout is a function from the panes, in order, and the tab's settings
-- to a `greed.PaneLayout` tree; `define` adds your own:
--
--     require("@panes").layouts.define("rows", function(panes)
--         return { split = "column", children = panes }
--     end)

local greed = require("@greed")

export type Settings = {
	--- The main area's share of the tab in `main-stack`, from 0 to 1.
	main: number,
}

export type Layout = (panes: { greed.View }, settings: Settings) -> any

greed.option.define({
	name = "pane-layout",
	doc = 'How new tabs arrange their panes: "manual", "main-stack", "columns", "spiral" or your own',
	default = "manual",
})

local M = {}

local layouts: { [string]: Layout } = {}
-- The layouts in the order `next` goes through them.
local order: { string } = {}

type TabState = { layout: string, panes: { number }, settings: Settings }

-- Each tab's layout, pane order and settings, by tab id.
local states: { [number]: TabState } = {}

--- Adds layout `name`, or replaces it, until the plugin (or config) that
--- added it goes.
function M.define(name: string, layout: Layout)
	if layouts[name] == nil then
		table.insert(order, name)
	end
	layouts[name] = layout
	greed.plugin.tie(function()
		if layouts[name] == layout then
			layouts[name] = nil
			local at = table.find(order, name)
			if at then
				table.remove(order, at)
			end
		end
	end)
end

--- The layouts there are, in the order `next` goes through them.
function M.names(): { string }
	return table.clone(order)
end

local function state_of(id: number): TabState
	local state = states[id]
	if state == nil then
		local default = greed.option.get("pane-layout") :: string
		state = {
			layout = if layouts[default] then default else "manual",
			panes = {},
			settings = { main = 0.6 },
		}
		states[id] = state
	end
	return state
end

-- The tab's panes in the state's order: the ones it knows first, then any
-- it doesn't yet, in the tab's own order.
local function ordered(tab: greed.TabInfo, state: TabState): { greed.View }
	local by_id: { [number]: greed.View } = {}
	for _, pane in tab.panes do
		by_id[pane:id()] = pane
	end
	local list, ids = {}, {}
	for _, id in state.panes do
		if by_id[id] then
			table.insert(list, by_id[id])
			table.insert(ids, id)
			by_id[id] = nil
		end
	end
	for _, pane in tab.panes do
		if by_id[pane:id()] then
			table.insert(list, pane)
			table.insert(ids, pane:id())
		end
	end
	state.panes = ids
	return list
end

--- Arranges the shown tab by its layout. `manual` leaves it as it is.
function M.arrange()
	local tab = greed.tab.current()
	local state = state_of(tab.id)
	local panes = ordered(tab, state)
	local layout = layouts[state.layout]
	if layout == nil or state.layout == "manual" or #panes == 0 then
		return
	end
	local ok, err = pcall(function()
		greed.tab.set_layout(layout(panes, state.settings), tab.id)
	end)
	if not ok then
		greed.echo(`layout {state.layout}: {err}`)
	end
end

--- The shown tab's layout.
function M.current(): string
	return state_of(greed.tab.current().id).layout
end

--- Arranges the shown tab with layout `name`.
function M.use(name: string)
	if layouts[name] == nil then
		greed.echo(`there's no layout called {name}`)
		return
	end
	state_of(greed.tab.current().id).layout = name
	M.arrange()
	greed.echo(`layout: {name}`)
end

--- Arranges the shown tab with the layout after its own.
function M.next()
	local i = table.find(order, M.current()) or 0
	M.use(order[i % #order + 1])
end

--- Switches the shown tab to `manual`, keeping its shape, when a pane is
--- resized by hand in another layout.
function M.made_manual(why: string)
	local state = state_of(greed.tab.current().id)
	if state.layout ~= "manual" then
		state.layout = "manual"
		greed.echo(`layout: manual ({why})`)
	end
end

--- Swaps `pane` with the main one, the first in the order; the main one
--- swaps with the second.
function M.swap_main(pane: greed.View)
	local tab = greed.tab.current()
	local state = state_of(tab.id)
	ordered(tab, state)
	local i = table.find(state.panes, pane:id())
	if i == nil or #state.panes < 2 then
		return
	end
	local with = if i == 1 then 2 else 1
	state.panes[i], state.panes[with] = state.panes[with], state.panes[i]
	M.arrange()
end

--- Moves every pane one place along the order, the last one to the front.
function M.rotate()
	local tab = greed.tab.current()
	local state = state_of(tab.id)
	ordered(tab, state)
	if #state.panes > 1 then
		table.insert(state.panes, 1, table.remove(state.panes) :: number)
		M.arrange()
	end
end

--- Grows the main area by `by` (a share of the tab), or shrinks it.
function M.grow_main(by: number)
	local state = state_of(greed.tab.current().id)
	state.settings.main = math.clamp(state.settings.main + by, 0.1, 0.9)
	M.arrange()
end

-- New panes go into main in `main-stack`, pushing the old main onto the
-- stack, and right after the pane they came from otherwise.
greed.on("pane.opened", function(event: greed.PaneOpened)
	local tab = greed.tab.current()
	local state = state_of(tab.id)
	if state.layout == "manual" then
		return
	end
	-- The panes it had, in order, then the new one where it goes.
	ordered(tab, state)
	local panes = state.panes
	local new = event.view:id()
	table.remove(panes, table.find(panes, new) :: number)
	local from = table.find(panes, event.from:id())
	if state.layout == "main-stack" then
		table.insert(panes, 1, new)
	elseif from then
		table.insert(panes, from + 1, new)
	else
		table.insert(panes, new)
	end
	M.arrange()
end)

greed.on("view.closed", function()
	M.arrange()
end)

M.define("manual", function()
	return nil
end)

M.define("main-stack", function(panes, settings)
	if #panes == 1 then
		return panes[1]
	end
	local stack = if #panes == 2
		then panes[2]
		else { split = "column", children = { table.unpack(panes, 2) } }
	-- A pane and a split side by side: `any`, as layouts are (see `Layout`).
	local children: { any } = { panes[1], stack }
	return {
		split = "row",
		sizes = { settings.main, 1 - settings.main },
		children = children,
	}
end)

M.define("columns", function(panes)
	return if #panes == 1 then panes[1] else { split = "row", children = panes }
end)

-- Each pane takes half of what's left, turning from side by side to one
-- above another and back, so they wind inward.
M.define("spiral", function(panes)
	local function from(i: number): any
		if i == #panes then
			return panes[i]
		end
		return {
			split = if i % 2 == 1 then "row" else "column",
			children = { panes[i], from(i + 1) },
		}
	end
	return from(1)
end)

return M
