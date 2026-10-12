-- Running a block in a pseudo terminal, as typed commands run: programs
-- see a terminal, so they print colors and progress, and their output and
-- errors come merged, in order. Lines the terminal wrapped are joined
-- again, so a block's text doesn't depend on any screen's width.
--
-- A program that wants a terminal of its own (a full screen one like an
-- editor or a pager, one reading keys raw, or a password prompt with echo
-- off) is handed to a terminal in the pane it ran from, which goes back to
-- the shell once it's done with the screen or exits. One that goes quiet
-- while it could be reading a line says so, and ctrl-t hands it over too.

local greed = require("@greed")
local core = require("@core")
local terminal = require("@terminal")
local state = require("./state")
local log = require("./log")
local run = require("./run")

type Shell = state.Shell
type Block = state.Block
type Line = log.Line

local M = {}

-- How long a program has to keep wanting a terminal before it's handed
-- one, so one that only touches the terminal's settings on its way isn't.
local SETTLE_MS = 100

-- How long a program in a line mode prints nothing before the block says
-- it may be waiting for input.
local QUIET_MS = 1000

-- How many lines that scrolled off its screen a block's terminal keeps
-- until they're read; they're read as they come, so only output faster
-- than a frame's worth of this can be lost.
local SCROLLBACK = 5000

-- A block's terminal, and how far it's been read.
type Run = {
	shell: Shell,
	block: Block,
	terminal: greed.Terminal,
	cols: number,
	-- The next scrollback line to read, and rows read whose line carries
	-- on (the terminal wrapped it) on rows not read yet.
	next: number,
	carry: { greed.TerminalRow },
	-- The terminal plugin's handle while it shows the program, to type
	-- into.
	shown: any?,
	-- What ended it, when the shell did.
	stopped: string?,
	-- When it last printed something.
	printed: number,
	-- Called with how it exited before the block finishes.
	before: ((code: number?, signal: string?) -> ())?,
	-- Whether a draw is under way, and whether more came in meanwhile.
	drawing: boolean,
	stale: boolean,
	-- The program's exit code, once it exited.
	exited: number?,
}

-- Runs by their terminal's id.
local runs: { [number]: Run } = {}

local function run_of(t: greed.Terminal): Run?
	return runs[t:id()]
end

local function run_for(block: Block): Run?
	for _, r in runs do
		if r.block == block then
			return r
		end
	end
	return nil
end

-- A text width for `text`, to pad a wrapped row to the screen's width.
local width = core.text.width

-- One line made of `rows`, each but the last wrapped onto the next: their
-- text joined, with their styles and links moved along.
local function join(rows: { greed.TerminalRow }, cols: number): Line
	local parts: { string } = {}
	local marks: { greed.Mark } = {}
	local at = 0
	for i, row in rows do
		local text = row.text
		-- A wrapped row filled the screen; spaces it ended in may have been
		-- trimmed off its text.
		if i < #rows and row.wrapped then
			text ..= string.rep(" ", math.max(cols - width(text), 0))
		end
		for _, span in row.spans do
			table.insert(marks, { from = at + span.from, to = at + span.to, style = span.style })
		end
		for _, link in row.links do
			table.insert(marks, { from = at + link.from, to = at + link.to, style = "markup.link" })
		end
		table.insert(parts, text)
		at += #text
	end
	return { text = table.concat(parts), marks = marks }
end

-- The rows of `screen` with output: up to the cursor's row (taking that one
-- only when it has text), and any with text below it.
local function used_rows(screen: greed.TerminalScreen): { greed.TerminalRow }
	local last = 0
	local cursor = screen.cursor
	if cursor then
		local row = screen.rows[cursor.row + 1]
		last = if cursor.col > 0 or (row and row.text ~= "") then cursor.row + 1 else cursor.row
		last = math.min(last, #screen.rows)
	end
	for i = #screen.rows, last + 1, -1 do
		if screen.rows[i].text ~= "" then
			last = i
			break
		end
	end
	return table.move(screen.rows, 1, last, 1, {})
end

-- Splits `rows` into lines on the rows that don't wrap; the rows of a line
-- still carrying on at the end are returned apart.
local function lines_of(
	rows: { greed.TerminalRow },
	cols: number
): ({ Line }, { greed.TerminalRow })
	local lines: { Line } = {}
	local group: { greed.TerminalRow } = {}
	for _, row in rows do
		table.insert(group, row)
		if not row.wrapped then
			table.insert(lines, join(group, cols))
			group = {}
		end
	end
	return lines, group
end

-- Keeps `lines` in the block's record, one line each.
local function record(block: Block, lines: { Line })
	if #lines == 0 then
		return
	end
	local texts = table.create(#lines)
	for i, line in lines do
		texts[i] = line.text
	end
	run.record(block, table.concat(texts, "\n") .. "\n", "stdout")
end

-- Shows what the program printed since last time: lines that scrolled off
-- its screen join the block for good, and its screen is drawn again under
-- them. With `final`, the screen joins too.
local function draw(r: Run, final: boolean)
	local block = r.block
	local t = r.terminal
	if not t:valid() then
		return
	end
	local scrolled = t:scrollback(r.next)
	local stable: { Line } = {}
	if scrolled.first > r.next then
		-- More went by than the terminal keeps.
		local said = `… {scrolled.first - r.next} lines went by too fast to keep`
		table.insert(
			stable,
			{ text = said, marks = { { from = 0, to = #said, style = "shell.status" } } }
		)
		r.carry = {}
	end
	r.next = scrolled.first + #scrolled.rows
	local rows = r.carry
	table.move(scrolled.rows, 1, #scrolled.rows, #rows + 1, rows)
	local done, carry = lines_of(rows, r.cols)
	table.move(done, 1, #done, #stable + 1, stable)
	r.carry = carry
	record(block, done)
	local now = t:screen()
	if now.alternate and not final then
		-- A full screen program's screen isn't output; the terminal it's
		-- handed to shows it.
		log.update(r.shell, block, stable, nil)
		return
	end
	local screen = table.clone(carry)
	local used = used_rows(now)
	table.move(used, 1, #used, #screen + 1, screen)
	local volatile, rest = lines_of(screen, r.cols)
	if #rest > 0 then
		table.insert(volatile, join(rest, r.cols))
	end
	if final then
		record(block, volatile)
		table.move(volatile, 1, #volatile, #stable + 1, stable)
		volatile = {}
		r.carry = {}
	end
	log.update(r.shell, block, stable, volatile)
end

-- Whether `t`'s program wants a terminal of its own: a full screen, keys
-- one at a time, or no echo for a password.
local function wants_terminal(t: greed.Terminal): boolean
	local modes = t:modes()
	return modes.alternate or not modes.canonical or not modes.echo
end

-- A view to hand `r`'s program over in: the one it ran from, while that
-- shows the shell, else one that shows it, else the focused one.
local function view_for(r: Run): greed.View
	local from = state.views[r.block.uid]
	if from and from:valid() and from:buffer() == r.shell.buffer then
		return from
	end
	return r.shell.buffer:views()[1] or greed.view()
end

-- Views a program was handed over in, by id, with the shell they show
-- again once it's done: the cursor goes back to the prompt there.
local returning: { [number]: Shell } = {}

--- Shows the program running `block` in a terminal, to type into, in the
--- pane it ran from. It comes back when the program is done with the
--- screen or exits. False when it can't be.
function M.handoff(block: Block): boolean
	local r = run_for(block)
	if r == nil then
		return false
	end
	if r.shown and terminal.is_open(r.shown) then
		return true
	end
	if block.status ~= "running" or not r.terminal:valid() then
		return false
	end
	block.handed = true
	block.waiting = false
	local view = view_for(r)
	returning[view:id()] = r.shell
	r.shown = terminal.adopt(r.terminal, {
		view = view,
		previous = r.shell.buffer,
		return_on_primary = true,
		title = block.command,
	})
	log.draw_block(r.shell, block)
	return true
end

-- Back from a terminal, the view's cursor is at the prompt again.
greed.on("selection.changed", function(event: greed.SelectionChanged)
	local view = event.view
	local shell = returning[view:id()]
	if shell and view:valid() and view:buffer() == shell.buffer then
		returning[view:id()] = nil
		view:set_cursor(shell.buffer:len())
	end
end)

-- Looks at `r`'s program every `SETTLE_MS` while it runs: one that wants a
-- terminal two looks in a row is handed one, and one quiet a while in a
-- line mode, as `read` or a question is, may be waiting for input.
local function watch(r: Run)
	greed.spawn(function()
		local wanted = false
		while true do
			greed.sleep(SETTLE_MS)
			local block = r.block
			if block.status ~= "running" or not r.terminal:valid() then
				break
			end
			if r.shown and not terminal.is_open(r.shown) then
				-- It came back to the shell, and may be handed over again.
				r.shown = nil
			end
			local wants = r.shown == nil and wants_terminal(r.terminal)
			if wants and wanted then
				M.handoff(block)
			end
			wanted = wants
			local waiting = r.shown == nil and not wants and greed.now() - r.printed >= QUIET_MS
			if waiting ~= block.waiting then
				block.waiting = waiting
				log.draw_block(r.shell, block)
			end
		end
	end)
end

-- Ends `r`'s block once its program exited with `code`.
local function finish(r: Run, code: number)
	runs[r.terminal:id()] = nil
	draw(r, true)
	-- A terminal says a program ended by a signal as a failure; the shell
	-- knows when it sent one.
	local signal = if code ~= 0 then r.stopped else nil
	local exit = if signal then nil else code
	if r.before then
		r.before(exit, signal)
	end
	run.finish(r.shell, r.block, exit, signal)
	-- The terminal plugin may still be giving its view back; close it after.
	local t = r.terminal
	greed.spawn(function()
		greed.sleep(0)
		if t:valid() then
			t:close()
		end
	end)
end

-- Ends `r`'s block if its program exited and nothing ended it yet.
local function finish_if_exited(r: Run)
	local code = r.exited
	if code ~= nil and runs[r.terminal:id()] == r then
		finish(r, code)
	end
end

-- Draws `r` until nothing more came in meanwhile, then ends it if its
-- program exited. A draw's time slice can run out partway, and another
-- event start meanwhile on the half-drawn block; that one leaves it to the
-- first.
local function pump(r: Run)
	if r.drawing then
		r.stale = true
		return
	end
	r.drawing = true
	local ok, err = pcall(function()
		repeat
			r.stale = false
			if r.exited == nil then
				draw(r, false)
			end
		until not r.stale
		finish_if_exited(r)
	end)
	r.drawing = false
	if not ok then
		-- A draw that failed still ends a block whose program has exited,
		-- or it would run forever.
		finish_if_exited(r)
		error(err, 0)
	end
end

export type Options = {
	--- The screen's size; the view it ran from's by default.
	rows: number?,
	cols: number?,
	--- Hand it to a terminal right away, as `!` asks.
	terminal: boolean?,
	--- Called with how it exited, before the block finishes.
	before: ((code: number?, signal: string?) -> ())?,
}

--- Runs `argv` for `block` in a pseudo terminal sized for the view it ran
--- from.
function M.start(shell: Shell, block: Block, argv: { string }, options: Options?)
	local opts: Options = options or {}
	local rows, cols = opts.rows, opts.cols
	local from = state.views[block.uid]
	if (rows == nil or cols == nil) and from and from:valid() then
		local r, c = from:size()
		rows, cols = rows or r, cols or c
	end
	block.runner = "pty"
	local ok, started = pcall(function()
		return greed.terminal.spawn({
			command = argv,
			cwd = block.cwd,
			env = state.environment(block),
			rows = rows or 24,
			cols = cols or 80,
			scrollback = SCROLLBACK,
		})
	end)
	if not ok then
		run.fail(shell, block, tostring(started))
		return
	end
	local t = started :: greed.Terminal
	local r: Run = {
		shell = shell,
		block = block,
		terminal = t,
		cols = cols or 80,
		next = 0,
		carry = {},
		shown = nil,
		stopped = nil,
		printed = greed.now(),
		before = opts.before,
		drawing = false,
		stale = false,
		exited = nil,
	}
	runs[t:id()] = r
	block.job = {
		interrupt = function()
			r.stopped = "INT"
			t:key("ctrl-c")
		end,
		kill = function()
			r.stopped = "KILL"
			t:kill()
		end,
		handoff = function(): boolean
			return M.handoff(block)
		end,
		terminal = t,
	}
	if opts.terminal then
		M.handoff(block)
	end
	watch(r)
end

greed.on("terminal.output", function(event)
	local r = run_of(event.terminal)
	if r == nil or r.block.status ~= "running" then
		return
	end
	r.printed = greed.now()
	if r.block.waiting then
		r.block.waiting = false
		log.draw_block(r.shell, r.block)
	end
	pump(r)
end)

greed.on("terminal.exited", function(event)
	local r = run_of(event.terminal)
	if r then
		r.exited = event.code
		pump(r)
	end
end)

-- Only the client a block ran for resizes its terminal: the others'
-- views changing size would fight over it.
greed.on("view.resized", function(event: greed.ViewResized)
	for _, r in runs do
		if
			r.shown == nil
			and r.block.client == event.client
			and event.view:buffer() == r.shell.buffer
			and r.terminal:valid()
		then
			r.cols = event.cols
			r.terminal:resize(event.rows, event.cols)
		end
	end
end)

return M
