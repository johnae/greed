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

kern.option.define({
	name = "link-opener",
	doc = 'What opens a link, e.g. "firefox"; empty for xdg-open, or open on macOS',
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
	-- The command it was asked to run, or nil for your shell.
	asked: { string }?,
	-- Images with a mark above the screen.
	images: { [number]: boolean },
	-- Whether a full screen program is showing, as of the last update.
	alternate: boolean,
	-- Links programs printed (OSC 8): above the screen by scrollback line,
	-- counting from the first ever, and on the screen by row.
	links: { [number]: { kern.TerminalLink } },
	screen_links: { [number]: { kern.TerminalLink } },
	-- Scrollback lines trimmed from the top of the buffer.
	dropped: number,
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

--- What the terminal in `buffer` was asked to run: its command, or nil for
--- your shell (and for a buffer that isn't a terminal).
function M.asked(buffer: kern.Buffer): { string }?
	local term = term_of(buffer)
	return term and term.asked and table.clone(term.asked)
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
		for _, link in row.links do
			table.insert(
				list,
				{ from = start + link.from, to = start + link.to, style = "markup.link" }
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
	for line = term.dropped, term.dropped + extra - 1 do
		term.links[line] = nil
	end
	term.dropped += extra
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
	for i, row in scrolled.rows do
		if #row.links > 0 then
			term.links[term.dropped + before + i - 1] = row.links
		end
	end
	term.screen_links = {}
	for i, row in screen.rows do
		if #row.links > 0 then
			term.screen_links[i - 1] = row.links
		end
	end
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
	term.alternate = screen.alternate
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
		kern.mode.set(core.style.home_for(view))
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

-- A terminal whose buffer was closed (with :bc, say) ends its program.
kern.on("buffer.closed", function(event: kern.BufferClosed)
	local term = terms[event.id]
	if term then
		terms[event.id] = nil
		term.terminal:close()
	end
end)

-- Floating terminals belong to the tab they open in.
local FLOAT: kern.FloatSpec = { title = "terminal", width = "80%", height = "80%", tab = true }

export type OpenOptions = {
	--- Open it in a new pane on this side of `from` (the focused view by
	--- default), rather than in the focused view.
	split: ("left" | "right" | "up" | "down")?,
	from: kern.View?,
	--- Open it floating over the panes, placed as this spec says if given.
	float: (boolean | kern.FloatSpec)?,
}

--- Environment variables every new terminal gets, on top of the editor's.
--- Plugins add to it, e.g. the agent plugin tells Claude Code where to
--- find Kern.
M.env = {} :: { [string]: string }

--- Opens a terminal running `command` (the user's shell without) and
--- types into it: in the focused view, a new pane or a float.
function M.open(command: { string }?, options: OpenOptions?): Term
	local opts: OpenOptions = options or {}
	local buffer = kern.create_buffer("terminal", "")
	buffer:set_readonly(true)
	buffer:set_line_numbers(false)
	local view, previous
	if opts.float then
		local spec = table.clone(FLOAT)
		if type(opts.float) == "table" then
			for key, value in opts.float :: { [string]: any } do
				(spec :: any)[key] = value
			end
		end
		view = kern.float(buffer, spec)
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
	-- Programs in it can tell which session they're in: `kern FILE` opens
	-- the file here instead of starting another editor inside this one,
	-- and `kern ctl` talks to this session.
	local env = table.clone(M.env)
	local session = kern.session.current()
	if session then
		env.KERN_TERMINAL = session
		env.KERN_SESSION = session
	end
	local spawned, started = pcall(function()
		return kern.terminal.spawn({
			command = given,
			cwd = kern.project.current().root,
			env = env,
			rows = rows or 24,
			cols = cols or 80,
			scrollback = limit,
		})
	end)
	if not spawned then
		-- Leave things as they were.
		if previous then
			view:show(previous)
		else
			view:close()
		end
		error(started, 2)
	end
	-- It keeps running while nothing shows it.
	buffer:set_kept(true)
	local term: Term = {
		terminal = started,
		buffer = buffer,
		history = 0,
		next = 0,
		limit = limit,
		chunks = {},
		chunk = 0,
		previous = previous,
		owns = previous == nil,
		command = if given then table.concat(given, " ") else "shell",
		asked = if command and #command > 0 then table.clone(command) else nil,
		images = {},
		alternate = false,
		links = {},
		screen_links = {},
		dropped = 0,
	}
	terms[buffer:id()] = term
	M.enter(view)
	return term
end

-- The floating terminal alt-f shows in each tab, by tab id.
local floats: { [number]: Term } = {}

--- Shows the tab's floating terminal, starting it the first time, or hides
--- it, leaving it running.
function M.toggle_float()
	local tab = kern.tab.current().id
	local term = floats[tab]
	if term == nil or terms[term.buffer:id()] == nil then
		floats[tab] = M.open(nil, { float = true })
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

-- A client that asked for a terminal (`kern --terminal`, `kern ssh HOST
-- --terminal`) gets one, in a tab of its own.
kern.on("client.attached", function(event: kern.ClientAttached)
	if event.terminal then
		kern.tab.new()
		M.open()
	end
end)

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

-- Two escs this close together (ms) leave the terminal.
local DOUBLE_ESC = 300

-- When esc last went to a program.
local last_esc = -math.huge

-- Sends `key` to the program in the buffer's terminal; once it has exited,
-- stops typing into it instead.
local function send(ctx: kern.Context, key: string)
	local term = term_of(ctx.buffer)
	if term == nil or term.terminal:exit_code() ~= nil then
		kern.mode.set(core.style.home())
		return
	end
	term.terminal:key(key)
end

kern.command({
	name = "terminal-key",
	doc = "Send the key to the terminal's program",
	run = function(ctx)
		-- Escs only count as double with nothing between them.
		last_esc = -math.huge
		send(ctx, ctx.keys or "")
	end,
})

kern.command({
	name = "terminal-esc",
	doc = "Send esc to the terminal's program; a second one quickly after stops typing into it",
	run = function(ctx)
		local now = kern.now()
		if now - last_esc <= DOUBLE_ESC then
			last_esc = -math.huge
			kern.run("terminal-leave")
			return
		end
		last_esc = now
		send(ctx, "esc")
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

-- A URL written out in text, for links programs didn't mark.
local URL = [=[(https?|ftp|file)://[^\s<>"'`]*[^\s<>"'`.,;:!?)\]}]]=]

--- Where the link at `pos` in `buffer` goes: one a terminal's program
--- printed, or a URL written there.
function M.link_at(buffer: kern.Buffer, pos: number): string?
	local line = buffer:line_of(pos)
	local start = buffer:line_start(line)
	local term = term_of(buffer)
	if term then
		local links = if line < term.history
			then term.links[term.dropped + line]
			else term.screen_links[line - term.history]
		for _, link in links or {} do
			if pos >= start + link.from and pos < start + link.to then
				return link.uri
			end
		end
	end
	for _, found in buffer:find_all(URL, start, buffer:line_end(line)) or {} do
		if pos >= found.from and pos < found.to then
			return buffer:slice(found.from, found.to)
		end
	end
	return nil
end

--- Opens `uri` with the link-opener option, or the system's opener.
function M.open_link(uri: string)
	local given = kern.option.get("link-opener") :: string
	local done, err
	if given ~= "" then
		local command = string.split(given, " ")
		table.insert(command, uri)
		done, err = kern.process.run(command)
	else
		done, err = kern.process.run({ "xdg-open", uri })
		if done == nil then
			done, err = kern.process.run({ "open", uri })
		end
	end
	if done == nil then
		kern.echo(`can't open {uri}: {err}`)
	elseif done.code ~= 0 then
		kern.echo(`can't open {uri}: {done.stderr}`)
	end
end

kern.command({
	name = "open-link",
	doc = "Open the link under the cursor",
	run = function(ctx)
		local selection = ctx.view:selection()
		local uri = M.link_at(ctx.buffer, selection.ranges[selection.primary].head)
		if uri then
			M.open_link(uri)
		else
			kern.echo("no link here")
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

-- The mouse in a terminal. A program that asked for it gets it. Otherwise
-- the wheel scrolls back through the output, as tmux does: up stops typing
-- into the program, and back at the bottom types into it again. In a full
-- screen program the wheel sends arrow keys instead, as xterm does. A
-- click types into the program, and a drag selects output to copy.
local dragged = false
local held: number? = nil

local function on_mouse(event: kern.MouseEvent): boolean
	local view = assert(event.view)
	local term = term_of(view:buffer())
	if term == nil then
		return false
	end
	local running = term.terminal:exit_code() == nil
	local row = view:scroll() + (event.y or 0) - term.history
	if running and row >= 0 and term.terminal:wants_mouse() then
		if event.kind == "press" then
			view:focus()
			M.enter(view)
		end
		term.terminal:mouse(event.kind, event.x or 0, row, event.button or event.dir, {
			ctrl = event.ctrl,
			alt = event.alt,
			shift = event.shift,
		})
		return true
	end
	if event.kind == "scroll" then
		local up = event.dir == "up"
		if running and term.alternate then
			for _ = 1, core.mouse.lines do
				term.terminal:key(if up then "up" else "down")
			end
			return true
		end
		view:focus()
		if up and kern.mode.get() == MODE then
			kern.mode.set(core.style.home())
		end
		core.mouse.scroll(view, if up then -core.mouse.lines else core.mouse.lines)
		if not up and running and view:scroll() >= term.history then
			M.enter(view)
		end
		return true
	end
	if event.kind == "press" and event.button == "left" and event.ctrl and event.pos then
		local uri = M.link_at(view:buffer(), event.pos)
		if uri then
			M.open_link(uri)
			return true
		end
	end
	if event.kind == "press" and event.button == "left" then
		view:focus()
		kern.mode.set(core.style.home())
		dragged, held = false, event.pos
		if event.pos then
			view:set_selection({
				ranges = { { anchor = event.pos, head = event.pos } },
				primary = 1,
			})
		end
	elseif event.kind == "drag" and held and event.pos then
		dragged = true
		view:set_selection({ ranges = { { anchor = held, head = event.pos } }, primary = 1 })
	elseif event.kind == "release" then
		if not dragged and held and running then
			M.enter(view)
		end
		held = nil
	end
	return true
end

core.mouse.claim("terminal", on_mouse)

-- Clicking away from a terminal stops typing into it.
kern.on("mouse", function(event: kern.MouseEvent)
	local view = event.view
	if
		event.kind == "press"
		and view
		and not term_of(view:buffer())
		and kern.mode.get() == MODE
	then
		kern.mode.set(core.style.home())
	end
end)

kern.keymap.isolate(MODE)
kern.keymap.fallback(MODE, "terminal-key")
kern.keymap.bind(MODE, {
	["ctrl-\\"] = "terminal-leave",
	["ctrl-space"] = "terminal-leader",
	esc = "terminal-esc",
})
kern.mode.cursor(MODE, "block")
for _, mode in { "normal", "vim" } do
	kern.keymap.bind({ mode = mode, kind = "terminal" }, {
		i = "terminal-input",
		a = "terminal-input",
		enter = "terminal-input",
		p = "terminal-paste",
		["g x"] = "open-link",
	})
end
kern.keymap.bind({ mode = "edit", kind = "terminal" }, { enter = "terminal-input" })

return M
