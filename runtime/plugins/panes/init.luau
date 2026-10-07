-- Panes and tabs, the way a terminal multiplexer has them: split the
-- screen between files and terminals, move between them, give a pane more
-- room, keep tabs of layouts (arranged by the layout managers in
-- layouts.luau). The keys follow zellij's where they can:
--
-- - alt keys work everywhere, in every editing style and in terminals:
--   alt-h/j/k/l move between panes (and to the next tab at the edge),
--   alt-n opens a terminal pane (a floating one while floats are shown),
--   alt-f shows or hides the tab's floating views (opening a floating
--   terminal when there are none), alt-F floats this file, alt-= and
--   alt-- resize, alt-[ and alt-] or alt-1..9 change tabs. alt-w changes
--   how the tab lays out its floats (see floats.luau), alt-{ and alt-}
--   cycle through them and alt-W picks one from the dock.
-- - alt-p and alt-t open the pane and tab modes, where single keys act until
--   esc.
-- - In normal mode, ctrl-w (and the leader's w) is the window prefix Vim and Helix
--   users know, and in Vim, g t and g T change tabs.
--
-- Every key is in `M.keys`; rebind or unbind them from your config like any
-- other (see docs/keys.md).

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")
local terminal = require("@terminal")
local layouts = require("@self/layouts")
local place = require("@self/place")

local M = {}

--- How tabs arrange their panes (see layouts.luau).
M.layouts = layouts

--- Layouts saved to open again (see saved.luau).
M.saved = require("@self/saved")

--- The floating views a tab has (see floats.luau).
M.floats = require("@self/floats")

export type Direction = "left" | "right" | "up" | "down"

local OPPOSITE: { [Direction]: Direction } =
	{ left = "right", right = "left", up = "down", down = "up" }

-- How many cells a resize moves an edge.
local STEP: { [Direction]: number } = { left = 4, right = 4, up = 2, down = 2 }

--- The pane keys go to: the focused view if it's a pane, else the shown
--- tab's active pane.
function M.pane(): greed.View
	local view = greed.view()
	return if view:is_pane() then view else greed.tab.current().active
end

local settle = terminal.settle

--- Focuses `view`, going into the right mode for it.
function M.focus(view: greed.View)
	view:focus()
	settle(view)
end

local function tabs(): ({ greed.TabInfo }, number)
	local list = greed.tab.list()
	for i, tab in list do
		if tab.current then
			return list, i
		end
	end
	return list, 1
end

--- Shows the tab `offset` places from the shown one, round the ends.
function M.cycle_tab(offset: number)
	local list, i = tabs()
	local tab = list[(i - 1 + offset) % #list + 1]
	greed.tab.switch(tab.id)
	settle(greed.view())
end

--- Shows the `n`th tab, if there is one.
function M.go_to_tab(n: number)
	local tab = greed.tab.list()[n]
	if tab then
		greed.tab.switch(tab.id)
		settle(greed.view())
	end
end

--- Moves to the pane or panel (the file tree, an agent) on the `dir` side.
--- Left and right go on to the tab before or after at the edge, as zellij
--- does.
function M.move(dir: Direction)
	local view = greed.view()
	local from = if core.floats.is_float(view) then M.pane() else view
	local next = from:neighbor(dir)
	if next then
		M.focus(next)
	elseif dir == "left" or dir == "right" then
		if #greed.tab.list() > 1 then
			M.cycle_tab(if dir == "left" then -1 else 1)
		end
	end
end

--- Focuses the next pane in the tab, round the end.
function M.next_pane()
	local tab = greed.tab.current()
	local current = M.pane():id()
	for i, pane in tab.panes do
		if pane:id() == current then
			M.focus(tab.panes[i % #tab.panes + 1])
			return
		end
	end
end

--- Grows the pane toward `dir`, or shrinks it with negative `steps`; at
--- the edge of the screen it moves the other edge instead. With a floating
--- view focused, it grows or shrinks that.
function M.resize(dir: Direction, steps: number?)
	local cells = STEP[dir] * (steps or 1)
	local view = greed.view()
	if core.floats.is_float(view) then
		core.floats.grow(view, dir, cells)
		return
	end
	-- A panel (the file tree, an agent) moves its edge by the main view.
	if not view:is_pane() and (view:resize(dir, cells) or view:resize(OPPOSITE[dir], -cells)) then
		return
	end
	layouts.made_manual("a pane was resized by hand")
	local pane = M.pane()
	if not pane:resize(dir, cells) then
		pane:resize(OPPOSITE[dir], -cells)
	end
end

--- Moves the focused floating view toward `dir`.
function M.move_float(dir: Direction)
	local view = greed.view()
	if core.floats.is_float(view) then
		local cells = STEP[dir]
		local dx = if dir == "left" then -cells elseif dir == "right" then cells else 0
		local dy = if dir == "up" then -cells elseif dir == "down" then cells else 0
		core.floats.move(view, dx, dy)
	end
end

--- Grows the pane every way it can (or shrinks it, with a negative `steps`).
function M.grow(steps: number)
	local view = greed.view()
	local ways: { Direction } = { "right", "down" }
	if core.floats.is_float(view) then
		for _, dir: Direction in ways do
			core.floats.grow(view, dir, STEP[dir] * steps)
		end
		return
	end
	layouts.made_manual("a pane was resized by hand")
	local pane = M.pane()
	for _, dir: Direction in ways do
		local cells = STEP[dir] * steps
		if not pane:resize(dir, cells) then
			pane:resize(OPPOSITE[dir], cells)
		end
	end
end

--- The side to split a pane of `rows` by `cols` cells along: its longer
--- one, counting a cell as about twice as tall as it's wide.
function M.split_side(rows: number, cols: number): Direction
	return if cols > rows * 2 then "right" else "down"
end

local function longer_side(pane: greed.View): Direction
	local rows, cols = pane:size()
	return M.split_side(rows or 24, cols or 80)
end

--- Opens a terminal in a new pane on the `dir` side (the longer side
--- without), running `command` or your shell.
function M.terminal_pane(dir: Direction?, command: { string }?)
	local pane = M.pane()
	terminal.open(command, { split = dir or longer_side(pane), from = pane })
end

--- Opens a pane on the `dir` side showing what this one shows.
function M.split(dir: Direction)
	M.focus(M.pane():split(dir))
end

--- Swaps what this pane shows with the pane on the `dir` side, and follows
--- it there.
function M.swap(dir: Direction)
	local here = M.pane()
	local there = here:neighbor(dir)
	if there == nil then
		return
	end
	local mine, theirs = here:buffer(), there:buffer()
	local my_selection, their_selection = here:selection(), there:selection()
	-- Kept while they change places, so a scratch buffer isn't dropped in
	-- the moment nothing shows it.
	local kept_mine, kept_theirs = mine:kept(), theirs:kept()
	mine:set_kept(true)
	theirs:set_kept(true)
	here:show(theirs)
	here:set_selection(their_selection)
	there:show(mine)
	there:set_selection(my_selection)
	mine:set_kept(kept_mine)
	theirs:set_kept(kept_theirs)
	M.focus(there)
end

--- Closes the pane, unless it's the last one.
function M.close_pane()
	-- A panel or a float closes like a pane would.
	local view = greed.view()
	if not view:is_pane() then
		view:close()
		return
	end
	local pane = M.pane()
	local buffer = pane:buffer()
	if not pane:close() then
		greed.echo("the last pane stays open")
		return
	end
	terminal.forget(buffer)
	settle(greed.view())
end

--- Closes every other pane in the tab.
function M.only()
	local keep = M.pane():id()
	for _, pane in greed.tab.current().panes do
		if pane:id() ~= keep then
			pane:close()
		end
	end
end

function M.toggle_zoom()
	greed.tab.set_zoomed(not greed.tab.current().zoomed)
end

-- What `pick` labels panes with: digits first, then letters.
local LABELS = "123456789abcdefghijklmnopqrstuvwxyz"

--- Puts a label over each pane of the tab and focuses the one whose label
--- is typed next; any other key leaves things as they were. In a zoomed
--- tab every pane shows again first. Returns whether a pane was picked.
function M.pick(): boolean
	if greed.tab.current().zoomed then
		greed.tab.set_zoomed(false)
		-- Lets the panes be drawn where they now are.
		greed.sleep(0)
	end
	local badges: { greed.View } = {}
	local labelled: { [string]: greed.View } = {}
	for i, pane in greed.tab.current().panes do
		local label = string.sub(LABELS, i, i)
		local area = pane:area()
		if label ~= "" and area then
			labelled[label] = pane
			local badge = greed.create_buffer("pane-label", ` {label} `, { readonly = true })
			badge:set_line_numbers(false)
			badge:decorate(
				"pane-label",
				{ { from = 0, to = 3, style = "ui.pane.label", line = true } }
			)
			table.insert(
				badges,
				greed.float(badge, { x = area.x, y = area.y, width = 5, height = 3, focus = false })
			)
		end
	end
	local key = greed.next_key()
	for _, badge in badges do
		badge:close()
	end
	local pane = labelled[key]
	if pane then
		M.focus(pane)
	end
	return pane ~= nil
end

--- Opens a tab, empty or with a terminal.
function M.new_tab(with_terminal: boolean?)
	greed.tab.new()
	if with_terminal then
		terminal.open()
	elseif greed.mode.get() == "terminal" then
		greed.mode.set(core.style.home())
	end
end

function M.close_tab()
	if not greed.tab.close(greed.tab.current().id) then
		greed.echo("the last tab stays open")
		return
	end
	settle(greed.view())
end

function M.rename_tab()
	local id = greed.tab.current().id
	core.prompt.open({
		title = "Tab name",
		on_submit = function(name)
			greed.tab.rename(id, name)
		end,
	})
end

-- The pane and tab modes: single keys act until esc, like zellij's.
local modes: { [string]: { back: string, hint: string } } = {}

local function enter(mode: string)
	local current = greed.mode.get()
	modes[mode].back = if modes[current] then modes[current].back else current
	greed.mode.set(mode)
	greed.echo(modes[mode].hint)
end

local function leave()
	local current = modes[greed.mode.get()]
	if current then
		greed.mode.set(current.back)
		settle(greed.view())
	end
end

-- Runs `f`, then leaves the mode.
local function once(f: () -> ()): (greed.Context) -> ()
	return function()
		f()
		leave()
	end
end

-- Commands: name, what it does, and what runs.
local commands: { { name: string, doc: string, run: () -> () } } = {
	{
		name = "pane-place",
		doc = "Show where a new pane would go, to move it and open it there",
		run = function()
			leave()
			place.start(M.pane())
		end,
	},
	{
		name = "pane-place-here",
		doc = "Open a pane with this file where the frame is",
		run = function()
			place.open()
		end,
	},
	{
		name = "pane-place-terminal",
		doc = "Open a terminal where the frame is",
		run = function()
			place.open(true)
		end,
	},
	{ name = "pane-place-cancel", doc = "Put things back without a new pane", run = place.cancel },
	{ name = "layout-next", doc = "Arrange this tab with the next layout", run = layouts.next },
	{
		name = "layout-pick",
		doc = "Pick how this tab arranges its panes",
		run = function()
			local items = {}
			for _, name in layouts.names() do
				local label = name .. if name == layouts.current() then "  (now)" else ""
				table.insert(items, { label = label, value = name })
			end
			picker.pick("Layouts", items, function(item)
				layouts.use(item.value)
			end)
		end,
	},
	{
		name = "layout-swap-main",
		doc = "Swap this pane with the main one",
		run = function()
			layouts.swap_main(M.pane())
		end,
	},
	{ name = "layout-rotate", doc = "Move every pane one place along", run = layouts.rotate },
	{
		name = "layout-main-grow",
		doc = "Give the main pane more room",
		run = function()
			layouts.grow_main(0.05)
		end,
	},
	{
		name = "layout-main-shrink",
		doc = "Give the main pane less room",
		run = function()
			layouts.grow_main(-0.05)
		end,
	},
	{ name = "pane-next", doc = "Move to the next pane", run = M.next_pane },
	{
		name = "pane-terminal",
		doc = "Open a terminal in a new pane, or a floating one while floating views are shown",
		run = function()
			-- As in zellij: with floats shown, the new pane floats too.
			if #M.floats.list() > 0 then
				M.floats.new_terminal()
			else
				M.terminal_pane()
			end
		end,
	},
	{ name = "pane-close", doc = "Close this pane", run = M.close_pane },
	{ name = "pane-only", doc = "Close every other pane in the tab", run = M.only },
	{ name = "pane-zoom", doc = "Show only this pane, or all of them again", run = M.toggle_zoom },
	{
		name = "pane-pick",
		doc = "Label the panes and go to the one whose label you type next",
		run = function()
			M.pick()
		end,
	},
	{
		name = "pane-grow",
		doc = "Give this pane more room",
		run = function()
			M.grow(1)
		end,
	},
	{
		name = "pane-shrink",
		doc = "Give this pane less room",
		run = function()
			M.grow(-1)
		end,
	},
	{
		name = "terminal-float",
		doc = "Show the floating terminal, or hide it",
		run = function()
			terminal.toggle_float()
		end,
	},
	{
		name = "tab-new",
		doc = "Open a new tab",
		run = function()
			M.new_tab()
		end,
	},
	{
		name = "tab-terminal",
		doc = "Open a new tab with a terminal",
		run = function()
			M.new_tab(true)
		end,
	},
	{ name = "tab-close", doc = "Close this tab and its panes", run = M.close_tab },
	{
		name = "tab-next",
		doc = "Show the next tab",
		run = function()
			M.cycle_tab(1)
		end,
	},
	{
		name = "tab-previous",
		doc = "Show the tab before",
		run = function()
			M.cycle_tab(-1)
		end,
	},
	{ name = "tab-rename", doc = "Name this tab", run = M.rename_tab },
	{
		name = "pane-mode",
		doc = "Keys for panes until esc: move, split, resize, close",
		run = function()
			enter("pane")
		end,
	},
	{
		name = "tab-mode",
		doc = "Keys for tabs until esc: new, close, switch, rename",
		run = function()
			enter("tab")
		end,
	},
	{
		name = "float-terminal-new",
		doc = "Open another floating terminal in this tab",
		run = function()
			M.floats.new_terminal()
		end,
	},
	{
		name = "floats-toggle",
		doc = "Hide this tab's floating views or show them again; with none, open a floating terminal",
		run = function()
			M.floats.toggle()
		end,
	},
	{
		name = "float-flip",
		doc = "Take this pane out to float over the tab, or put a floating view back in as a pane",
		run = function()
			M.floats.flip(greed.view())
		end,
	},
	{
		name = "floats-tile",
		doc = "Lay this tab's floating views out side by side, from now on",
		run = function()
			M.floats.use("tiled")
		end,
	},
	{
		name = "floats-cascade",
		doc = "Stack this tab's floating views in a cascade, from now on",
		run = function()
			M.floats.use("cascade")
		end,
	},
	{
		name = "floats-one",
		doc = "Show this tab's floating views one at a time, like tabs, all in the same place, from now on",
		run = function()
			M.floats.use("one")
		end,
	},
	{
		name = "float-layout-next",
		doc = "Lay this tab's floating views out with the next float layout",
		run = M.floats.next,
	},
	{
		name = "float-layout-pick",
		doc = "Pick how this tab lays out its floating views",
		run = M.floats.pick,
	},
	{
		name = "float-next",
		doc = "Bring the next floating view in this tab to the front",
		run = function()
			M.floats.cycle(1)
		end,
	},
	{
		name = "float-previous",
		doc = "Bring the floating view before in this tab to the front",
		run = function()
			M.floats.cycle(-1)
		end,
	},
	{
		name = "float-dock",
		doc = "Show the dock of this tab's floating views, or hide it",
		run = M.floats.toggle_dock,
	},
	{
		name = "float-dock-pick",
		doc = "Pick a floating view from the dock: 1 to 9, or the arrows and enter",
		run = M.floats.pick_from_dock,
	},
	{
		name = "resize-mode",
		doc = "Keys for resizing the pane or floating view until esc, and moving a float",
		run = function()
			enter("resize")
		end,
	},
	{ name = "pane-mode-leave", doc = "Back from the pane or tab mode", run = leave },
}

-- How each side reads in the docs of its commands.
type Words = { where: string, its: string, edge: string, out: string, back: string, tab: string }
local WORDS: { [Direction]: Words } = {
	left = {
		where = "on the left",
		its = "on its left",
		edge = "left edge",
		out = "out",
		back = "in",
		tab = ", or the tab before",
	},
	right = {
		where = "on the right",
		its = "on its right",
		edge = "right edge",
		out = "out",
		back = "in",
		tab = ", or the tab after",
	},
	up = { where = "above", its = "above", edge = "top edge", out = "up", back = "down", tab = "" },
	down = {
		where = "below",
		its = "below",
		edge = "bottom edge",
		out = "down",
		back = "up",
		tab = "",
	},
}
local function add(name: string, doc: string, run: () -> ())
	table.insert(commands, { name = name, doc = doc, run = run })
end

-- Adds the commands for `side`.
local function add_side(side: Direction)
	local w = WORDS[side]
	add(`pane-place-{side}`, `Move the new pane's frame {side}`, function()
		place.move(side)
	end)
	add(`pane-{side}`, `Move to the pane {w.where}{w.tab}`, function()
		M.move(side)
	end)
	add(`pane-swap-{side}`, `Swap this pane with the one {w.its}`, function()
		M.swap(side)
	end)
	add(`pane-resize-{side}`, `Move this pane's {w.edge} {w.out}`, function()
		M.resize(side)
	end)
	add(`pane-shrink-{side}`, `Move this pane's {w.edge} {w.back}`, function()
		M.resize(side, -1)
	end)
	add(`float-move-{side}`, `Move the floating view {side}`, function()
		M.move_float(side)
	end)
	if side == "right" or side == "down" then
		add(`pane-split-{side}`, `Show this pane's file in a new pane {w.where}`, function()
			M.split(side)
		end)
		add(`pane-terminal-{side}`, `Open a terminal in a new pane {w.where}`, function()
			M.terminal_pane(side)
		end)
		add(`pane-new-{side}`, `Open a pane {w.where} with a new, empty buffer`, function()
			M.focus(M.pane():split(side, greed.create_buffer("file", "")))
		end)
		add(
			`pane-file-{side}`,
			`Open the file named under the cursor in a pane {w.where}`,
			function()
				M.split(side)
				greed.run("goto-file")
			end
		)
	end
end
add_side("left")
add_side("right")
add_side("up")
add_side("down")

local by_name: { [string]: () -> () } = {}
for _, c in commands do
	local run = c.run
	greed.command({
		name = c.name,
		doc = c.doc,
		run = function()
			run()
			-- Messages go with the next key; while still in a mode, its keys
			-- stay on the status line.
			local mode = modes[greed.mode.get()]
			if mode then
				greed.echo(mode.hint)
			end
		end,
	})
	by_name[c.name] = c.run
end

greed.command({
	name = "tab-go",
	doc = "Show tab N",
	args = { { name = "n", doc = "The tab's number, from 1" } },
	run = function(ctx)
		M.go_to_tab(tonumber(ctx.args[1] or ctx.keys and string.match(ctx.keys, "%d+$") or "") or 1)
	end,
})

greed.command({
	name = "float-file",
	doc = "Open a file (this one if none is given) in a new floating view",
	args = { { name = "path", complete = "file" } },
	run = function(ctx)
		local path = ctx.args[1]
		M.focus(M.floats.open(if path then greed.load(path) else ctx.buffer))
	end,
})

-- Files, as things to act on: in a float, or in a pane beside this one.
core.actions.action({
	kind = "file",
	name = "float",
	doc = "Open it in a floating view",
	run = function(target)
		M.focus(M.floats.open(greed.load(target.value)))
	end,
})
core.actions.action({
	kind = "file",
	name = "split",
	doc = "Open it in a new pane beside this one",
	run = function(target)
		M.focus(M.pane():split(longer_side(M.pane()), greed.load(target.value)))
	end,
})

-- Saves the tab as the layout named in `args`, or asks for a name.
local function save_layout(args: { string }, mine: boolean)
	local function save(name: string)
		local file, err = M.saved.save(name, mine)
		greed.echo(if file then `saved layout {name} in {file}` else `can't save it: {err}`)
	end
	if args[1] then
		save(args[1])
	else
		core.prompt.open({ title = "Save layout as", on_submit = save })
	end
end

greed.command({
	name = "layout-save",
	doc = "Save this tab's panes, and what they show, as a layout of the project",
	args = { { name = "name", doc = "What to call it" } },
	run = function(ctx)
		save_layout(ctx.args, false)
	end,
})

greed.command({
	name = "layout-save-mine",
	doc = "Save this tab's panes, and what they show, as a layout for any project",
	args = { { name = "name", doc = "What to call it" } },
	run = function(ctx)
		save_layout(ctx.args, true)
	end,
})

greed.command({
	name = "layout-open",
	doc = "Open a saved layout as a new tab",
	args = { { name = "name", doc = "The layout" } },
	run = function(ctx)
		if ctx.args[1] then
			M.saved.open(ctx.args[1])
			return
		end
		local items = {}
		for _, name in M.saved.names() do
			table.insert(items, { label = name, value = name })
		end
		if #items == 0 then
			greed.echo("no saved layouts yet; :layout-save NAME saves this tab")
			return
		end
		picker.pick("Saved layouts", items, function(item)
			M.saved.open(item.value)
		end)
	end,
})

-- Commands that leave the pane or tab mode after running, for keys in it
-- that open something.
for _, name in
	{ "pane-terminal", "pane-close", "tab-new", "tab-terminal", "tab-close", "tab-rename" }
do
	greed.command({
		name = `{name}-done`,
		doc = `{name}, then back from the mode`,
		run = once(by_name[name]),
	})
end

--- The default keys, by layer. Change them before this plugin loads, or
--- rebind and unbind from your config afterwards.
M.keys = {
	-- Everywhere: every mode of every style, and terminals.
	everywhere = {
		["alt-h"] = "pane-left",
		["alt-j"] = "pane-down",
		["alt-k"] = "pane-up",
		["alt-l"] = "pane-right",
		["alt-left"] = "pane-left",
		["alt-down"] = "pane-down",
		["alt-up"] = "pane-up",
		["alt-right"] = "pane-right",
		["alt-n"] = "pane-terminal",
		["alt-f"] = "floats-toggle",
		["alt-F"] = "float-file",
		["alt-="] = "pane-grow",
		["alt-+"] = "pane-grow",
		["alt--"] = "pane-shrink",
		["alt-["] = "tab-previous",
		["alt-]"] = "tab-next",
		["alt-p"] = "pane-mode",
		["alt-space"] = "layout-next",
		["alt-m"] = "layout-swap-main",
		["alt-t"] = "tab-mode",
		["alt-r"] = "resize-mode",
		["alt-w"] = "float-layout-next",
		["alt-W"] = "float-dock-pick",
		["alt-{"] = "float-previous",
		["alt-}"] = "float-next",
	} :: { [string]: string },
	-- Resizing the pane or floating view: grow toward a side, shrink from
	-- it with shift, and move a float with the arrows.
	resize = {
		h = "pane-resize-left",
		j = "pane-resize-down",
		k = "pane-resize-up",
		l = "pane-resize-right",
		H = "pane-shrink-left",
		J = "pane-shrink-down",
		K = "pane-shrink-up",
		L = "pane-shrink-right",
		left = "float-move-left",
		down = "float-move-down",
		up = "float-move-up",
		right = "float-move-right",
		["="] = "pane-grow",
		["+"] = "pane-grow",
		["-"] = "pane-shrink",
		esc = "pane-mode-leave",
		enter = "pane-mode-leave",
		["alt-r"] = "pane-mode-leave",
	} :: { [string]: string },
	pane = {
		h = "pane-left",
		j = "pane-down",
		k = "pane-up",
		l = "pane-right",
		left = "pane-left",
		down = "pane-down",
		up = "pane-up",
		right = "pane-right",
		tab = "pane-next",
		H = "pane-resize-left",
		J = "pane-resize-down",
		K = "pane-resize-up",
		L = "pane-resize-right",
		["="] = "pane-grow",
		["+"] = "pane-grow",
		["-"] = "pane-shrink",
		n = "pane-terminal-done",
		r = "pane-terminal-right",
		d = "pane-terminal-down",
		v = "pane-split-right",
		s = "pane-split-down",
		x = "pane-close-done",
		f = "pane-zoom",
		g = "pane-pick",
		w = "floats-toggle",
		e = "float-flip",
		E = "float-file",
		space = "layout-next",
		m = "layout-swap-main",
		o = "layout-rotate",
		["]"] = "layout-main-grow",
		["["] = "layout-main-shrink",
		y = "layout-pick",
		p = "pane-place",
		R = "resize-mode",
		W = "float-terminal-new",
		F = "float-flip",
		z = "floats-toggle",
		T = "floats-tile",
		C = "floats-cascade",
		O = "floats-one",
		Y = "float-layout-pick",
		["{"] = "float-previous",
		["}"] = "float-next",
		esc = "pane-mode-leave",
		enter = "pane-mode-leave",
		["alt-p"] = "pane-mode-leave",
	} :: { [string]: string },
	tab = {
		h = "tab-previous",
		l = "tab-next",
		left = "tab-previous",
		right = "tab-next",
		["["] = "tab-previous",
		["]"] = "tab-next",
		n = "tab-new-done",
		t = "tab-terminal-done",
		x = "tab-close-done",
		r = "tab-rename-done",
		esc = "pane-mode-leave",
		enter = "pane-mode-leave",
		["alt-t"] = "pane-mode-leave",
	} :: { [string]: string },
	-- While placing a new pane.
	place = {
		h = "pane-place-left",
		j = "pane-place-down",
		k = "pane-place-up",
		l = "pane-place-right",
		left = "pane-place-left",
		down = "pane-place-down",
		up = "pane-place-up",
		right = "pane-place-right",
		enter = "pane-place-here",
		t = "pane-place-terminal",
		esc = "pane-place-cancel",
	} :: { [string]: string },
	-- After ctrl-w in normal mode, as in Vim and Helix, and w in the leader.
	window = {
		v = "pane-split-right",
		s = "pane-split-down",
		h = "pane-left",
		j = "pane-down",
		k = "pane-up",
		l = "pane-right",
		w = "pane-next",
		q = "pane-close",
		c = "pane-close",
		o = "pane-only",
		t = "pane-terminal",
		z = "pane-zoom",
		g = "pane-pick",
		H = "pane-swap-left",
		J = "pane-swap-down",
		K = "pane-swap-up",
		L = "pane-swap-right",
		f = "pane-file-down",
		F = "pane-file-right",
		["n s"] = "pane-new-down",
		["n v"] = "pane-new-right",
	} :: { [string]: string },
}

for n = 1, 9 do
	M.keys.everywhere[`alt-{n}`] = "tab-go"
end

-- What each mode's keys do, for the line shown on entering it.
local function hint(keys: { [string]: string }, order: { string }): string
	local parts = {}
	for _, key in order do
		local name = keys[key]
		if name then
			local short = string.gsub(string.gsub(name, "^pane%-", ""), "^tab%-", "")
			local what = string.gsub(short, "%-done$", "")
			table.insert(parts, `{key} {what}`)
		end
	end
	return table.concat(parts, "  ")
end

modes.pane = {
	back = "helix",
	hint = hint(M.keys.pane, {
		"h",
		"j",
		"k",
		"l",
		"n",
		"r",
		"d",
		"v",
		"s",
		"x",
		"g",
		"f",
		"w",
		"space",
		"m",
		"o",
		"y",
		"H",
		"R",
		"W",
		"F",
		"z",
		"T",
		"C",
		"O",
		"D",
		"Y",
		"{",
		"}",
		"=",
		"-",
		"esc",
	}),
}
modes.tab = { back = "helix", hint = hint(M.keys.tab, { "h", "l", "n", "t", "x", "r", "esc" }) }
modes.resize = {
	back = "helix",
	hint = "h j k l grow  H J K L shrink  arrows move a float  = - every way  esc",
}

-- Binds `M.keys` in the layers they belong to. The terminal's mode takes
-- every key, so the everywhere keys are bound in it too.
local function bind()
	greed.keymap.bind({}, M.keys.everywhere)
	greed.keymap.bind("terminal", M.keys.everywhere)
	for mode in modes do
		greed.keymap.isolate(mode)
		greed.keymap.bind(mode, M.keys[mode])
		greed.keymap.fallback(mode, "pane-mode-leave")
	end
	greed.keymap.bind("pane-place", M.keys.place)
	greed.keymap.fallback("pane-place", "pane-place-cancel")
	local window: { [string]: string } = {}
	local leader: { [string]: string } = {}
	for key, name in M.keys.window do
		window[`ctrl-w {key}`] = name
		leader[`w {key}`] = name
	end
	greed.keymap.bind("helix", window)
	greed.keymap.bind("vim", window)
	greed.keymap.bind({ layer = "leader" }, leader)
	greed.keymap.bind("vim", { ["g t"] = "tab-next", ["g T"] = "tab-previous" })
end

bind()

-- The keys that cycle floats, for the hint on the float in front.
local cycling = {}
for _, name in { "float-previous", "float-next" } do
	for key, bound in M.keys.everywhere do
		if bound == name then
			table.insert(cycling, key)
			break
		end
	end
end
M.floats.cycle_hint = table.concat(cycling, " ")

-- The line between panes, or by a panel, being dragged: the view whose
-- edge it is, which edge, and where the mouse was last.
local dragging: { view: greed.View, edge: "left" | "right" | "down", col: number, row: number }? =
	nil

-- Clicking a tab in the tab line shows it, and dragging the line between
-- panes or by a panel resizes them.
greed.on("mouse", function(event: greed.MouseEvent)
	if event.kind == "press" and event.tab then
		greed.tab.switch(event.tab)
		settle(greed.view())
	elseif event.kind == "press" and event.button == "left" and event.edge and event.view then
		dragging = { view = event.view, edge = event.edge, col = event.col, row = event.row }
	elseif event.kind == "drag" and dragging then
		local drag = dragging
		local cells = if drag.edge == "down" then event.row - drag.row else event.col - drag.col
		if cells == 0 then
			return
		end
		-- Dragging a left edge left grows the view.
		if drag.edge == "left" then
			cells = -cells
		end
		local dir: Direction = drag.edge
		-- The view may have closed under the mouse.
		local ok = pcall(function()
			if drag.view:is_pane() then
				layouts.made_manual("a pane was resized by hand")
			end
			drag.view:resize(dir, cells)
		end)
		if ok then
			drag.col, drag.row = event.col, event.row
		else
			dragging = nil
		end
	elseif event.kind == "release" then
		dragging = nil
	end
end)

return M
