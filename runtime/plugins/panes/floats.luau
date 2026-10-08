-- The floating views that belong to a tab (floating terminals, agent
-- sessions, panes taken out to float): more of them, hiding and showing
-- them all, turning a pane into a float and back, and the tab's float
-- layout, which says where they go and which of them show:
--
-- - `free`: where you put them, the default; each float goes back to its
--   own place here after another layout moved it;
-- - `one`: one at a time, like tabs: all in one place at one size, the one
--   in front showing and the others running out of sight; cycling swaps
--   them in place;
-- - `tiled`: side by side in a grid over the panes, kept so as floats
--   come and go;
-- - `cascade`: overlapping, each a step down and right, titles showing.
--
-- A layout that hides floats marks the one showing with where it is among
-- them (`‹ 2/5 ›` on its border, a dot for each float under it) and shows
-- the dock, a strip along the bottom listing them. A float whose buffer
-- needs you (`core.floats.attention`) gets a colored dot in both.
--
-- `define` adds a layout of your own: a function from the tab's floats to
-- where each goes and whether it shows.
--
--     require("@panes").floats.define("halves", function(a)
--         local places = {}
--         local width = a.room.width // 2
--         for i in a.floats do
--             local x = a.room.x + (if i % 2 == 1 then 0 else width)
--             places[i] = { box = { x = x, y = a.room.y, width = width, height = a.room.height } }
--         end
--         return places
--     end)

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")
local terminal = require("@terminal")

local M = {}

export type Area = { x: number, y: number, width: number, height: number }

--- What a layout gets: the tab's floats in the order they opened, which of
--- them is in front, which was before that changed (if it just did), the
--- room the tab's panes take, and where each float is now, its border
--- included (nil before it's drawn). Every box is in screen cells.
export type Arrangement = {
	floats: { greed.View },
	current: number,
	previous: number?,
	room: Area,
	boxes: { Area? },
}

--- Where a layout puts a float: in `box` (its border included), hidden or
--- shown. Either left out stays as it is.
export type Place = { box: Area?, hidden: boolean? }

--- A float layout: where each of the tab's floats goes, by its place in
--- `arrangement.floats`.
export type Layout = (arrangement: Arrangement) -> { [number]: Place }

type Entry = { name: string, layout: Layout }

-- The layouts in the order `next` goes through them.
local layouts: { Entry } = {}

greed.option.define({
	name = "float-layout",
	doc = 'How new tabs lay out their floating views: "free", "one", "tiled", "cascade" or your own',
	default = "free",
})

--- Adds float layout `name`, or replaces it, until the plugin (or config)
--- that added it goes.
function M.define(name: string, layout: Layout)
	local entry: Entry = { name = name, layout = layout }
	greed.plugin.tie(core.registry.put(layouts, entry, function(other: Entry)
		return other.name == name
	end))
end

--- The float layouts there are, in the order `next` goes through them.
function M.names(): { string }
	local names = {}
	for _, entry in layouts do
		table.insert(names, entry.name)
	end
	return names
end

-- Older names of layouts: `deck` became `one`.
local ALIASES: { [string]: string } = { deck = "one" }

local function layout_named(name: string): Entry?
	name = ALIASES[name] or name
	for _, entry in layouts do
		if entry.name == name then
			return entry
		end
	end
	return nil
end

-- What each tab has: its layout, its floats in the order they opened, the
-- one in front, whether alt-f hid them all, the dock (shown or hidden by
-- hand, nil to follow the layout, its view and where each float's name is
-- in its text) and the float being picked in it.
type TabState = {
	layout: string,
	order: { greed.View },
	current: greed.View?,
	away: boolean,
	dock: boolean?,
	dock_view: greed.View?,
	dock_items: { { from: number, to: number } },
	picking: number?,
	-- Where each float was in `free`, by view id, to go back to there.
	own: { [number]: Area? },
}

local states: { [number]: TabState } = {}

local function state(): TabState
	local id = greed.tab.current().id
	local st = states[id]
	if st == nil then
		local default = greed.option.get("float-layout") :: string
		local fresh: TabState = {
			layout = if layout_named(default) then ALIASES[default] or default else "free",
			order = {},
			away = false,
			dock_items = {},
			own = {},
		}
		states[id] = fresh
		return fresh
	end
	return st
end

-- The dock's buffers are of this kind.
local DOCK = "float-dock"

local function is_dock(view: greed.View): boolean
	return view:buffer():kind() == DOCK
end

local function index_of(list: { greed.View }, view: greed.View?): number?
	for i, other in list do
		if other == view then
			return i
		end
	end
	return nil
end

-- The shown tab's own floats, the hidden ones too with `hidden`, leaving
-- out the dock; the one in front last.
local function own(hidden: boolean): { greed.View }
	local out = {}
	for _, view in greed.floats({ hidden = hidden }) do
		local spec = view:float_spec()
		if spec and spec.tab and not is_dock(view) then
			table.insert(out, view)
		end
	end
	return out
end

--- The shown tab's own floating views that show, the one in front last.
function M.list(): { greed.View }
	return own(false)
end

-- Brings the tab's float order up to date with the floats it has, and
-- works out which is in front: the focused one, else the one that was,
-- else the one that took the closed one's place.
local function reconcile(st: TabState)
	local now = own(true)
	local was = index_of(st.order, st.current)
	local order = {}
	for _, view in st.order do
		if index_of(now, view) then
			table.insert(order, view)
		end
	end
	for _, view in now do
		if not index_of(order, view) then
			table.insert(order, view)
		end
	end
	st.order = order
	local focused = greed.view()
	if index_of(order, focused) then
		st.current = focused
	elseif not index_of(order, st.current) then
		st.current = order[math.min(was or #order, #order)]
	end
end

--- The shown tab's own floating views, hidden or not, in the order they
--- opened.
function M.all(): { greed.View }
	local st = state()
	reconcile(st)
	return table.clone(st.order)
end

-- The room the tab's panes take, where its floats go.
local function room(): Area
	local left, top, right, bottom = math.huge, math.huge, 0, 0
	for _, pane in greed.tab.current().panes do
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

-- Where `view` is, its border included: as it was placed, in cells of the
-- acting client's screen, or else as it was last drawn.
local function box_of(view: greed.View): Area?
	local spec = view:float_spec()
	local placed = spec and core.floats.in_cells(spec)
	if placed then
		return placed
	end
	local area = view:area()
	if area == nil then
		return nil
	end
	return { x = area.x - 1, y = area.y - 1, width = area.width + 2, height = area.height + 2 }
end

-- The name of `buffer`'s file, if it has one.
local function file_name(buffer: greed.Buffer): string?
	local path = buffer:path()
	return if path then core.project.basename(path) else nil
end

-- A float's name: its title, else what its buffer is called (its file's
-- name, the name it was given, or its kind).
local function title_of(view: greed.View): string
	local spec = view:float_spec()
	if spec and spec.title and spec.title ~= "" then
		return spec.title
	end
	return view:buffer():title()
end

--- The keys that cycle the floats, shown faint on the float in front. The
--- pane plugin sets them from its keys.
M.cycle_hint = ""

type Piece = { text: string, style: string? }

-- What the float in front shows on its border when the layout hides the
-- others: where it is among them (with its neighbors' names when it's
-- `cells` wide enough) and a dot for each float.
local function indicator(st: TabState, i: number, cells: number): ({ Piece }, { Piece })
	local n = #st.order
	local label: { Piece } = {
		{ text = "‹ ", style = "ui.float.title" },
		{ text = `{i}/{n}`, style = "ui.float.title" },
	}
	if cells >= 60 then
		local each = (cells - 30) // 4
		-- The ones either side, round the ends; of two, the other one once,
		-- on the side it's on.
		local before = if n > 2 or i > 1 then st.order[(i - 2) % n + 1] else nil
		local after = if n > 2 or i < n then st.order[i % n + 1] else nil
		if before then
			table.insert(
				label,
				2,
				{ text = core.text.clip(title_of(before), each) .. " · ", style = "ui.float.hint" }
			)
		end
		if after then
			table.insert(
				label,
				{ text = " · " .. core.text.clip(title_of(after), each), style = "ui.float.hint" }
			)
		end
	end
	table.insert(label, { text = " ›", style = "ui.float.title" })
	local footer: { Piece } = {}
	for j, view in st.order do
		local dot, style = "○", nil
		if core.floats.needs_attention(view:buffer()) then
			dot, style = "●", "ui.float.attention"
		elseif j == i then
			dot, style = "●", "ui.float.title"
		end
		table.insert(footer, { text = if j == 1 then dot else " " .. dot, style = style })
	end
	if M.cycle_hint ~= "" and 2 * n + core.text.width(M.cycle_hint) + 6 <= cells then
		table.insert(footer, { text = "  " .. M.cycle_hint, style = "ui.float.hint" })
	end
	return label, footer
end

-- The label and footer last given each float, by view id, as text, so
-- they're set again only when they change.
local marked: { [number]: string } = {}

local function key_of(pieces: { Piece }): string
	local parts = {}
	for _, piece in pieces do
		table.insert(parts, `{piece.style or ""}:{piece.text}`)
	end
	return table.concat(parts, "|")
end

-- Puts `view` where `place` says, with `label` and `footer` on its border
-- (none if empty), changing only what's different.
local function apply(view: greed.View, place: Place?, label: { Piece }, footer: { Piece })
	local spec = view:float_spec()
	if spec == nil then
		return
	end
	local change: greed.FloatSpec = {}
	local changed = false
	-- In shares of the screen, so it's in the same place on every client's.
	local box = place and place.box and core.floats.in_shares(place.box)
	if
		box
		and (
			spec.x ~= box.x
			or spec.y ~= box.y
			or spec.width ~= box.width
			or spec.height ~= box.height
		)
	then
		change.x, change.y, change.width, change.height = box.x, box.y, box.width, box.height
		changed = true
	end
	local hidden = place and place.hidden
	if hidden ~= nil and hidden ~= (spec.hidden == true) then
		change.hidden = hidden
		changed = true
	end
	local key = key_of(label) .. "/" .. key_of(footer)
	if (marked[view:id()] or "/") ~= key then
		marked[view:id()] = key
		change.label = if #label > 0 then label else ""
		change.footer = if #footer > 0 then footer else ""
		changed = true
	end
	if changed then
		view:configure(change)
	end
end

-- Shows the dock along the bottom of the tab's room, listing its floats,
-- or closes it.
local function draw_dock(st: TabState, shown: boolean)
	local view = st.dock_view
	if not shown then
		if view and view:valid() then
			view:close()
		end
		st.dock_view = nil
		return
	end
	local text, items, marks = "", {}, {}
	local current = index_of(st.order, st.current)
	for i, float in st.order do
		local from = #text
		text ..= ` {i} {title_of(float)} `
		local style = if i == st.picking
			then "ui.menu.selected"
			elseif i == current then "ui.tabline.active"
			else "ui.tabline"
		table.insert(marks, { from = from, to = #text, style = style })
		if core.floats.needs_attention(float:buffer()) then
			table.insert(marks, { from = #text, to = #text + #"●", style = "ui.float.attention" })
			text ..= "● "
		end
		table.insert(items, { from = from, to = #text })
		text ..= " "
	end
	table.insert(marks, 1, { from = 0, to = #text, style = "ui.tabline", line = true })
	local buffer: greed.Buffer
	if view and view:valid() then
		buffer = view:buffer()
	else
		buffer = greed.create_buffer(DOCK, "", { readonly = true })
		buffer:forget_history()
		buffer:set_line_numbers(false)
	end
	if buffer:text() ~= text then
		buffer:edit(function(e)
			e:replace(0, buffer:len(), text)
		end)
	end
	buffer:decorate("float-dock", marks)
	-- Along the bottom, as wide as the room on every client's screen.
	local area = core.floats.in_shares(room())
	local spec: greed.FloatSpec = { x = area.x, width = area.width, height = 1, anchor = "bottom" }
	if view and view:valid() then
		view:configure(spec)
	else
		spec.border, spec.tab, spec.focus = false, true, false
		st.dock_view = greed.float(buffer, spec)
	end
	st.dock_items = items
end

-- Lays the tab's floats out by its layout, marks the one in front when the
-- layout hides the others, and shows or hides the dock. `previous` was in
-- front before, if that just changed.
local function arrange(previous: greed.View?)
	local st = state()
	reconcile(st)
	local n = #st.order
	local current = index_of(st.order, st.current) or n
	local places: { [number]: Place } = {}
	local entry = layout_named(st.layout)
	if n > 0 and not st.away and entry then
		local boxes = {}
		for i, view in st.order do
			boxes[i] = box_of(view)
		end
		local ok, result = pcall(entry.layout, {
			floats = table.clone(st.order),
			current = current,
			previous = index_of(st.order, previous),
			room = room(),
			boxes = boxes,
		})
		if ok then
			places = result
		else
			greed.echo(`float layout {st.layout}: {result}`)
		end
	end
	local hides = false
	for _, place in places do
		hides = hides or place.hidden == true
	end
	for i, view in st.order do
		local label, footer = {}, {}
		if hides and n > 1 and i == current then
			local box = (places[i] and places[i].box) or box_of(view)
			label, footer = indicator(st, i, if box then box.width - 2 else 0)
		end
		apply(view, places[i], label, footer)
	end
	-- The focused float comes to the front, but never over a picker or a
	-- prompt that has focus.
	local front = st.current
	if front and front == greed.view() then
		local shown = M.list()
		if shown[#shown] ~= front then
			front:raise()
		end
	end
	local dock = if st.dock == nil then hides else st.dock
	draw_dock(st, n > 0 and not st.away and (dock or st.picking ~= nil))
end

--- Lays the shown tab's floats out again by its float layout.
function M.arrange()
	arrange()
end

--- The shown tab's float layout.
function M.current(): string
	return state().layout
end

--- Lays the shown tab's floats out with layout `name`, from now on.
function M.use(name: string)
	if layout_named(name) == nil then
		greed.echo(`there's no float layout called {name}`)
		return
	end
	name = ALIASES[name] or name
	local st = state()
	-- Floats keep their own places from `free`, and get them back there.
	if st.layout == "free" and name ~= "free" then
		for _, view in M.all() do
			st.own[view:id()] = box_of(view)
		end
	end
	local back = name == "free" and st.layout ~= "free"
	st.layout = name
	-- What the layout before hid comes back, unless the new one hides it.
	if not st.away then
		for _, view in M.all() do
			apply(view, { hidden = false, box = if back then st.own[view:id()] else nil }, {}, {})
		end
	end
	arrange()
	greed.echo(`float layout: {name}`)
end

--- Lays the shown tab's floats out with the layout after its own.
function M.next()
	local names = M.names()
	local i = table.find(names, M.current()) or 0
	M.use(names[i % #names + 1])
end

--- Picks the shown tab's float layout from a list.
function M.pick()
	local items = {}
	for _, name in M.names() do
		local label = name .. if name == M.current() then "  (now)" else ""
		table.insert(items, { label = label, value = name })
	end
	picker.pick("Float layouts", items, function(item)
		M.use(item.value)
	end)
end

--- Brings `view`, one of the shown tab's floats, to the front and focuses
--- it, showing it if it was hidden: in layouts that show one at a time,
--- it's the one shown.
function M.focus(view: greed.View)
	local st = state()
	local previous = st.current
	st.current = view
	st.away = false
	view:focus()
	arrange(previous)
	terminal.settle(view)
end

--- Brings the float `offset` places on from the one in front to the
--- front, round the ends.
function M.cycle(offset: number)
	local st = state()
	reconcile(st)
	local n = #st.order
	if n == 0 then
		greed.echo("no floating views in this tab")
		return
	end
	local i = index_of(st.order, st.current) or n
	M.focus(st.order[(i - 1 + offset) % n + 1])
end

--- Shows the dock in the shown tab, or hides it. Without this it shows
--- while the layout hides floats.
function M.toggle_dock()
	local st = state()
	local view = st.dock_view
	st.dock = not (view and view:valid())
	arrange()
end

--- Shows the dock and picks a float from it: 1 to 9 pick one by its
--- number, the arrows (or h and l) move along and enter picks; any other
--- key leaves things as they were.
function M.pick_from_dock()
	local st = state()
	reconcile(st)
	local n = #st.order
	if n == 0 then
		greed.echo("no floating views in this tab")
		return
	end
	local at = index_of(st.order, st.current) or 1
	local chosen: greed.View? = nil
	local numbers = if n > 1 then `1 to {math.min(n, 9)}` else "1"
	while chosen == nil do
		st.picking = at
		arrange()
		greed.echo(`pick a floating view: {numbers}, or h and l then enter; esc leaves it`)
		local key = greed.next_key()
		local number = tonumber(key)
		if number and number >= 1 and number <= n then
			chosen = st.order[number]
		elseif key == "left" or key == "h" then
			at = (at - 2) % n + 1
		elseif key == "right" or key == "l" then
			at = at % n + 1
		elseif key == "enter" then
			chosen = st.order[at]
		else
			break
		end
	end
	st.picking = nil
	if chosen then
		M.focus(chosen)
	else
		arrange()
	end
end

-- Where a new float goes: a step down and right from the one in front, at
-- its size (its area is inside the border), or nil when there's none.
local function cascaded(): greed.FloatSpec?
	local front = M.list()
	local last = front[#front]
	local area = last and last:area()
	if area == nil then
		return nil
	end
	return core.floats.in_shares({
		x = area.x + 3,
		y = area.y + 1,
		width = area.width + 2,
		height = area.height + 2,
	})
end

--- Opens another floating terminal in the tab, a step down and right from
--- the float in front, if there is one.
function M.new_terminal()
	terminal.open(nil, { float = cascaded() or true })
end

--- Opens `buffer` in a new floating view over the tab: as `spec` says if
--- given, else a little down and right of the one in front.
function M.open(buffer: greed.Buffer, spec: greed.FloatSpec?): greed.View
	local float: greed.FloatSpec = if spec
		then table.clone(spec)
		else cascaded() or { width = "80%", height = "80%" }
	float.tab = true
	float.title = float.title or file_name(buffer)
	return greed.float(buffer, float)
end

--- Shows `buffer` in a float of the shown tab and brings it to the front:
--- the float already showing it, or a new one (placed as `spec` says, if
--- given). For plugins that show things in floats, like agent sessions.
function M.show(buffer: greed.Buffer, spec: greed.FloatSpec?): greed.View
	for _, view in M.all() do
		if view:buffer() == buffer then
			M.focus(view)
			return view
		end
	end
	local view = M.open(buffer, spec)
	M.focus(view)
	return view
end

--- Hides the tab's floats, or shows the ones it hid, as zellij's alt-f
--- does; with none, opens a floating terminal. Hidden terminals keep
--- running, and floats come back where they were.
function M.toggle()
	local st = state()
	reconcile(st)
	if #M.list() > 0 then
		st.away = true
		for _, view in st.order do
			apply(view, { hidden = true }, {}, {})
		end
		arrange()
		terminal.settle(greed.view())
		return
	end
	local front = st.current or st.order[#st.order]
	if front == nil then
		M.new_terminal()
		return
	end
	for _, view in st.order do
		apply(view, { hidden = false }, {}, {})
	end
	M.focus(front)
end

--- Takes the focused pane out of the tab to float over it, or puts the
--- focused float back in as a pane beside the active one.
function M.flip(view: greed.View)
	local buffer, selection = view:buffer(), view:selection()
	local moved: greed.View
	if view:float_spec() then
		local active = greed.tab.current().active
		local rows, cols = active:size()
		moved = active:split(if (cols or 80) > (rows or 24) * 2 then "right" else "down", buffer)
	elseif #greed.tab.current().panes > 1 then
		-- A file by its name; a named buffer, like a terminal, shows its own.
		moved = greed.float(
			buffer,
			{ title = file_name(buffer), width = "70%", height = "70%", tab = true }
		)
	else
		greed.echo("the last pane stays in the tab")
		return
	end
	moved:set_selection(selection)
	view:close()
	moved:focus()
	terminal.settle(moved)
end

-- A box `share` of `area` across and down, in its middle.
local function centered(area: Area, share: number): Area
	local width, height = math.floor(area.width * share), math.floor(area.height * share)
	return {
		x = area.x + (area.width - width) // 2,
		y = area.y + (area.height - height) // 2,
		width = width,
		height = height,
	}
end

M.define("free", function()
	return {}
end)

-- One at a time, like tabs: every float in the one place, where the float
-- in front was, moved or resized, so cycling never moves anything.
M.define("one", function(a)
	local box = a.boxes[a.previous or a.current] or centered(a.room, 0.8)
	local places = {}
	for i in a.floats do
		places[i] = { box = box, hidden = i ~= a.current }
	end
	return places
end)

M.define("tiled", function(a)
	local cols = math.ceil(math.sqrt(#a.floats))
	local rows = math.ceil(#a.floats / cols)
	local width, height = a.room.width // cols, a.room.height // rows
	local places = {}
	for i in a.floats do
		local col, row = (i - 1) % cols, (i - 1) // cols
		local box = {
			x = a.room.x + col * width,
			y = a.room.y + row * height,
			width = width,
			height = height,
		}
		places[i] = { box = box, hidden = false }
	end
	return places
end)

M.define("cascade", function(a)
	local width, height = a.room.width * 3 // 5, a.room.height * 3 // 5
	local places = {}
	for i in a.floats do
		local step = i - 1
		local box = {
			x = math.min(a.room.x + 2 + step * 4, a.room.x + a.room.width - width),
			y = math.min(a.room.y + 1 + step * 2, a.room.y + a.room.height - height),
			width = width,
			height = height,
		}
		places[i] = { box = box, hidden = false }
	end
	return places
end)

-- A float taking focus (opened, clicked, focused by a plugin) is the one
-- in front. Floats coming and going, the tab changing size and buffers
-- needing you lay the tab out again.
greed.on("view.focused", function(event: greed.ViewFocused)
	local spec = event.view:float_spec()
	if spec and spec.tab and not is_dock(event.view) then
		local st = state()
		local previous = st.current
		st.current = event.view
		st.away = false
		arrange(previous)
	else
		arrange()
	end
end)

greed.on("view.closed", function(event: greed.ViewClosed)
	marked[event.view] = nil
	arrange()
end)

greed.on("view.resized", function(event: greed.ViewResized)
	if event.view:valid() and not is_dock(event.view) then
		arrange()
	end
end)

core.floats.on_attention(function()
	arrange()
end)

-- Clicking a float's name in the dock brings it to the front; clicking
-- anywhere else on it goes back.
greed.on("mouse", function(event: greed.MouseEvent)
	local view = event.view
	if not (event.kind == "press" and event.button == "left" and view and is_dock(view)) then
		return
	end
	local st = state()
	local pos = event.pos or -1
	for i, item in st.dock_items do
		if pos >= item.from and pos < item.to and st.order[i] then
			M.focus(st.order[i])
			return
		end
	end
	local back = st.current or greed.tab.current().active
	back:focus()
	terminal.settle(back)
end)

return M
