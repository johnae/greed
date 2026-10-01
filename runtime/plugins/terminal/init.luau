-- Terminals: a shell, or any program, in a buffer. `:terminal [command]`
-- opens one in the main view and sends it every key; ctrl-\ goes back to
-- the editing style's mode, where the output is text to select, search
-- and copy, and i or enter types into the program again.
--
-- The buffer holds the lines that scrolled off the top, then the screen.
-- Output replaces the screen part and adds what scrolled off above it.

local kern = require("@kern")
local core = require("@core")
local picker = require("@picker")

kern.option.define({
	name = "terminal-scrollback",
	doc = "How many lines that scrolled off a terminal's screen are kept",
	default = 10000,
})

local MODE = "terminal"

type Term = {
	terminal: kern.Terminal,
	buffer: kern.Buffer,
	-- How many lines above the screen the buffer holds.
	history: number,
	-- The next scrollback line to add, counting from the first ever.
	next: number,
	-- The most it keeps above the screen.
	limit: number,
	-- Namespaces styling the lines above the screen, oldest first, with how
	-- many lines each covers.
	chunks: { { ns: string, lines: number } },
	chunk: number,
	-- What the main view showed before, to go back to when it closes.
	previous: kern.Buffer?,
	-- What it runs, as typed.
	command: string,
}

local M = {}

-- Terminals by the id of their buffer.
local terms: { [number]: Term } = {}

local function term_of(buffer: kern.Buffer): Term?
	local ok, id = pcall(buffer.id, buffer)
	return if ok then terms[id] else nil
end

local function shown(term: Term): boolean
	return kern.view():buffer():id() == term.buffer:id()
end

--- The terminal shown in `buffer`, if it's one.
function M.terminal(buffer: kern.Buffer): kern.Terminal?
	local term = term_of(buffer)
	return term and term.terminal
end

-- Styles for `rows`, which start at line `line` of the buffer.
local function marks(buffer: kern.Buffer, rows: { kern.TerminalRow }, line: number): { kern.Mark }
	local list = {}
	for i, row in rows do
		local start = buffer:line_start(line + i - 1)
		for _, span in row.spans do
			table.insert(
				list,
				{ from = start + span.from, to = start + span.to, style = span.style }
			)
		end
	end
	return list
end

-- Drops the oldest lines above the screen beyond the limit, with their
-- styles.
local function trim(term: Term)
	local extra = term.history - term.limit
	if extra <= 0 then
		return
	end
	local buffer = term.buffer
	buffer:edit(function(e)
		e:delete(0, buffer:line_start(extra))
	end)
	term.history -= extra
	while extra > 0 and #term.chunks > 0 do
		local oldest = term.chunks[1]
		if oldest.lines > extra then
			oldest.lines -= extra
			break
		end
		extra -= oldest.lines
		buffer:decorate(oldest.ns, {})
		table.remove(term.chunks, 1)
	end
end

-- Puts the cursor where the program's is, and keeps the screen in view
-- while typing into it or when already at the bottom.
local function follow(term: Term, screen: kern.TerminalScreen, before: number)
	if not shown(term) then
		return
	end
	local view = kern.view()
	local typing = kern.mode.get() == MODE
	if typing and screen.cursor then
		local pos = term.buffer:line_start(term.history + screen.cursor.row) + screen.cursor.col
		view:set_selection({ ranges = { { anchor = pos, head = pos } }, primary = 1 })
	end
	if typing or view:scroll() >= before then
		view:set_scroll(term.history)
	end
end

--- Shows the terminal's latest output in its buffer.
function M.update(term: Term)
	local buffer = term.buffer
	local scrolled = term.terminal:scrollback(term.next)
	local screen = term.terminal:screen()
	local before = term.history
	local lines = {}
	for _, row in scrolled.rows do
		table.insert(lines, row.text)
	end
	for _, row in screen.rows do
		table.insert(lines, row.text)
	end
	local from = if before < buffer:line_count() then buffer:line_start(before) else buffer:len()
	buffer:edit(function(e)
		e:replace(from, buffer:len(), table.concat(lines, "\n"))
	end)
	term.next = scrolled.first + #scrolled.rows
	term.history += #scrolled.rows
	if #scrolled.rows > 0 then
		term.chunk += 1
		local ns = `terminal.lines.{term.chunk}`
		buffer:decorate(ns, marks(buffer, scrolled.rows, before))
		table.insert(term.chunks, { ns = ns, lines = #scrolled.rows })
	end
	trim(term)
	buffer:decorate("terminal.screen", marks(buffer, screen.rows, term.history))
	follow(term, screen, before)
end

--- Lets the terminal go: ends its program, and shows what the main view
--- showed before in the views showing it.
function M.close(term: Term)
	terms[term.buffer:id()] = nil
	term.terminal:close()
	if shown(term) then
		if kern.mode.get() == MODE then
			kern.mode.set(core.style.home())
		end
		local view = kern.view()
		local ok = term.previous and pcall(view.show, view, term.previous)
		if not ok then
			view:show(kern.create_buffer("file", ""))
		end
	end
	term.buffer:set_kept(false)
end

--- Opens a terminal running `command` (the user's shell without) in the
--- main view, and types into it.
function M.open(command: { string }?): Term
	local view = kern.view()
	local previous = view:buffer()
	local buffer = kern.create_buffer("terminal", "")
	buffer:set_readonly(true)
	buffer:set_line_numbers(false)
	buffer:set_kept(true)
	local rows, cols = view:size()
	local limit = kern.option.get("terminal-scrollback") :: number
	local given = if command and #command > 0 then command else nil
	local terminal = kern.terminal.spawn({
		command = given,
		cwd = kern.project.current().root,
		rows = rows or 24,
		cols = cols or 80,
		scrollback = limit,
	})
	local term: Term = {
		terminal = terminal,
		buffer = buffer,
		history = 0,
		next = 0,
		limit = limit,
		chunks = {},
		chunk = 0,
		previous = previous,
		command = if given then table.concat(given, " ") else "shell",
	}
	terms[buffer:id()] = term
	view:show(buffer)
	kern.mode.set(MODE)
	return term
end

local function find(terminal: kern.Terminal): Term?
	for _, term in terms do
		if term.terminal:id() == terminal:id() then
			return term
		end
	end
	return nil
end

kern.on("terminal.output", function(event)
	local term = find(event.terminal)
	if term then
		M.update(term)
	end
end)

kern.on("terminal.exited", function(event)
	local term = find(event.terminal)
	if term == nil then
		return
	end
	M.update(term)
	if event.code == 0 then
		M.close(term)
		return
	end
	local last = term.buffer:len()
	term.buffer:decorate("terminal.exit", {
		{ from = last, to = last, style = "comment", lines = { `[exited with {event.code}]` } },
	})
	if kern.mode.get() == MODE and shown(term) then
		kern.mode.set(core.style.home())
	end
end)

kern.on("view.resized", function(event: kern.ViewResized)
	local term = term_of(event.view:buffer())
	if term and term.terminal:exit_code() == nil then
		term.terminal:resize(event.rows, event.cols)
	end
end)

kern.command({
	name = "terminal",
	doc = "Open a terminal running a command, or your shell",
	args = { { name = "command", doc = "The program and its arguments" } },
	run = function(ctx)
		M.open(ctx.args)
	end,
})

kern.command({
	name = "terminal-key",
	doc = "Send the key to the terminal's program",
	run = function(ctx)
		local term = term_of(ctx.buffer)
		if term == nil or term.terminal:exit_code() ~= nil then
			kern.mode.set(core.style.home())
			return
		end
		term.terminal:key(ctx.keys or "")
	end,
})

kern.command({
	name = "terminal-input",
	doc = "Type into the terminal's program",
	run = function(ctx)
		local term = term_of(ctx.buffer)
		if term and term.terminal:exit_code() == nil then
			kern.mode.set(MODE)
			M.update(term)
		end
	end,
})

kern.command({
	name = "terminal-leave",
	doc = "Stop typing into the terminal, to move around its output",
	run = function()
		kern.mode.set(core.style.home())
	end,
})

kern.command({
	name = "terminal-paste",
	doc = "Paste the latest copy into the terminal's program",
	run = function(ctx)
		local term = term_of(ctx.buffer)
		local copy = kern.clipboard.get()
		if term and copy then
			term.terminal:paste(table.concat(copy, "\n"))
		end
	end,
})

kern.command({
	name = "terminal-close",
	doc = "End the terminal's program and close it",
	run = function(ctx)
		local term = term_of(ctx.buffer)
		if term then
			M.close(term)
		end
	end,
})

--- Shows `term` in the main view and types into it.
function M.show(term: Term)
	if not shown(term) then
		local view = kern.view()
		term.previous = view:buffer()
		view:show(term.buffer)
	end
	if term.terminal:exit_code() == nil then
		kern.mode.set(MODE)
		M.update(term)
	end
end

kern.command({
	name = "pick-terminal",
	doc = "Switch to a terminal, or open a new one",
	run = function()
		local items: { picker.Item } = { { label = "new terminal", value = 0 } }
		local ids = {}
		for id in terms do
			table.insert(ids, id)
		end
		table.sort(ids)
		for _, id in ids do
			local term = terms[id]
			table.insert(items, { label = term.terminal:title() or term.command, value = id })
		end
		picker.pick("Terminals", items, function(item)
			local term = terms[item.value]
			if term then
				M.show(term)
			else
				M.open()
			end
		end)
	end,
})

kern.keymap.bind("normal", { ["space t"] = "pick-terminal" })
kern.keymap.isolate(MODE)
kern.keymap.fallback(MODE, "terminal-key")
kern.keymap.bind(MODE, { ["ctrl-\\"] = "terminal-leave" })
kern.mode.cursor(MODE, "block")
for _, mode in { "normal", "vim" } do
	kern.keymap.bind({ mode = mode, kind = "terminal" }, {
		i = "terminal-input",
		a = "terminal-input",
		enter = "terminal-input",
		p = "terminal-paste",
	})
end
kern.keymap.bind({ mode = "edit", kind = "terminal" }, { enter = "terminal-input" })

return M
