-- Blocks mode: a shell's commands, and the rows they printed, as things to
-- move between and act on with a key. `esc` at the prompt comes here, and
-- so does clicking in what a command printed; typing goes back to the
-- prompt with what's typed. Nothing here edits the shell's text: `o` opens
-- a block's output in a buffer of its own for that.
--
--     up down (k j)    a step through everything: a command, its rows,
--                      the next command
--     J K              the next or previous command, past the rows
--     right (l)        into the command's rows; left (h) back to it
--     enter            change the command at the prompt, to run in its
--                      place; on a row, what the row does (open a file,
--                      describe a pod)
--     r                run it again in its place
--     /                filter its rows
--     .                what can be done with it
--     b                what it showed the run before
--     d                what changed since the run before
--     y  Y             copy what it printed, or its command
--     o                open what it printed in a buffer
--     s                stop it
--     tab              fold or unfold it
--     g  G             the first or last command
--     esc  i  a        back to the prompt

local greed = require("@greed")
local core = require("@core")
local state = require("./state")
local log = require("./log")
local rows = require("./rows")

type Shell = state.Shell
type Block = state.Block

local M = {}

M.MODE = "blocks"

local NS = "shell.selected"

greed.option.define({
	name = "shell-blocks",
	doc = "In the shell, esc and clicks in output go to blocks mode, to move between commands and rows and act on them",
	default = true,
})

--- Whether blocks mode is on for shells.
function M.on(): boolean
	return greed.option.get("shell-blocks") == true
end

-- The shell `view` shows, if it shows one.
local function shell_in(view: greed.View): Shell?
	return state.of(view:buffer())
end

-- The line `block`'s command is on, if it's still there.
local function command_line(shell: Shell, block: Block): number?
	local from = log.range(block)
	return if from then shell.buffer:line_of(from) else nil
end

-- The lines of `block`'s output that are things to land on: its table's
-- rows, or the lines with something on them.
local function row_lines(shell: Shell, block: Block): { number }
	local from, to = log.output_range(shell, block)
	if from == nil or to == nil then
		return {}
	end
	local buffer = shell.buffer
	local found: { number } = {}
	for line = buffer:line_of(from), buffer:line_of(to) do
		local start = buffer:line_start(line)
		local thing = if block.table
			then rows.row_at(shell, block, start) ~= nil
			else string.match(buffer:line_text(line), "%S") ~= nil
		if thing then
			table.insert(found, line)
		end
	end
	return found
end

-- The blocks of `shell` in the order they show, top to bottom.
local function in_order(shell: Shell): { Block }
	local list: { Block } = {}
	for _, block in shell.blocks do
		if log.range(block) then
			table.insert(list, block)
		end
	end
	table.sort(list, function(a: Block, b: Block): boolean
		return (log.range(a) :: number) < (log.range(b) :: number)
	end)
	return list
end

--- What `view`'s cursor is on in blocks mode: the block, and the line of
--- its row when it's on one rather than on the command.
function M.at(view: greed.View): (Block?, number?)
	local shell = shell_in(view)
	if shell == nil then
		return nil, nil
	end
	local pos = view:cursor()
	local block = log.block_at(shell, pos)
	if block == nil then
		return nil, nil
	end
	local line = shell.buffer:line_of(pos)
	if line == command_line(shell, block) then
		return block, nil
	end
	return block, line
end

-- Puts `view`'s cursor at the start of `line`.
local function land(view: greed.View, line: number)
	view:set_cursor(view:buffer():line_start(line))
end

-- Puts `view` on `block`'s command.
local function select_block(view: greed.View, shell: Shell, block: Block)
	local line = command_line(shell, block)
	if line then
		land(view, line)
	end
end

-- What can be done with what's selected, for the line under it.
local function hint(on_row: boolean, block: Block): string
	if on_row then
		return "enter what it does · . actions · y copy · J K commands · esc prompt"
	end
	local parts = { "enter change", "r run again", "/ filter", ". actions" }
	if block.before then
		table.insert(parts, "b before")
		table.insert(parts, "d what changed")
	end
	table.insert(parts, "↓ rows")
	table.insert(parts, "J K commands")
	table.insert(parts, "esc prompt")
	return table.concat(parts, " · ")
end

-- What each shell's buffer shows as selected now, to draw it only when
-- that changes.
local drawn: { [number]: string } = {}

-- The block each view ran again in its place, by the view's id: its text
-- is written anew as it runs, which moves the cursor, so the cursor goes
-- back to it until you move.
local pinned: { [number]: Block } = {}

-- Marks `buffer`'s selected line as `marks` say, unless it shows that
-- already (`key`).
local function decorate(buffer: greed.Buffer, key: string, marks: { greed.Mark })
	if drawn[buffer:id()] ~= key then
		drawn[buffer:id()] = key
		buffer:decorate(NS, marks)
	end
end

--- Shows what `view` has selected in blocks mode: its line marked, and
--- what can be done with it under it. Nothing outside blocks mode.
function M.draw(view: greed.View)
	local shell = shell_in(view)
	if shell == nil then
		return
	end
	local buffer = shell.buffer
	local block, row = M.at(view)
	local line = if greed.mode.get() == M.MODE and block
		then row or command_line(shell, block)
		else nil
	if line == nil or block == nil then
		decorate(buffer, "", {})
		return
	end
	local start, stop = buffer:line_start(line), buffer:line_end(line)
	local says = hint(row ~= nil, block)
	decorate(buffer, `{start}:{stop}:{says}`, {
		{ from = start, to = stop, style = "shell.selected", line = true },
		{ from = stop, to = stop, style = "shell.hint", lines = { says } },
	})
end

--- Goes to blocks mode in `view`, on the block at the cursor, or the last
--- one from the prompt. Says so when there's nothing to go to.
function M.enter(view: greed.View): boolean
	local shell = shell_in(view)
	if shell == nil then
		return false
	end
	local block, row = M.at(view)
	if block == nil then
		local all = in_order(shell)
		block = all[#all]
		if block == nil then
			greed.echo("nothing has run here yet")
			return false
		end
		select_block(view, shell, block)
	elseif row then
		land(view, row)
	else
		select_block(view, shell, block)
	end
	greed.mode.set(M.MODE)
	M.draw(view)
	return true
end

--- Back to the prompt in `view`, typing at its end.
function M.leave(view: greed.View)
	local shell = shell_in(view)
	if shell == nil then
		greed.mode.set(core.style.home())
		return
	end
	greed.mode.set(core.style.typing_mode())
	view:set_cursor(shell.buffer:len())
	M.draw(view)
end

-- Whether `block` is folded under its command, its rows out of sight.
local function folded(shell: Shell, block: Block): boolean
	local line = command_line(shell, block)
	return line ~= nil and core.folds.starts(shell.buffer, line)
end

-- The rows of `block` to move through: none while it's folded.
local function visible_rows(shell: Shell, block: Block): { number }
	return if folded(shell, block) then {} else row_lines(shell, block)
end

-- Moves `view` to the command after or before (`back`) the one it's on.
local function to_command(view: greed.View, back: boolean)
	local shell = shell_in(view)
	local block = M.at(view)
	if shell == nil or block == nil then
		return
	end
	local all = in_order(shell)
	local i = table.find(all, block) or 0
	local to = all[if back then i - 1 else i + 1]
	if to then
		select_block(view, shell, to)
	elseif not back then
		greed.echo("the last command: esc goes to the prompt")
	end
end

-- Moves `view` a step down, or up with `back`, through everything in
-- order: a command, its rows, the next command.
local function step(view: greed.View, back: boolean)
	local shell = shell_in(view)
	local block, row = M.at(view)
	if shell == nil or block == nil then
		return
	end
	local rows_here = visible_rows(shell, block)
	if back then
		local i = if row then table.find(rows_here, row) else nil
		if i and i > 1 then
			land(view, rows_here[i - 1])
		elseif row then
			select_block(view, shell, block)
		else
			local all = in_order(shell)
			local before = all[(table.find(all, block) or 0) - 1]
			if before then
				local above = visible_rows(shell, before)
				if #above > 0 then
					land(view, above[#above])
				else
					select_block(view, shell, before)
				end
			end
		end
		return
	end
	local i = if row then table.find(rows_here, row) or 0 else 0
	local to = rows_here[i + 1]
	if to then
		land(view, to)
	else
		to_command(view, false)
	end
end

local function command(name: string, doc: string, run: (view: greed.View) -> ())
	greed.command({
		name = name,
		doc = doc,
		run = function(ctx)
			pinned[ctx.view:id()] = nil
			run(ctx.view)
			M.draw(ctx.view)
		end,
	})
end

command(
	"shell-blocks",
	"Go to blocks mode, to move between commands and act on them",
	function(view)
		M.enter(view)
	end
)

command("shell-blocks-prompt", "Go back to the prompt", M.leave)

command("shell-blocks-up", "Up a step: the row before, or the command before", function(view)
	step(view, true)
end)

command("shell-blocks-down", "Down a step: the next row, or the next command", function(view)
	step(view, false)
end)

command("shell-blocks-next", "The next command, past its rows", function(view)
	to_command(view, false)
end)

command("shell-blocks-previous", "The command before", function(view)
	local shell = shell_in(view)
	local block, row = M.at(view)
	if shell and block and row then
		select_block(view, shell, block)
	else
		to_command(view, true)
	end
end)

command("shell-blocks-rows", "Into the rows the command printed", function(view)
	local shell = shell_in(view)
	local block, row = M.at(view)
	if shell == nil or block == nil or row then
		return
	end
	-- A folded block opens to show its rows.
	greed.run("fold-open")
	local first = row_lines(shell, block)[1]
	if first then
		land(view, first)
	else
		greed.echo("it printed nothing")
	end
end)

command("shell-blocks-out", "Back out of the rows to the command", function(view)
	local shell = shell_in(view)
	local block = M.at(view)
	if shell and block then
		select_block(view, shell, block)
	end
end)

command("shell-blocks-first", "The first command", function(view)
	local shell = shell_in(view)
	local first = shell and in_order(shell)[1]
	if shell and first then
		select_block(view, shell, first)
	end
end)

command("shell-blocks-last", "The last command", function(view)
	local shell = shell_in(view)
	local all = if shell then in_order(shell) else {}
	if shell and #all > 0 then
		select_block(view, shell, all[#all])
	end
end)

greed.command({
	name = "shell-blocks-rerun",
	doc = "Run the selected command again in its place, staying on it",
	run = function(ctx)
		local block = M.at(ctx.view)
		if block then
			pinned[ctx.view:id()] = block
		end
		greed.run("shell-rerun-in-place")
	end,
})

command("shell-blocks-filter", "Filter the rows the command printed", function(view)
	local shell = shell_in(view)
	local block = M.at(view)
	local from = shell and block and log.output_range(shell, block)
	if from then
		view:set_cursor(from)
	end
	greed.run("shell-filter")
end)

-- Typing in blocks mode goes to the prompt, with what was typed.
greed.command({
	name = "shell-blocks-type",
	doc = "Go back to the prompt and type there",
	run = function(ctx)
		M.leave(ctx.view)
		if ctx.char then
			local buffer = ctx.view:buffer()
			local at = buffer:len()
			buffer:edit(function(e)
				e:insert(at, ctx.char :: string)
			end)
			ctx.view:set_cursor(buffer:len())
		end
	end,
})

-- Blocks mode is the shell's alone: a view showing something else, or
-- another view focused, goes back to the style's own mode.
local function leave_elsewhere(view: greed.View)
	if greed.mode.get() == M.MODE and view:valid() and view == greed.view() then
		greed.mode.set(core.style.home())
	end
end

-- A click is a move of your own.
greed.on("mouse", function(event: greed.MouseEvent)
	if event.kind == "press" and event.view then
		pinned[event.view:id()] = nil
	end
end)

greed.on("view.focused", function(event: greed.ViewFocused)
	if not shell_in(event.view) then
		leave_elsewhere(event.view)
	end
end)

-- Keeps what's selected marked as the cursor moves, and drops the mark on
-- leaving blocks mode.
greed.on("selection.changed", function(event: greed.SelectionChanged)
	local view = event.view
	local shell = if view:valid() then shell_in(view) else nil
	if shell == nil then
		leave_elsewhere(view)
		return
	end
	-- Typing goes in the prompt alone: the cursor put elsewhere, as by a
	-- click, selects what it's on instead.
	local range = view:selection().ranges[1]
	if
		M.on()
		and core.style.is_typing()
		and range.anchor == range.head
		and not log.in_prompt(shell, range.head)
		and log.block_at(shell, range.head)
	then
		M.enter(view)
		return
	end
	M.draw(view)
end)

-- Emptying the prompt drops the command being changed, so what's typed
-- next runs as a new one.
greed.on("buffer.changed", function(event: greed.BufferChanged)
	local shell = state.of(event.buffer)
	if shell and shell.editing and log.prompt_text(shell) == "" then
		shell.editing = nil
		log.draw_prompt(shell)
	end
end)

-- What a command shows changing moves what's selected, and can change what
-- can be done with it.
log.on_update(function()
	local view = greed.view()
	local shell = if view:valid() then shell_in(view) else nil
	if shell == nil then
		return
	end
	local was = pinned[view:id()]
	if
		was
		and greed.mode.get() == M.MODE
		and M.at(view) ~= was
		and table.find(shell.blocks, was)
	then
		select_block(view, shell, was)
	end
	M.draw(view)
end)

greed.on("mode.changed", function()
	local view = greed.view()
	if view:valid() and shell_in(view) then
		M.draw(view)
	end
end)

greed.keymap.isolate(M.MODE)
greed.keymap.fallback(M.MODE, "shell-blocks-type")
greed.keymap.bind(M.MODE, {
	up = "shell-blocks-up",
	k = "shell-blocks-up",
	down = "shell-blocks-down",
	j = "shell-blocks-down",
	J = "shell-blocks-next",
	K = "shell-blocks-previous",
	["ctrl-down"] = "shell-blocks-next",
	["ctrl-up"] = "shell-blocks-previous",
	right = "shell-blocks-rows",
	l = "shell-blocks-rows",
	left = "shell-blocks-out",
	h = "shell-blocks-out",
	g = "shell-blocks-first",
	G = "shell-blocks-last",
	esc = "shell-blocks-prompt",
	i = "shell-blocks-prompt",
	a = "shell-blocks-prompt",
	enter = "shell-enter",
	r = "shell-blocks-rerun",
	["/"] = "shell-blocks-filter",
	["."] = "act",
	b = "shell-before",
	d = "shell-diff-before",
	y = "shell-copy-output",
	Y = "shell-copy-command",
	o = "shell-output-open",
	s = "shell-interrupt",
	tab = "fold-toggle",
	["ctrl-c"] = "shell-interrupt",
	["ctrl-t"] = "shell-handoff",
	["ctrl-r"] = "shell-history",
})
-- The leader works here as in the style's own modes.
greed.keymap.enter(M.MODE, "space", "leader")
greed.mode.set_cursor(M.MODE, "block")

return M
