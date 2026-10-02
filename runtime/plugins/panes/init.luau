-- Panes and tabs, the way a terminal multiplexer has them: split the
-- screen between files and terminals, move between them, give a pane more
-- room, keep tabs of layouts (arranged by the layout managers in
-- layouts.luau). The keys follow zellij's where they can:
--
-- - alt keys work everywhere, in every editing style and in terminals:
--   alt-h/j/k/l move between panes (and to the next tab at the edge),
--   alt-n opens a terminal pane, alt-f a floating terminal, alt-= and alt--
--   resize, alt-[ and alt-] or alt-1..9 change tabs.
-- - alt-p and alt-t open the pane and tab modes, where single keys act until
--   esc.
-- - In normal mode, ctrl-w (and space w) is the window prefix Vim and Helix
--   users know, and in Vim, g t and g T change tabs.
--
-- Every key is in `M.keys`; rebind or unbind them from your config like any
-- other (see docs/keys.md).

local kern = require("@kern")
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

type Direction = "left" | "right" | "up" | "down"

local OPPOSITE: { [Direction]: Direction } =
	{ left = "right", right = "left", up = "down", down = "up" }

-- How many cells a resize moves an edge.
local STEP: { [Direction]: number } = { left = 4, right = 4, up = 2, down = 2 }

--- The pane keys go to: the focused view if it's a pane, else the shown
--- tab's active pane.
function M.pane(): kern.View
	local view = kern.view()
	return if view:is_pane() then view else kern.tab.current().active
end

local settle = terminal.settle

--- Focuses `view`, going into the right mode for it.
function M.focus(view: kern.View)
	view:focus()
	settle(view)
end

local function tabs(): ({ kern.TabInfo }, number)
	local list = kern.tab.list()
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
	kern.tab.switch(tab.id)
	settle(kern.view())
end

--- Shows the `n`th tab, if there is one.
function M.go_to_tab(n: number)
	local tab = kern.tab.list()[n]
	if tab then
		kern.tab.switch(tab.id)
		settle(kern.view())
	end
end

--- Moves to the pane on the `dir` side. Left and right go on to the tab
--- before or after at the edge, as zellij does.
function M.move(dir: Direction)
	local next = M.pane():neighbor(dir)
	if next then
		M.focus(next)
	elseif dir == "left" or dir == "right" then
		if #kern.tab.list() > 1 then
			M.cycle_tab(if dir == "left" then -1 else 1)
		end
	end
end

--- Focuses the next pane in the tab, round the end.
function M.next_pane()
	local tab = kern.tab.current()
	local current = M.pane():id()
	for i, pane in tab.panes do
		if pane:id() == current then
			M.focus(tab.panes[i % #tab.panes + 1])
			return
		end
	end
end

--- Grows the pane toward `dir`, or shrinks it with negative `steps`; at
--- the edge of the screen it moves the other edge instead.
function M.resize(dir: Direction, steps: number?)
	layouts.made_manual("a pane was resized by hand")
	local pane = M.pane()
	local cells = STEP[dir] * (steps or 1)
	if not pane:resize(dir, cells) then
		pane:resize(OPPOSITE[dir], -cells)
	end
end

--- Grows the pane every way it can (or shrinks it, with a negative `steps`).
function M.grow(steps: number)
	layouts.made_manual("a pane was resized by hand")
	local pane = M.pane()
	for _, dir in { "right", "down" } :: { Direction } do
		local cells = STEP[dir] * steps
		if not pane:resize(dir, cells) then
			pane:resize(OPPOSITE[dir], cells)
		end
	end
end

-- The side to split the pane along: its longer one, counting a cell as
-- about twice as tall as it's wide.
local function longer_side(pane: kern.View): Direction
	local rows, cols = pane:size()
	return if (cols or 80) > (rows or 24) * 2 then "right" else "down"
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

--- Closes the pane, unless it's the last one.
function M.close_pane()
	local pane = M.pane()
	local buffer = pane:buffer()
	if not pane:close() then
		kern.echo("the last pane stays open")
		return
	end
	terminal.forget(buffer)
	settle(kern.view())
end

--- Closes every other pane in the tab.
function M.only()
	local keep = M.pane():id()
	for _, pane in kern.tab.current().panes do
		if pane:id() ~= keep then
			pane:close()
		end
	end
end

function M.toggle_zoom()
	kern.tab.set_zoomed(not kern.tab.current().zoomed)
end

--- Opens a tab, empty or with a terminal.
function M.new_tab(with_terminal: boolean?)
	kern.tab.new()
	if with_terminal then
		terminal.open()
	elseif kern.mode.get() == "terminal" then
		kern.mode.set(core.style.home())
	end
end

function M.close_tab()
	if not kern.tab.close(kern.tab.current().id) then
		kern.echo("the last tab stays open")
		return
	end
	settle(kern.view())
end

function M.rename_tab()
	local id = kern.tab.current().id
	core.prompt.open({
		title = "Tab name",
		on_submit = function(name)
			kern.tab.rename(id, name)
		end,
	})
end

-- The pane and tab modes: single keys act until esc, like zellij's.
local modes: { [string]: { back: string, hint: string } } = {}

local function enter(mode: string)
	local current = kern.mode.get()
	modes[mode].back = if modes[current] then modes[current].back else current
	kern.mode.set(mode)
	kern.echo(modes[mode].hint)
end

local function leave()
	local current = modes[kern.mode.get()]
	if current then
		kern.mode.set(current.back)
		settle(kern.view())
	end
end

-- Runs `f`, then leaves the mode.
local function once(f: () -> ()): (kern.Context) -> ()
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
		name = "pane-place-left",
		doc = "Move the new pane's frame left",
		run = function()
			place.move("left")
		end,
	},
	{
		name = "pane-place-right",
		doc = "Move the new pane's frame right",
		run = function()
			place.move("right")
		end,
	},
	{
		name = "pane-place-up",
		doc = "Move the new pane's frame up",
		run = function()
			place.move("up")
		end,
	},
	{
		name = "pane-place-down",
		doc = "Move the new pane's frame down",
		run = function()
			place.move("down")
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
	{
		name = "pane-left",
		doc = "Move to the pane on the left, or the tab before",
		run = function()
			M.move("left")
		end,
	},
	{
		name = "pane-right",
		doc = "Move to the pane on the right, or the tab after",
		run = function()
			M.move("right")
		end,
	},
	{
		name = "pane-up",
		doc = "Move to the pane above",
		run = function()
			M.move("up")
		end,
	},
	{
		name = "pane-down",
		doc = "Move to the pane below",
		run = function()
			M.move("down")
		end,
	},
	{ name = "pane-next", doc = "Move to the next pane", run = M.next_pane },
	{
		name = "pane-split-right",
		doc = "Show this pane's file in a new pane on the right",
		run = function()
			M.split("right")
		end,
	},
	{
		name = "pane-split-down",
		doc = "Show this pane's file in a new pane below",
		run = function()
			M.split("down")
		end,
	},
	{
		name = "pane-terminal",
		doc = "Open a terminal in a new pane",
		run = function()
			M.terminal_pane()
		end,
	},
	{
		name = "pane-terminal-right",
		doc = "Open a terminal in a new pane on the right",
		run = function()
			M.terminal_pane("right")
		end,
	},
	{
		name = "pane-terminal-down",
		doc = "Open a terminal in a new pane below",
		run = function()
			M.terminal_pane("down")
		end,
	},
	{ name = "pane-close", doc = "Close this pane", run = M.close_pane },
	{ name = "pane-only", doc = "Close every other pane in the tab", run = M.only },
	{ name = "pane-zoom", doc = "Show only this pane, or all of them again", run = M.toggle_zoom },
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
		name = "pane-resize-left",
		doc = "Move this pane's left edge out",
		run = function()
			M.resize("left")
		end,
	},
	{
		name = "pane-resize-right",
		doc = "Move this pane's right edge out",
		run = function()
			M.resize("right")
		end,
	},
	{
		name = "pane-resize-up",
		doc = "Move this pane's top edge up",
		run = function()
			M.resize("up")
		end,
	},
	{
		name = "pane-resize-down",
		doc = "Move this pane's bottom edge down",
		run = function()
			M.resize("down")
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
	{ name = "pane-mode-leave", doc = "Back from the pane or tab mode", run = leave },
}

local by_name: { [string]: () -> () } = {}
for _, c in commands do
	local run = c.run
	kern.command({
		name = c.name,
		doc = c.doc,
		run = function()
			run()
			-- Messages go with the next key; while still in a mode, its keys
			-- stay on the status line.
			local mode = modes[kern.mode.get()]
			if mode then
				kern.echo(mode.hint)
			end
		end,
	})
	by_name[c.name] = c.run
end

kern.command({
	name = "tab-go",
	doc = "Show tab N",
	args = { { name = "n", doc = "The tab's number, from 1" } },
	run = function(ctx)
		M.go_to_tab(tonumber(ctx.args[1] or ctx.keys and string.match(ctx.keys, "%d+$") or "") or 1)
	end,
})

-- Saves the tab as the layout named in `args`, or asks for a name.
local function save_layout(args: { string }, mine: boolean)
	local function save(name: string)
		local file, err = M.saved.save(name, mine)
		kern.echo(if file then `saved layout {name} in {file}` else `can't save it: {err}`)
	end
	if args[1] then
		save(args[1])
	else
		core.prompt.open({ title = "Save layout as", on_submit = save })
	end
end

kern.command({
	name = "layout-save",
	doc = "Save this tab's panes, and what they show, as a layout of the project",
	args = { { name = "name", doc = "What to call it" } },
	run = function(ctx)
		save_layout(ctx.args, false)
	end,
})

kern.command({
	name = "layout-save-mine",
	doc = "Save this tab's panes, and what they show, as a layout for any project",
	args = { { name = "name", doc = "What to call it" } },
	run = function(ctx)
		save_layout(ctx.args, true)
	end,
})

kern.command({
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
			kern.echo("no saved layouts yet; :layout-save NAME saves this tab")
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
	kern.command({
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
		["alt-f"] = "terminal-float",
		["alt-="] = "pane-grow",
		["alt-+"] = "pane-grow",
		["alt--"] = "pane-shrink",
		["alt-["] = "tab-previous",
		["alt-]"] = "tab-next",
		["alt-p"] = "pane-mode",
		["alt-space"] = "layout-next",
		["alt-m"] = "layout-swap-main",
		["alt-t"] = "tab-mode",
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
		w = "terminal-float",
		space = "layout-next",
		m = "layout-swap-main",
		o = "layout-rotate",
		["]"] = "layout-main-grow",
		["["] = "layout-main-shrink",
		y = "layout-pick",
		p = "pane-place",
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
	-- After ctrl-w (and space w) in normal mode, as in Vim and Helix.
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
	back = "normal",
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
		"f",
		"w",
		"space",
		"m",
		"o",
		"y",
		"H",
		"=",
		"-",
		"esc",
	}),
}
modes.tab = { back = "normal", hint = hint(M.keys.tab, { "h", "l", "n", "t", "x", "r", "esc" }) }

-- Binds `M.keys` in the layers they belong to. The terminal's mode takes
-- every key, so the everywhere keys are bound in it too.
local function bind()
	kern.keymap.bind({}, M.keys.everywhere)
	kern.keymap.bind("terminal", M.keys.everywhere)
	for mode in modes do
		kern.keymap.isolate(mode)
		kern.keymap.bind(mode, M.keys[mode])
		kern.keymap.fallback(mode, "pane-mode-leave")
	end
	kern.keymap.bind("pane-place", M.keys.place)
	kern.keymap.fallback("pane-place", "pane-place-cancel")
	local window: { [string]: string } = {}
	for key, name in M.keys.window do
		window[`ctrl-w {key}`] = name
		window[`space w {key}`] = name
	end
	kern.keymap.bind("normal", window)
	kern.keymap.bind("vim", window)
	kern.keymap.bind("vim", { ["g t"] = "tab-next", ["g T"] = "tab-previous" })
end

bind()

-- Clicking a tab in the tab line shows it.
kern.on("mouse", function(event: kern.MouseEvent)
	if event.kind == "press" and event.tab then
		kern.tab.switch(event.tab)
		settle(kern.view())
	end
end)

return M
