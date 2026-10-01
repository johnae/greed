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

kern.option.define({
	name = "terminal-shell",
	doc = 'What a new terminal runs, e.g. "fish -l"; empty for your $SHELL',
	default = "",
})

-- The terminal-shell option as a command line, or nil for $SHELL.
local function shell(): { string }?
	local words = {}
	for word in string.gmatch(kern.option.get("terminal-shell") :: string, "%S+") do
		table.insert(words, word)
	end
	return if #words > 0 then words else nil
end

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
	-- Whether its views were opened for it (a pane, a float), so they close
	-- with it.
	owns: boolean,
	-- What it runs, as typed.
	command: string,
	-- Images with a mark above the screen.
	images: { [number]: boolean },
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

-- Styles and images for `rows`, which start at line `line` of the buffer.
-- An image gets one mark, where its first row in the buffer is, reaching
-- to its last so it's drawn whenever any of it shows; `marked` holds the
-- images that have one already.
local function marks(
	buffer: kern.Buffer,
	rows: { kern.TerminalRow },
	line: number,
	marked: { [number]: boolean }
): { kern.Mark }
	local list = {}
	local last = buffer:line_count() - 1
	for i, row in rows do
		local start = buffer:line_start(line + i - 1)
		for _, span in row.spans do
			table.insert(
				list,
				{ from = start + span.from, to = start + span.to, style = span.style }
			)
		end
		for _, image in row.images do
			if not marked[image.id] then
				marked[image.id] = true
				local bottom = math.min(line + i - 1 + image.rows - image.row - 1, last)
				table.insert(list, {
					from = start + image.from,
					to = math.max(start + image.from, buffer:line_start(bottom)),
					style = "terminal.image",
					image = {
						id = image.id,
						cols = image.cols,
						rows = image.rows,
						col = image.col,
						row = image.row,
					},
				})
			end
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

-- Puts the cursor where the program's is in each view showing the
-- terminal, and keeps the screen in view: always in views without focus,
-- and in the focused one while typing into it or already at the bottom.
local function follow(term: Term, screen: kern.TerminalScreen, before: number)
	local focused = kern.view():id()
	local typing = kern.mode.get() == MODE
	local buffer = term.buffer
	for _, view in buffer:views() do
		-- Drawing scrolls to the cursor, so a view that follows has its
		-- cursor put on the screen too, unless you're reading the output.
		if view:id() ~= focused or typing then
			local pos = if screen.cursor
				then buffer:line_start(term.history + screen.cursor.row) + screen.cursor.col
				else buffer:line_start(term.history)
			view:set_selection({ ranges = { { anchor = pos, head = pos } }, primary = 1 })
			view:set_scroll(term.history)
		elseif view:scroll() >= before then
			view:set_scroll(term.history)
		end
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
		buffer:decorate(ns, marks(buffer, scrolled.rows, before, term.images))
		table.insert(term.chunks, { ns = ns, lines = #scrolled.rows })
	end
	trim(term)
	-- The screen is new each time; images above it keep their marks.
	local marked = table.clone(term.images)
	buffer:decorate("terminal.screen", marks(buffer, screen.rows, term.history, marked))
	follow(term, screen, before)
end

--- Types into the terminal `view` shows, if it shows one that's running.
function M.enter(view: kern.View)
	local term = term_of(view:buffer())
	if term and term.terminal:exit_code() == nil then
		kern.mode.set(MODE)
		M.update(term)
	end
end

--- Goes into the right mode for `view`: typing into a terminal, or out of
--- the terminal mode for anything else.
function M.settle(view: kern.View)
	if term_of(view:buffer()) then
		M.enter(view)
	elseif kern.mode.get() == MODE then
		kern.mode.set(core.style.home())
	end
end

--- Lets the terminal go: ends its program and stops showing it. Panes and
--- floats opened for it close; a view it took over shows what it showed
--- before.
function M.close(term: Term)
	terms[term.buffer:id()] = nil
	term.terminal:close()
	for _, view in term.buffer:views() do
		if not (term.owns and view:close()) then
			local ok = term.previous and pcall(view.show, view, term.previous)
			if not ok then
				view:show(kern.create_buffer("file", ""))
			end
		end
	end
	term.buffer:set_kept(false)
	M.settle(kern.view())
end

--- Ends the terminal in `buffer` if nothing shows it any more, e.g. after
--- its pane was closed.
function M.forget(buffer: kern.Buffer)
	local term = term_of(buffer)
	if term and #buffer:views() == 0 then
		M.close(term)
	end
end

local FLOAT: kern.FloatSpec = { title = "terminal", width = "80%", height = "80%" }

export type OpenOptions = {
	--- Open it in a new pane on this side of `from` (the focused view by
	--- default), rather than in the focused view.
	split: ("left" | "right" | "up" | "down")?,
	from: kern.View?,
	--- Open it floating over the panes.
	float: boolean?,
}

--- Opens a terminal running `command` (the user's shell without) and
--- types into it: in the focused view, a new pane or a float.
function M.open(command: { string }?, options: OpenOptions?): Term
	local opts: OpenOptions = options or {}
	local buffer = kern.create_buffer("terminal", "")
	buffer:set_readonly(true)
	buffer:set_line_numbers(false)
	buffer:set_kept(true)
	local view, previous
	if opts.float then
		view = kern.float(buffer, FLOAT)
	elseif opts.split then
		view = (opts.from or kern.view()):split(opts.split, buffer)
	else
		view = kern.view()
		previous = view:buffer()
		view:show(buffer)
	end
	-- A new view hasn't been drawn yet; it says its size once it is.
	local rows, cols = view:size()
	local limit = kern.option.get("terminal-scrollback") :: number
	local given = if command and #command > 0 then command else shell()
	local term: Term = {
		terminal = kern.terminal.spawn({
			command = given,
			cwd = kern.project.current().root,
			rows = rows or 24,
			cols = cols or 80,
			scrollback = limit,
		}),
		buffer = buffer,
		history = 0,
		next = 0,
		limit = limit,
		chunks = {},
		chunk = 0,
		previous = previous,
		owns = previous == nil,
		command = if given then table.concat(given, " ") else "shell",
		images = {},
	}
	terms[buffer:id()] = term
	M.enter(view)
	return term
end

-- The floating terminal of each project, by project id.
local floats: { [number]: Term } = {}

--- Shows the project's floating terminal, starting it the first time, or
--- hides it, leaving it running.
function M.toggle_float()
	local project = kern.project.current().id
	local term = floats[project]
	if term == nil or terms[term.buffer:id()] == nil then
		floats[project] = M.open(nil, { float = true })
		return
	end
	for _, view in term.buffer:views() do
		if not view:is_pane() then
			view:close()
			M.settle(kern.view())
			return
		end
	end
	M.enter(kern.float(term.buffer, FLOAT))
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
	name = "terminal-leader",
	doc = "Stop typing into the terminal and press space, for the keys after it",
	run = function()
		kern.mode.set(core.style.home())
		-- Styles without space keys (edit mode) just stop typing into it.
		if #kern.keymap.next("space") > 0 then
			kern.keys.feed("space")
		end
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
	local view = kern.view()
	if not shown(term) then
		term.previous = view:buffer()
		term.owns = false
		view:show(term.buffer)
	end
	M.enter(view)
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
kern.keymap.bind(MODE, { ["ctrl-\\"] = "terminal-leave", ["ctrl-space"] = "terminal-leader" })
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
