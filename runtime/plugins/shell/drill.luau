-- Drilling down: what an action on a row runs (enter on a pod, or `.` and
-- "describe") shows where you are, in a float over the shell titled with
-- the way there (`❯ 3 pods › api-7d9f › describe`), rather than at the
-- bottom of the shell out of sight. Acting on a row in it goes a level
-- further down in its place; `esc` goes back up one, to the row you were
-- on. Every block still lands in the shell too, in the order it ran.

local greed = require("@greed")
local state = require("./state")
local log = require("./log")
local peek = require("./peek")

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
}

-- The levels open, the deepest last.
local levels: { Level } = {}

local FOOTER = "esc back · enter or space . on a row · / filter · ctrl-c stops"

local function level_of(view: greed.View): Level?
	for _, level in levels do
		if level.view == view then
			return level
		end
	end
	return nil
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
	view:configure({ title = level.title, footer = FOOTER, width = "95%", height = "90%" })
	if at then
		view:set_cursor(at)
	end
	level.view = view
end

--- Shows `block` of `shell`, what an action on a row ran from `from`, as a
--- level down from where `from` is: `step` names the way, like
--- "api-7d9f › describe". `tail` follows the block's last line, for one
--- that keeps showing what's new.
function M.open(shell: Shell, block: Block, step: string, from: greed.View, tail: boolean?)
	local parent = level_of(from)
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
	}
	if parent then
		parent.replaced = true
		parent.at = from:cursor()
		parent.view:close()
	end
	table.insert(levels, level)
	show(level, nil, tail)
end

--- Whether `view` is a level drilled down to.
function M.is(view: greed.View): boolean
	return level_of(view) ~= nil
end

-- A level's float closing goes back up a level: to the one above, shown
-- again where it was, or to the row the first action was taken from.
greed.on("view.closed", function(event: greed.ViewClosed)
	for i = #levels, 1, -1 do
		local level = levels[i]
		if level.view:id() == event.view then
			-- Kept, to come back to from the level below.
			if level.replaced then
				return
			end
			table.remove(levels, i)
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
end)

-- Closes every level's float, going nowhere: what replaced them shows.
local function close_all()
	local open = levels
	levels = {}
	for _, level in open do
		if level.view:valid() then
			level.view:close()
		end
	end
end

-- A file opened from a level, as a row of files does, opens where the
-- first action was taken, and the levels go: in a level's float it's moved
-- there, and opened there already, the floats over it close.
greed.on("selection.changed", function(event: greed.SelectionChanged)
	local view = event.view
	if #levels == 0 or not view:valid() then
		return
	end
	local first = levels[1]
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

return M
