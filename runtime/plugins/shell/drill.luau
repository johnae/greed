-- Drilling down: what an action on a row runs (enter on a pod, or `.` and
-- "describe") shows where you are, in a float over the shell titled with
-- the way there (`❯ 3 pods › api-7d9f › describe`), rather than at the
-- bottom of the shell out of sight. Acting on a row in it goes a level
-- further down in its place; `esc` goes back up one, to the row you were
-- on. Every block still lands in the shell too, in the order it ran.

local greed = require("@greed")
local core = require("@core")
local state = require("./state")
local log = require("./log")
local peek = require("./peek")
local run = require("./run")

type Shell = state.Shell
type Block = state.Block

local M = {}

-- One level down: its float and the block it shows, the way there, and
-- where to go back to: the level above (`parent`), or else the view and
-- place the first action was taken from.
type Level = {
	view: greed.View,
	shell: Shell,
	block: Block,
	title: string,
	parent: Level?,
	from: greed.View,
	at: number,
	-- Closed to make way for a level below, not to go back up.
	replaced: boolean,
	-- Its command was started to show here: going back stops it.
	owned: boolean,
}

-- The levels each client has open, the deepest last: each goes down its
-- own way.
local levels: { [number]: { Level } } = {}

-- The levels of the client the code acts for.
local function mine(): { Level }
	local id = greed.client.id()
	local list = levels[id] or {}
	levels[id] = list
	return list
end

local FOOTER = "esc back · enter or space . on a row · / filter · ctrl-c stops"

-- Goes back up keeping the command running, as ctrl-z puts a job in the
-- background in a shell.
local KEEP = "ctrl-z"

-- For a level whose command was started to show there.
local OWNED_FOOTER =
	`esc back, stopping it · {KEEP} back, keeping it running · / filter · . on a row`

-- The level `view` shows, and the list of levels it's in.
local function level_of(view: greed.View): (Level?, { Level }?)
	for _, list in levels do
		for _, level in list do
			if level.view == view then
				return level, list
			end
		end
	end
	return nil, nil
end

-- A block in a few words, for the first step of the way: its number and
-- what its rows are, or its command.
local function named(block: Block): string
	local what = if block.called
		then block.called.many
		else string.match(block.command, "^%S+") or block.command
	return `❯ {block.number} {what}`
end

-- Shows `level`'s float: its block, its title, the cursor at `at`.
local function show(level: Level, at: number?, tail: boolean?)
	-- From the top, unless it keeps showing what's new.
	local view = peek.open(level.shell, level.block, { focus = true, tail = tail == true })
	if view == nil then
		return
	end
	local running = level.owned and level.block.status == "running"
	view:configure({
		title = level.title,
		footer = if running then OWNED_FOOTER else FOOTER,
		width = "95%",
		height = "90%",
	})
	if at then
		view:set_cursor(at)
	end
	level.view = view
end

--- Shows `block` of `shell`, what an action on a row ran from `from`, as a
--- level down from where `from` is: `step` names the way, like
--- "api-7d9f › describe". `tail` follows the block's last line, for one
--- that keeps showing what's new. A block `owned`, started to show here,
--- stops when its level is gone back from.
function M.open(
	shell: Shell,
	block: Block,
	step: string,
	from: greed.View,
	tail: boolean?,
	owned: boolean?
)
	local parent, list = level_of(from)
	local above: string
	if parent then
		above = parent.title
	else
		local here = log.block_at(shell, from:cursor())
		above = if here then named(here) else shell.name
	end
	local level: Level = {
		view = from,
		shell = shell,
		block = block,
		title = `{above} › {step}`,
		parent = parent,
		from = from,
		at = from:cursor(),
		replaced = false,
		owned = owned == true,
	}
	if parent then
		parent.replaced = true
		parent.at = from:cursor()
		parent.view:close()
	end
	table.insert(list or mine(), level)
	show(level, nil, tail)
end

--- Whether `view` is a level drilled down to.
function M.is(view: greed.View): boolean
	return level_of(view) ~= nil
end

-- A level's float closing goes back up a level: to the one above, shown
-- again where it was, or to the row the first action was taken from.
greed.on("view.closed", function(event: greed.ViewClosed)
	for _, list in levels do
		for i = #list, 1, -1 do
			local level = list[i]
			if level.view:id() == event.view then
				-- Kept, to come back to from the level below.
				if level.replaced then
					return
				end
				table.remove(list, i)
				local job = level.block.job
				if level.owned and level.block.status == "running" and job then
					job.interrupt()
				end
				local parent = level.parent
				if parent then
					parent.replaced = false
					show(parent, parent.at)
				elseif level.from:valid() then
					level.from:focus()
					level.from:set_cursor(level.at)
				end
				return
			end
		end
	end
end)

-- A level's command ending has nothing left to stop or keep running: its
-- footer says what's left to do.
run.on_finish(function(_, block: Block)
	for _, list in levels do
		for _, level in list do
			if level.block == block and not level.replaced and level.view:valid() then
				level.view:configure({ footer = FOOTER })
			end
		end
	end
end)

-- Closes the acting client's levels' floats, going nowhere: what replaced
-- them shows.
local function close_all()
	local id = greed.client.id()
	local open: { Level } = levels[id] or {}
	levels[id] = nil
	for _, level in open do
		if level.view:valid() then
			level.view:close()
		end
	end
end

-- A file opened from a level, as a row of files does, opens where the
-- first action was taken, and the client's levels go: in a level's float
-- it's moved there, and opened there already, the floats over it close.
greed.on("selection.changed", function(event: greed.SelectionChanged)
	local view = event.view
	local list = levels[event.client]
	if list == nil or #list == 0 or not view:valid() then
		return
	end
	local first = list[1]
	if view:buffer() == first.shell.buffer then
		return
	end
	if view == first.from then
		close_all()
	elseif level_of(view) then
		local opened, at = view:buffer(), view:cursor()
		close_all()
		if first.from:valid() then
			first.from:show(opened)
			first.from:set_cursor(at)
			first.from:focus()
		end
	end
end)

greed.command({
	name = "shell-drill-keep",
	doc = "Go back up from a level drilled down to, keeping its command running in the shell",
	run = function(ctx)
		local level = level_of(ctx.view)
		if level then
			level.owned = false
			ctx.view:close()
			return
		end
		-- Anywhere else the key does what it always does, like undo in vscode.
		core.keys.otherwise(KEEP, "shell-drill-keep")
	end,
})
greed.keymap.bind({ role = "command", kind = "shell" }, { [KEEP] = "shell-drill-keep" })
greed.keymap.bind(
	{ style = "vscode", role = "typing", kind = "shell" },
	{ [KEEP] = "shell-drill-keep" }
)

return M
