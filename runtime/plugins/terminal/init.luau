-- Terminals: a shell, or any program, in a buffer. `:terminal [command]`
-- opens one in the main view and sends it every key; ctrl-\ goes back to
-- the editing style's mode, where the output is text to select, search
-- and copy, and i or enter types into the program again.
--
-- The buffer holds the lines that scrolled off the top, then the screen.
-- Output replaces the screen part and adds what scrolled off above it.

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")

greed.option.define({
	name = "terminal-scrollback",
	doc = "How many lines that scrolled off a terminal's screen are kept",
	default = 10000,
})

greed.option.define({
	name = "terminal-shell",
	needs = "proc",
	doc = 'What a new terminal runs, e.g. "fish -l"; empty for your $SHELL',
	default = "",
})

-- The terminal-shell option as a command line, or nil for $SHELL.
local function shell(): { string }?
	local words = {}
	for word in string.gmatch(greed.option.get("terminal-shell") :: string, "%S+") do
		table.insert(words, word)
	end
	return if #words > 0 then words else nil
end

local MODE = "terminal"

export type Term = {
	terminal: greed.Terminal,
	buffer: greed.Buffer,
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
	previous: greed.Buffer?,
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
	links: { [number]: { greed.TerminalLink } },
	screen_links: { [number]: { greed.TerminalLink } },
	-- Scrollback lines trimmed from the top of the buffer.
	dropped: number,
	-- How many marks the shell had made when `failures` was worked out, and
	-- the commands that failed: where each starts, and its exit code.
	marks_made: number,
	failures: { { mark: greed.TerminalMark, code: number } },
	-- Whether it stays open when its program ends well, to read the output.
	keep: boolean,
	-- Whether an update is under way, and whether more came in meanwhile.
	updating: boolean,
	stale: boolean,
	-- The client whose screen it's sized for: the one that last typed into
	-- it or focused it. A program has one screen size, so the others see it
	-- cropped or scaled.
	client: number?,
	-- The size its screen was given for that client, and the note the
	-- others see on it.
	screen_size: { rows: number, cols: number, note: string }?,
	-- Whether another plugin started its program and handed it over
	-- (`adopt`): closing it ends the program, but the terminal stays that
	-- plugin's to read and close.
	adopted: boolean,
	-- Whether it gives its views back once the program leaves the alternate
	-- screen or exits, and whether that's due.
	return_on_primary: boolean,
	giving_back: boolean,
	-- The agent running in it, as its hooks last said (`agent_state`).
	agent: { name: string, state: AgentState, since: number }?,
}

local M = {}

-- Terminals by the id of their buffer.
local terms: { [number]: Term } = {}

-- Says how every view lays `term`'s screen out: at the size it was given,
-- with the row of the program's `cursor` kept in sight where a view crops
-- it.
local function publish_size(term: Term, cursor: { row: number, col: number }?)
	local size = term.screen_size
	if size == nil then
		return
	end
	term.buffer:set_screen_size({
		rows = size.rows,
		cols = size.cols,
		note = size.note,
		cursor_row = cursor and cursor.row,
	})
end

-- Sizes `term`'s screen at `rows` by `cols`, for the acting client, whose
-- screen it follows from now on: the program's, and how every view lays
-- it out.
local function size_for_client(term: Term, rows: number, cols: number)
	term.client = greed.client.id()
	local running = term.terminal:exit_code() == nil
	if running then
		term.terminal:resize(rows, cols)
	end
	local name = greed.client.current().name
	term.screen_size = { rows = rows, cols = cols, note = ` {cols}×{rows} for {name} ` }
	publish_size(term, if running then term.terminal:screen().cursor else nil)
end

-- Has `term` follow the acting client's screen, as its `view` of it has
-- room, unless it does already or the view hasn't been drawn yet.
local function claim(term: Term, view: greed.View)
	if term.client == greed.client.id() then
		return
	end
	local rows, cols = view:size()
	if rows and cols then
		size_for_client(term, rows, cols)
	end
end

-- The terminal last typed into, where text sent from files goes.
local last_used: Term? = nil

-- Names `term`'s buffer after what it runs and the folder its shell is in,
-- like "nu ~/src" or "cargo test ~/src", for its float's border, the tab
-- line, the dock and the status line; an adopted one by the title it was
-- given. Called as output comes, since the folder changes.
local function name(term: Term)
	local what = if term.adopted or term.asked then term.command else term.terminal:program()
	local cwd = if not term.adopted and term.terminal:valid() then term.terminal:cwd() else nil
	local wanted = if cwd then `{what} {core.project.tilde(cwd)}` else what
	if term.buffer:valid() and term.buffer:name() ~= wanted then
		term.buffer:set_name(wanted)
	end
end

local function term_of(buffer: greed.Buffer): Term?
	return terms[buffer:id()]
end

--- Whether `term` is still open.
function M.is_open(term: Term): boolean
	return terms[term.buffer:id()] == term
end

local function shown(term: Term): boolean
	return greed.view():buffer() == term.buffer
end

-- Whether the terminal shows only in hidden floats, out of sight.
local function out_of_sight(term: Term): boolean
	local views = term.buffer:views()
	for _, view in views do
		local spec = view:float_spec()
		if not (spec and spec.hidden) then
			return false
		end
	end
	return #views > 0
end

-- Says the terminal showing in `buffer` needs a look and why, or with nil
-- that it no longer does.
local function needs_look(buffer: greed.Buffer, reason: string?)
	local key = `terminal:{buffer:id()}`
	if reason == nil then
		core.attention.set(key, nil)
		return
	end
	local term = term_of(buffer)
	local label = (if term then term.terminal:title() or term.command else buffer:name())
		or "a terminal"
	core.attention.set(key, { label = label, reason = reason, buffer = buffer })
end

--- How an agent running in a terminal says it's doing.
export type AgentState = "working" | "waiting" | "idle"

--- Says the agent `name` (like "claude") in the terminal shown in `buffer`
--- is working, waiting for you or idle, as its hooks tell; nil says it's
--- gone. One waiting needs you until it says otherwise. False when
--- `buffer` isn't a terminal.
function M.agent_state(buffer: greed.Buffer, name: string, state: AgentState?): boolean
	local term = term_of(buffer)
	if term == nil then
		return false
	end
	local had = term.agent
	term.agent = if state
		then {
			name = name,
			state = state,
			since = if had and had.state == state then had.since else os.time(),
		}
		else nil
	needs_look(buffer, if state == "waiting" then `{name} waits for your answer` else nil)
	return true
end

--- The terminal shown in `buffer`, if it's one.
function M.terminal(buffer: greed.Buffer): greed.Terminal?
	local term = term_of(buffer)
	return term and term.terminal
end

--- The folder the shell in `buffer`'s terminal is in, as it last said
--- (OSC 7), or the one it started in; nil for a buffer that isn't a
--- terminal.
function M.cwd(buffer: greed.Buffer): string?
	local term = term_of(buffer)
	return term and term.terminal:cwd()
end

--- What the terminal in `buffer` was asked to run: its command, or nil for
--- your shell (and for a buffer that isn't a terminal).
function M.asked(buffer: greed.Buffer): { string }?
	local term = term_of(buffer)
	return term and term.asked and table.clone(term.asked)
end

--- Styles, links and images for terminal `rows` shown in `buffer` from
--- line `line` on, as marks to decorate it with. An image gets one mark,
--- where its first row in the buffer is, reaching to its last so it's drawn
--- whenever any of it shows; `marked` holds the images that have one
--- already, and gains the new ones.
function M.row_marks(
	buffer: greed.Buffer,
	rows: { greed.TerminalRow },
	line: number,
	marked: { [number]: boolean }
): { greed.Mark }
	local list: { greed.Mark } = {}
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
local function follow(term: Term, screen: greed.TerminalScreen, before: number)
	local focused = greed.view():id()
	local typing = greed.mode.get() == MODE
	local buffer = term.buffer
	for _, view in buffer:views() do
		-- Drawing scrolls to the cursor, so a view that follows has its
		-- cursor put on the screen too, unless you're reading the output.
		if view:id() ~= focused or typing then
			local pos = if screen.cursor
				then buffer:line_start(term.history + screen.cursor.row) + screen.cursor.col
				else buffer:line_start(term.history)
			view:set_cursor(pos)
			view:set_scroll(term.history)
		elseif view:scroll() >= before then
			view:set_scroll(term.history)
		end
	end
end

--- A command run in a terminal's shell, from the marks the shell made
--- (OSC 133): where its prompt, the command and its output start and
--- where it ended, as byte positions in the buffer, and its exit code.
--- Parts the shell didn't mark, or that are above what the buffer holds,
--- are nil.
export type Command = {
	prompt: number?,
	command: number?,
	output: number?,
	done: number?,
	code: number?,
}

-- Where `mark` is in the buffer, or nil above what it holds.
local function mark_position(term: Term, mark: greed.TerminalMark): number?
	local buffer = term.buffer
	local line = mark.line - term.next + term.history
	if line < 0 or line >= buffer:line_count() then
		return nil
	end
	return math.min(buffer:line_start(line) + mark.col, buffer:line_end(line))
end

local function commands_of(term: Term): { Command }
	local list: { Command } = {}
	local current: Command? = nil
	for _, mark in term.terminal:marks(term.next - term.history) do
		local at = mark_position(term, mark)
		if mark.kind == "prompt" or current == nil then
			current = {}
			table.insert(list, current :: Command)
		end
		local c = current :: Command
		if mark.kind == "prompt" then
			c.prompt = at
		elseif mark.kind == "command" then
			c.command = at
		elseif mark.kind == "output" then
			c.output = at
		else
			c.done = at
			c.code = mark.code
		end
	end
	return list
end

--- The commands run in the terminal shown in `buffer`, oldest first, as
--- far back as the buffer goes. Empty for a shell that doesn't mark its
--- prompts.
function M.commands(buffer: greed.Buffer): { Command }
	local term = term_of(buffer)
	return if term then commands_of(term) else {}
end

-- Where the command `c` starts, for moving to it.
local function start_of(c: Command): number?
	return c.command or c.prompt
end

-- Shows the exit code by each command that failed.
-- Which commands failed is worked out again only when the shell made new
-- marks; output replaces the screen's text, so the marks showing them are
-- placed on every update.
local function mark_failures(term: Term)
	local made = term.terminal:marks_made()
	if made ~= term.marks_made then
		local fresh = made - term.marks_made
		term.marks_made = made
		local failures = {}
		local start: greed.TerminalMark? = nil
		local finished = false
		local marks = term.terminal:marks(term.next - term.history)
		for i, mark in marks do
			if mark.kind == "prompt" or mark.kind == "command" then
				start = mark
			elseif mark.kind == "done" and start and mark.code and mark.code ~= 0 then
				table.insert(failures, { mark = start, code = mark.code })
			end
			finished = finished or (mark.kind == "done" and i > #marks - fresh)
		end
		term.failures = failures
		-- A command that finished in a hidden float wants a look.
		if finished and out_of_sight(term) then
			needs_look(term.buffer, "a command finished")
		end
	end
	local marks: { greed.Mark } = {}
	for _, failure in term.failures do
		local at = mark_position(term, failure.mark)
		if at then
			table.insert(marks, {
				from = at,
				to = at,
				style = "diagnostic.message.error",
				text = `exit {failure.code}`,
				eol = true,
			})
		end
	end
	term.buffer:decorate("terminal.exits", marks)
end

local function show(term: Term)
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
		buffer:decorate(ns, M.row_marks(buffer, scrolled.rows, before, term.images))
		table.insert(term.chunks, { ns = ns, lines = #scrolled.rows })
	end
	trim(term)
	-- The screen is new each time; images above it keep their marks.
	local marked = table.clone(term.images)
	buffer:decorate("terminal.screen", M.row_marks(buffer, screen.rows, term.history, marked))
	if term.return_on_primary and term.alternate and not screen.alternate then
		term.giving_back = true
	end
	term.alternate = screen.alternate
	mark_failures(term)
	follow(term, screen, before)
	publish_size(term, screen.cursor)
end

-- Stops showing `term`: panes and floats opened for it close, and a view
-- it took over shows what it showed before. Its program is left as it is.
local function release(term: Term)
	terms[term.buffer:id()] = nil
	if last_used == term then
		last_used = nil
	end
	for _, view in term.buffer:views() do
		if not (term.owns and view:close()) then
			local previous = term.previous
			if previous and previous:valid() then
				view:show(previous)
			else
				view:show(greed.create_buffer("file", ""))
			end
		end
	end
	term.buffer:set_kept(false)
	M.settle(greed.view())
end

-- Ends `term`'s program. A terminal another plugin handed over stays that
-- plugin's to read and close.
local function stop(term: Term)
	if not term.adopted then
		term.terminal:close()
	elseif term.terminal:valid() and term.terminal:exit_code() == nil then
		term.terminal:kill()
	end
end

--- Shows the terminal's latest output in its buffer.
function M.update(term: Term)
	-- An update's time slice can run out partway, and another start on the
	-- half-updated buffer meanwhile; that one leaves it to the first.
	if term.updating then
		term.stale = true
		return
	end
	term.updating = true
	name(term)
	local ok, err = pcall(function()
		repeat
			term.stale = false
			show(term)
		until not term.stale
	end)
	term.updating = false
	if not ok then
		error(err, 0)
	end
	if term.giving_back and M.is_open(term) then
		release(term)
	end
end

--- Types into the terminal `view` shows, if it shows one that's running.
function M.enter(view: greed.View)
	local term = term_of(view:buffer())
	if term and term.terminal:exit_code() == nil then
		last_used = term
		greed.mode.set(MODE)
		M.update(term)
	end
end

--- Goes into the right mode for `view`: typing into a terminal, or out of
--- the terminal mode for anything else.
function M.settle(view: greed.View)
	if term_of(view:buffer()) then
		M.enter(view)
	elseif greed.mode.get() == MODE then
		greed.mode.set(core.style.home_for(view))
	end
end

--- Lets the terminal go: ends its program and stops showing it. Panes and
--- floats opened for it close; a view it took over shows what it showed
--- before.
function M.close(term: Term)
	stop(term)
	release(term)
end

--- Ends the terminal in `buffer` if nothing shows it any more, e.g. after
--- its pane was closed.
function M.forget(buffer: greed.Buffer)
	local term = term_of(buffer)
	if term and #buffer:views() == 0 then
		M.close(term)
	end
end

-- A terminal whose buffer was closed (with :bc, say) ends its program.
greed.on("buffer.closed", function(event: greed.BufferClosed)
	local term = terms[event.id]
	if term then
		terms[event.id] = nil
		stop(term)
	end
end)

-- Floating terminals belong to the tab they open in.
-- Without a title of their own, their buffers' names show on the border.
local FLOAT: greed.FloatSpec = { width = "80%", height = "80%", tab = true }

export type OpenOptions = {
	--- Open it in a new pane on this side of `from` (the focused view by
	--- default), rather than in the focused view.
	split: ("left" | "right" | "up" | "down")?,
	from: greed.View?,
	--- Open it floating over the panes, placed as this spec says if given.
	float: (boolean | greed.FloatSpec)?,
	--- Keep it open when its program ends well, as for a task whose output
	--- you want to read; otherwise only a failure keeps it.
	keep: boolean?,
	--- The folder to start in, instead of the focused terminal's or the
	--- project's.
	cwd: string?,
	--- Environment variables for its program on top of every terminal's,
	--- like the shell a command came from has (`KUBECONFIG`, `PATH`);
	--- `false` leaves one out.
	env: { [string]: string | false }?,
}

--- Environment variables every new terminal gets, on top of the editor's;
--- set with `set_env`.
M.env = {} :: { [string]: string }

--- Gives every new terminal the environment variable `name`, e.g. the
--- agent plugin tells Claude Code where to find Greed. It goes when the
--- plugin (or config) that set it does.
function M.set_env(name: string, value: string)
	greed.plugin.tie(core.registry.set(M.env, name, value))
end

-- A new buffer to show a terminal in.
local function new_buffer(): greed.Buffer
	local buffer = greed.create_buffer("terminal", "")
	buffer:set_readonly(true)
	buffer:set_line_numbers(false)
	-- Every bit of output replaces the screen; keeping each one to undo
	-- would grow without end in a long-running terminal.
	buffer:forget_history()
	core.file.scratch(buffer)
	return buffer
end

-- Starts showing `terminal` in `buffer`, which keeps it running while
-- nothing shows it.
local function track(
	terminal: greed.Terminal,
	buffer: greed.Buffer,
	how: {
		previous: greed.Buffer?,
		owns: boolean,
		command: string,
		asked: { string }?,
		keep: boolean,
		client: number?,
		adopted: boolean,
		return_on_primary: boolean,
	}
): Term
	buffer:set_kept(true)
	local term: Term = {
		terminal = terminal,
		buffer = buffer,
		history = 0,
		next = 0,
		limit = greed.option.get("terminal-scrollback") :: number,
		chunks = {},
		chunk = 0,
		previous = how.previous,
		owns = how.owns,
		command = how.command,
		asked = how.asked,
		images = {},
		alternate = false,
		links = {},
		screen_links = {},
		dropped = 0,
		marks_made = 0,
		failures = {},
		keep = how.keep,
		updating = false,
		stale = false,
		client = how.client,
		adopted = how.adopted,
		return_on_primary = how.return_on_primary,
		giving_back = false,
	}
	terms[buffer:id()] = term
	name(term)
	return term
end

--- Opens a terminal running `command` (the user's shell without) and
--- types into it: in the focused view, a new pane or a float.
function M.open(command: { string }?, options: OpenOptions?): Term
	local opts: OpenOptions = options or {}
	-- Opened from a terminal, it starts in the folder that one's shell is in.
	local here = M.cwd(greed.view():buffer())
	local buffer = new_buffer()
	local view, previous
	if opts.float then
		local spec = table.clone(FLOAT)
		if type(opts.float) == "table" then
			for key, value in opts.float :: { [string]: any } do
				(spec :: any)[key] = value
			end
		end
		view = greed.float(buffer, spec)
	elseif opts.split then
		view = (opts.from or greed.view()):split(opts.split, buffer)
	else
		view = greed.view()
		previous = view:buffer()
		view:show(buffer)
	end
	-- A new view hasn't been drawn yet; it says its size once it is.
	local rows, cols = view:size()
	local given = if command and #command > 0 then command else shell()
	-- Programs in it can tell which session they're in: `greed FILE` opens
	-- the file here instead of starting another editor inside this one,
	-- and `greed ctl` talks to this session.
	local env: { [string]: string | false } = {}
	for name, value in M.env do
		env[name] = value
	end
	if opts.env then
		for name, value in opts.env do
			env[name] = value :: string | false
		end
	end
	local session = greed.session.current()
	if session then
		env.GREED_TERMINAL = session
		env.GREED_SESSION = session
		-- Which terminal, and the greed to reach it with, for an agent's
		-- hooks saying how it's doing (`greed ctl agent_hook`), on a machine
		-- where greed isn't on the PATH too.
		env.GREED_TERMINAL_ID = tostring(buffer:id())
		env.GREED_BIN = greed.session.program() or false
	end
	local spawned, started = pcall(function()
		return greed.terminal.spawn({
			command = given,
			cwd = opts.cwd or here or greed.project.current().root,
			env = env,
			rows = rows or 24,
			cols = cols or 80,
			scrollback = greed.option.get("terminal-scrollback") :: number,
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
	local term = track(started, buffer, {
		previous = previous,
		owns = previous == nil,
		command = if given then table.concat(given, " ") else "shell",
		asked = if command and #command > 0 then table.clone(command) else nil,
		keep = opts.keep == true,
		client = greed.client.id(),
		adopted = false,
		return_on_primary = false,
	})
	M.enter(view)
	return term
end

export type AdoptOptions = {
	--- The view to show it in; the focused one by default.
	view: greed.View?,
	--- What the view shows again when the terminal closes or gives it
	--- back; by default what it showed before.
	previous: greed.Buffer?,
	--- Keep it open when its program ends well, to read the output.
	keep: boolean?,
	--- Give the view back to `previous` once the program leaves the
	--- alternate screen (a full screen program is done) or exits. The
	--- program goes on, for the plugin that started it.
	return_on_primary: boolean?,
	--- What to call it, e.g. in the terminal picker.
	title: string?,
}

--- Shows `terminal`, which another plugin started with
--- `greed.terminal.spawn`, in a view as if opened here, sized for the
--- client's screen, and types into it when that view is focused. Closing
--- it ends the program, but the terminal stays the starting plugin's: it
--- still reads it and closes it.
function M.adopt(terminal: greed.Terminal, options: AdoptOptions?): Term
	local opts: AdoptOptions = options or {}
	local view = opts.view or greed.view()
	local previous = opts.previous or view:buffer()
	local buffer = new_buffer()
	view:show(buffer)
	local term = track(terminal, buffer, {
		previous = previous,
		owns = false,
		command = opts.title or "program",
		asked = nil,
		keep = opts.keep == true,
		client = nil,
		adopted = true,
		return_on_primary = opts.return_on_primary == true,
	})
	-- Sized for the client's screen; a view not drawn yet says its size
	-- once it is.
	local rows, cols = view:size()
	if rows and cols then
		size_for_client(term, rows, cols)
	end
	if view == greed.view() and terminal:exit_code() == nil then
		M.enter(view)
	else
		M.update(term)
	end
	-- Its end may have come and gone before it was handed over.
	if term.return_on_primary and terminal:exit_code() ~= nil and M.is_open(term) then
		release(term)
	end
	return term
end

-- The floating terminal alt-f shows in each tab, by tab id, and where it
-- was when hidden, so it comes back as moved or resized.
local floats: { [number]: Term } = {}
local float_specs: { [number]: greed.FloatSpec } = {}

--- Shows the tab's floating terminal, starting it the first time, or hides
--- it, leaving it running.
function M.toggle_float()
	local tab = greed.tab.current().id
	local term = floats[tab]
	if term == nil or terms[term.buffer:id()] == nil then
		floats[tab] = M.open(nil, { float = true })
		float_specs[tab] = nil
		return
	end
	for _, view in term.buffer:views() do
		local spec = view:float_spec()
		if spec then
			float_specs[tab] = spec
			view:close()
			M.settle(greed.view())
			return
		end
	end
	M.enter(greed.float(term.buffer, float_specs[tab] or FLOAT))
end

local function find(terminal: greed.Terminal): Term?
	for _, term in terms do
		if term.terminal == terminal then
			return term
		end
	end
	return nil
end

-- A client that asked for a terminal (`greed --terminal`, `greed ssh HOST
-- --terminal`) gets one, in a tab of its own.
greed.on("client.attached", function(event: greed.ClientAttached)
	if event.terminal then
		greed.tab.new()
		M.open()
	end
end)

greed.on("terminal.output", function(event)
	local term = find(event.terminal)
	if term then
		M.update(term)
	end
end)

greed.on("terminal.exited", function(event)
	local term = find(event.terminal)
	if term == nil then
		return
	end
	M.update(term)
	if term.return_on_primary then
		if M.is_open(term) then
			release(term)
		end
		return
	end
	if event.code == 0 and not term.keep then
		M.close(term)
		return
	end
	local last = term.buffer:len()
	local said = if event.code == 0 then "[done]" else `[exited with {event.code}]`
	term.buffer:decorate("terminal.exit", {
		{ from = last, to = last, style = "comment", lines = { said } },
	})
	if greed.mode.get() == MODE and shown(term) then
		greed.mode.set(core.style.home())
	end
	if out_of_sight(term) then
		needs_look(term.buffer, "its program ended")
	end
end)

-- Keys meant for a program never go on to anything else: out of the
-- terminal's mode when the focused `view` shows something other than a
-- terminal, as when another client closed the terminal or moved this one.
local function leave_unless_terminal(view: greed.View)
	if
		greed.mode.get() == MODE
		and view:valid()
		and view == greed.view()
		and term_of(view:buffer()) == nil
	then
		greed.mode.set(core.style.home_for(view))
	end
end

-- A terminal you look at again no longer needs you, and is sized for your
-- screen from then on.
greed.on("view.focused", function(event: greed.ViewFocused)
	local term = if event.view:valid() then term_of(event.view:buffer()) else nil
	if term then
		needs_look(event.view:buffer(), nil)
		claim(term, event.view)
	else
		leave_unless_terminal(event.view)
	end
end)

greed.on("selection.changed", function(event: greed.SelectionChanged)
	leave_unless_terminal(event.view)
end)

-- Only the screen of the client a terminal is sized for resizes it: the
-- others' views of it changing size would only fight over it.
greed.on("view.resized", function(event: greed.ViewResized)
	local term = term_of(event.view:buffer())
	if term and (term.client == nil or term.client == event.client) then
		size_for_client(term, event.rows, event.cols)
	end
end)

-- A client that went no longer holds its terminals' size; the next to
-- type into one or focus it does.
greed.on("client.detached", function(event: greed.ClientDetached)
	for _, term in terms do
		if term.client == event.client then
			term.client = nil
		end
	end
end)

greed.command({
	name = "terminal",
	doc = "Open a terminal running a command, or your shell",
	args = { { name = "command", doc = "The program and its arguments" } },
	run = function(ctx)
		M.open(ctx.args)
	end,
})

greed.option.define({
	name = "terminal-esc-wait",
	doc = "Hold esc a moment in terminals whose program draws on the normal screen, like Claude "
		.. "Code, so esc esc stops typing into it without the program getting an esc",
	default = true,
})

-- Two escs this close together (ms) leave the terminal.
local DOUBLE_ESC = 300

-- When esc last went to a program.
local last_esc = -math.huge

-- An esc held back to see if another follows: it goes to `term` once
-- DOUBLE_ESC is up, unless another key comes first.
local held_esc: { term: Term, view: greed.View }? = nil

-- Sends `key` to `term`'s program; once it has exited, stops typing into it
-- instead.
local function send_to(term: Term?, view: greed.View, key: string)
	if term == nil or term.terminal:exit_code() ~= nil then
		greed.mode.set(core.style.home())
		return
	end
	-- Typing into it sizes it for the screen you type on.
	claim(term, view)
	term.terminal:key(key)
end

-- Sends a held esc now, before what comes after it.
local function flush_held()
	local esc = held_esc
	held_esc = nil
	if esc then
		send_to(esc.term, esc.view, "esc")
	end
end

local function send(ctx: greed.Context, key: string)
	flush_held()
	send_to(term_of(ctx.buffer), ctx.view, key)
end

greed.command({
	name = "terminal-key",
	doc = "Send the key to the terminal's program",
	run = function(ctx)
		-- Escs only count as double with nothing between them.
		last_esc = -math.huge
		send(ctx, ctx.keys or "")
	end,
})

greed.command({
	name = "terminal-esc",
	doc = "Send esc to the terminal's program; a second one quickly after stops typing into it",
	run = function(ctx)
		local now = greed.now()
		if now - last_esc <= DOUBLE_ESC then
			last_esc = -math.huge
			-- The first never reached the program, if it was held.
			held_esc = nil
			greed.run("terminal-leave")
			return
		end
		last_esc = now
		local term = term_of(ctx.buffer)
		-- Full screen programs (editors, pagers) get esc at once; for one
		-- on the normal screen, like Claude Code, esc may mean "stop".
		if
			term
			and greed.option.get("terminal-esc-wait") == true
			and not term.terminal:modes().alternate
		then
			flush_held()
			local esc = { term = term, view = ctx.view }
			held_esc = esc
			greed.spawn(function()
				greed.sleep(DOUBLE_ESC)
				if held_esc == esc then
					flush_held()
				end
			end)
			return
		end
		send(ctx, "esc")
	end,
})

greed.command({
	name = "terminal-input",
	doc = "Type into the terminal's program",
	run = function(ctx)
		local term = term_of(ctx.buffer)
		if term and term.terminal:exit_code() == nil then
			claim(term, ctx.view)
			greed.mode.set(MODE)
			M.update(term)
		end
	end,
})

greed.command({
	name = "terminal-leave",
	doc = "Stop typing into the terminal, to move around its output",
	run = function()
		greed.mode.set(core.style.home())
	end,
})

greed.command({
	name = "terminal-leader",
	doc = "Stop typing into the terminal and open the leader, for the keys after it",
	run = function()
		greed.mode.set(core.style.home())
		-- A style without a leader just stops typing into it.
		local leader = core.style.current().leader
		if leader then
			greed.keys.feed(leader)
		end
	end,
})

-- Text pasted into the client goes to the program in the terminal pane
-- you're in, marked as a paste if it asked for that.
greed.on("client.paste", function(event: greed.ClientPaste)
	local view = greed.view()
	local term = term_of(view:buffer())
	if term then
		claim(term, view)
		term.terminal:paste(event.text)
	end
end)

greed.command({
	name = "terminal-paste",
	doc = "Paste the latest copy into the terminal's program",
	run = function(ctx)
		local term = term_of(ctx.buffer)
		local copy = greed.clipboard.get()
		if term and copy then
			term.terminal:paste(table.concat(copy, "\n"))
		end
	end,
})

greed.command({
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

-- A path, maybe with a line and column after it, as compilers and grep
-- print them: `src/main.rs:12:5`.
local PATH = [=[[^\s:'"`()<>\[\]{},;]+(:\d+){0,2}]=]

-- The ranges `pattern` matches in `buffer` from `from` to `to`, or none
-- when it can't be searched for.
local function find_all(
	buffer: greed.Buffer,
	pattern: string,
	from: number?,
	to: number?
): { { from: number, to: number } }
	return buffer:find_all(pattern, from, to) or {}
end

-- The file `text` (a match of PATH) names, and the line and column after
-- it, when that file is there: a relative path is taken from `cwd`, or the
-- project's root.
local function resolve(text: string, cwd: string?): (string?, number?, number?)
	local before, row, col = string.match(text, "^(.-):(%d+):?(%d*)$")
	local name = before or text
	local path = core.project.resolve(name, cwd)
	local info = greed.fs.stat(path)
	if info == nil or info.kind ~= "file" then
		return nil, nil, nil
	end
	return path, tonumber(row), tonumber(col)
end

--- The file named at `pos` in `buffer`, with the line and column after it
--- if there are any (1-based), when that file is there: a relative path is
--- taken from the folder the terminal's shell is in, or the project's.
function M.file_at(buffer: greed.Buffer, pos: number): (string?, number?, number?)
	local line = buffer:line_of(pos)
	for _, found in find_all(buffer, PATH, buffer:line_start(line), buffer:line_end(line)) do
		if pos >= found.from and pos < found.to then
			return resolve(buffer:slice(found.from, found.to), M.cwd(buffer))
		end
	end
	return nil, nil, nil
end

-- A path with a line after it, as compilers, linters and test runners
-- point at a problem: `src/main.rs:12:5`.
local REFERENCE = [=[[^\s:'"`()<>\[\]{},;]+:\d+(:\d+)?]=]

--- A place in a file that a terminal's output points at, like
--- `src/main.rs:12:5`: where it is in the buffer, the file, its 1-based
--- line and column, and the text around it, saying what's there.
export type Reference = {
	from: number,
	to: number,
	path: string,
	line: number,
	col: number?,
	text: string,
}

-- What a reference on line `line` says: its line's text, and for one on a
-- line of its own after an arrow (`--> src/main.rs:2:9`, as rustc prints),
-- the line before it, which says what's wrong.
local function said_about(buffer: greed.Buffer, line: number): string
	local function trimmed(at: number): string
		return string.match(buffer:line_text(at), "^%s*(.-)%s*$") or ""
	end
	local text = trimmed(line)
	if line > 0 and string.match(text, "^%-%->") then
		text = `{trimmed(line - 1)} {text}`
	end
	return text
end

export type ReferenceOptions = {
	--- Only look from byte `from` to byte `to`; the whole buffer by default.
	from: number?,
	to: number?,
	--- The folder relative paths are taken from; by default the one the
	--- terminal's shell is in, or the project's root.
	cwd: string?,
}

--- The places in files that the output in `buffer` points at, in order,
--- for files that are there.
function M.references(buffer: greed.Buffer, options: ReferenceOptions?): { Reference }
	local opts: ReferenceOptions = options or {}
	local cwd = opts.cwd or M.cwd(buffer)
	local list: { Reference } = {}
	-- Files named again and again, as test runs do, are looked for once.
	local there: { [string]: boolean } = {}
	for _, found in find_all(buffer, REFERENCE, opts.from, opts.to) do
		local text = buffer:slice(found.from, found.to)
		local name = string.match(text, "^(.-):%d") :: string
		local path, line, col = nil, nil, nil
		if there[name] ~= false then
			path, line, col = resolve(text, cwd)
			there[name] = path ~= nil
		end
		if path and line then
			table.insert(list, {
				from = found.from,
				to = found.to,
				path = path,
				line = line,
				col = col,
				text = said_about(buffer, buffer:line_of(found.from)),
			})
		end
	end
	return list
end

-- Selects the next reference after the cursor, or with `back` the one
-- before it.
local function to_reference(ctx: greed.Context, back: boolean)
	local head = ctx.view:cursor()
	local list = M.references(ctx.buffer)
	local found: Reference? = nil
	for _, ref in list do
		if back and ref.to <= head then
			found = ref
		elseif not back and ref.from > head then
			found = ref
			break
		end
	end
	if found == nil then
		greed.echo(if #list == 0 then "the output names no file and line" else "no more")
		return
	end
	ctx.view:set_selection({
		ranges = { { anchor = found.from, head = found.to - 1 } },
		primary = 1,
	})
end

-- Opens `path` in the main view, at 1-based `line` and `col` if given.
local function open_file(path: string, line: number?, col: number?)
	core.file.open_at(path, if line then line - 1 else nil, if col then col - 1 else nil)
end

greed.command({
	name = "terminal-next-reference",
	doc = "Go to the next file and line the output names, like an error's place; g x opens it",
	run = function(ctx)
		to_reference(ctx, false)
	end,
})

greed.command({
	name = "terminal-prev-reference",
	doc = "Go to the file and line the output names before the cursor",
	run = function(ctx)
		to_reference(ctx, true)
	end,
})

greed.command({
	name = "terminal-references",
	doc = "Pick from the files and lines the output names, like a compiler's errors, to open one",
	run = function(ctx)
		local list = M.references(ctx.buffer)
		if #list == 0 then
			greed.echo("the output names no file and line")
			return
		end
		local items = {}
		for _, ref in list do
			local shown = core.project.relative(ref.path)
			table.insert(items, { label = `{shown}:{ref.line}  {ref.text}`, value = ref })
		end
		picker.pick("In the output", items, function(item)
			local ref = item.value :: Reference
			open_file(ref.path, ref.line, ref.col)
		end)
	end,
})

--- Where the link at `pos` in `buffer` goes: one a terminal's program
--- printed, or a URL written there.
function M.link_at(buffer: greed.Buffer, pos: number): string?
	local line = buffer:line_of(pos)
	local start = buffer:line_start(line)
	local term = term_of(buffer)
	if term then
		local links: { greed.TerminalLink }? = if line < term.history
			then term.links[term.dropped + line]
			else term.screen_links[line - term.history]
		if links then
			for _, link in links do
				if pos >= start + link.from and pos < start + link.to then
					return link.uri
				end
			end
		end
	end
	for _, found in find_all(buffer, URL, start, buffer:line_end(line)) do
		if pos >= found.from and pos < found.to then
			return buffer:slice(found.from, found.to)
		end
	end
	return nil
end

-- Opens the link at `pos` in `buffer`, or else the file named there; false
-- when there's neither.
local function open_at(buffer: greed.Buffer, pos: number): boolean
	local uri = M.link_at(buffer, pos)
	if uri then
		core.file.open_link(uri)
		return true
	end
	local path, line, col = M.file_at(buffer, pos)
	if path then
		open_file(path, line, col)
		return true
	end
	return false
end

greed.command({
	name = "open-link",
	doc = "Open the link under the cursor, or the file it names, at the line it says",
	run = function(ctx)
		if not open_at(ctx.buffer, ctx.view:cursor()) then
			greed.echo("no link or file here")
		end
	end,
})

-- Links, in terminals and in any text, as things to act on.
core.actions.finder({
	name = "link",
	find = function(view, range)
		local uri = M.link_at(view:buffer(), range.head)
		return if uri then { { kind = "link", label = uri, value = uri } } else nil
	end,
})
core.actions.action({
	kind = "link",
	name = "open",
	doc = "Open it with the link-opener",
	run = function(target)
		core.file.open_link(target.value)
	end,
})
core.actions.action({
	kind = "link",
	name = "copy",
	doc = "Copy it",
	run = function(target)
		greed.clipboard.set(target.value)
		greed.echo(`copied {target.value}`)
	end,
})

--- Shows `term` in the main view and types into it.
function M.show(term: Term)
	local view = greed.view()
	if not shown(term) then
		term.previous = view:buffer()
		term.owns = false
		view:show(term.buffer)
	end
	M.enter(view)
end

-- Moves the cursor to the next command's start after the cursor's line,
-- or with `back` the one before it.
local function to_command(ctx: greed.Context, back: boolean)
	local buffer = ctx.buffer
	local line = buffer:line_of(ctx.view:cursor())
	local commands = M.commands(buffer)
	local found: number? = nil
	for _, c in commands do
		local at = start_of(c)
		if at then
			local their = buffer:line_of(at)
			if back and their < line then
				found = at
			elseif not back and their > line then
				found = at
				break
			end
		end
	end
	if found == nil then
		greed.echo(
			if #commands == 0
				then "no commands marked: the shell has to mark its prompts (see Terminals in the docs)"
				else `no command {if back then "before" else "after"} this one`
		)
		return
	end
	ctx.view:set_cursor(found)
end

greed.command({
	name = "terminal-prev-command",
	doc = "Go to the command before the cursor in a terminal, where its shell marks commands",
	run = function(ctx)
		to_command(ctx, true)
	end,
})

greed.command({
	name = "terminal-next-command",
	doc = "Go to the command after the cursor in a terminal, where its shell marks commands",
	run = function(ctx)
		to_command(ctx, false)
	end,
})

--- The output of the command at `pos` in the terminal shown in `buffer`,
--- as a byte range, or nil when its shell didn't mark any there.
function M.output_at(buffer: greed.Buffer, pos: number): (number?, number?)
	local list = M.commands(buffer)
	for i, c in list do
		local from = start_of(c) or c.output
		local after = list[i + 1]
		local to = after and (after.prompt or after.command) or buffer:len()
		if from and from <= pos and pos < to and c.output then
			local stop = c.done or to
			-- Not the line break before the next prompt.
			if stop > c.output and buffer:slice(stop - 1, stop) == "\n" then
				stop -= 1
			end
			return c.output, stop
		end
	end
	return nil, nil
end

greed.command({
	name = "terminal-select-output",
	doc = "Select the output of the command at the cursor in a terminal, to copy or search",
	run = function(ctx)
		local from, to = M.output_at(ctx.buffer, ctx.view:cursor())
		if from == nil or to == nil then
			greed.echo("no output marked here")
			return
		end
		ctx.view:set_selection({ ranges = { { anchor = from, head = to } }, primary = 1 })
	end,
})

--- Sends `text` to the terminal last typed into, as if pasted, then enter,
--- so a shell or a REPL runs it. False when there's no terminal to send it
--- to.
function M.send(text: string): boolean
	local term = last_used
	if term == nil or term.terminal:exit_code() ~= nil then
		return false
	end
	term.terminal:paste(text)
	term.terminal:key("enter")
	return true
end

greed.command({
	name = "terminal-send",
	doc = "Send the selection, or the cursor's line, to the terminal you used last, and run it",
	run = function(ctx)
		local buffer = ctx.buffer
		if term_of(buffer) then
			greed.echo("this is a terminal; send from a file")
			return
		end
		local parts = {}
		for _, range in ctx.view:selection().ranges do
			local from, to = core.text.span(range)
			-- A cursor sends its line.
			if to - from <= 1 then
				local line = buffer:line_of(range.head)
				from = buffer:line_start(line)
				to = buffer:line_end(line)
			end
			table.insert(parts, (string.gsub(buffer:slice(from, to), "\r?\n$", "")))
		end
		if not M.send(table.concat(parts, "\n")) then
			greed.echo("no terminal to send to: space t opens one")
			return
		end
		greed.echo(`sent to {(last_used :: Term).command}`)
	end,
})

greed.command({
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

greed.keymap.bind({ layer = "leader" }, { t = "pick-terminal", T = "terminal-send" })

-- The mouse in a terminal. A program that asked for it gets it. Otherwise
-- the wheel scrolls back through the output, as tmux does: up stops typing
-- into the program, and back at the bottom types into it again. In a full
-- screen program the wheel sends arrow keys instead, as xterm does. A
-- click types into the program, and a drag selects output to copy.
local dragged = false
local held: number? = nil

local function on_mouse(event: greed.MouseEvent): boolean
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
		if up and greed.mode.get() == MODE then
			greed.mode.set(core.style.home())
		end
		core.mouse.scroll(view, if up then -core.mouse.lines else core.mouse.lines)
		if not up and running and view:scroll() >= term.history then
			M.enter(view)
		end
		return true
	end
	if event.kind == "press" and event.button == "left" and event.ctrl and event.pos then
		if open_at(view:buffer(), event.pos) then
			return true
		end
	end
	if event.kind == "press" and event.button == "left" then
		view:focus()
		greed.mode.set(core.style.home())
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
greed.on("mouse", function(event: greed.MouseEvent)
	local view = event.view
	if
		event.kind == "press"
		and view
		and not term_of(view:buffer())
		and greed.mode.get() == MODE
	then
		greed.mode.set(core.style.home())
	end
end)

greed.keymap.isolate(MODE)
greed.keymap.fallback(MODE, "terminal-key")
greed.keymap.bind(MODE, {
	["ctrl-\\"] = "terminal-leave",
	["ctrl-space"] = "terminal-leader",
	esc = "terminal-esc",
})
greed.mode.set_cursor(MODE, "block")
greed.keymap.bind({ kind = "terminal" }, {
	i = "terminal-input",
	a = "terminal-input",
	enter = "terminal-input",
	p = "terminal-paste",
	["g x"] = "open-link",
	["[ p"] = "terminal-prev-command",
	["] p"] = "terminal-next-command",
	["g o"] = "terminal-select-output",
	["] e"] = "terminal-next-reference",
	["[ e"] = "terminal-prev-reference",
})

greed.keymap.bind({ layer = "leader", kind = "terminal" }, {
	d = "terminal-references",
})

local tasks = require("@self/tasks")
tasks.setup(M)
--- Tasks from your config, by name (tasks.luau).
M.tasks = tasks.tasks
--- Runs the task `name`, or says why it can't.
function M.run_task(name: string): (boolean, string?)
	return tasks.run(M, name)
end
--- Every task for the project at `root` (the shown one by default).
M.all_tasks = tasks.all

-- A command running in a terminal, or a program other than your shell,
-- keeps the session on :q (core's on-quit).
core.file.running("terminals", function()
	local found = {}
	for _, term in terms do
		local t = term.terminal
		if t:valid() and t:exit_code() == nil and (term.asked or term.adopted or t:busy()) then
			local what = if term.asked then term.command else t:title() or "a command"
			table.insert(found, `{what} in a terminal`)
		end
	end
	return found
end)

-- Terminals as objects, by their buffer's id: what runs, where, and how it
-- ended, for the inspector and agents.
local function term_object(term: Term): core.Object
	return {
		kind = "terminal",
		id = `terminal:{term.buffer:id()}`,
		label = term.terminal:title() or term.command,
		value = term,
	}
end

core.objects.kind({
	name = "terminal",
	doc = "A program running in a terminal",
	list = function()
		local out = {}
		for _, term in terms do
			if term.terminal:valid() then
				table.insert(out, term_object(term))
			end
		end
		return out
	end,
	get = function(key)
		local term = terms[tonumber(key) or -1]
		return if term and term.terminal:valid() then term_object(term) else nil
	end,
	inspect = function(term: Term)
		local t = term.terminal
		return {
			command = term.command,
			program = t:program(),
			folder = t:cwd(),
			running = t:exit_code() == nil,
			exit_code = t:exit_code(),
			busy = t:busy(),
			failed_commands = #term.failures,
			agent = term.agent,
		}
	end,
	relations = function(term: Term)
		local views = {}
		for _, view in term.buffer:views() do
			table.insert(views, assert(core.objects.get(`view:{view:id()}`)))
		end
		return {
			buffer = { assert(core.objects.get(`buffer:{term.buffer:id()}`)) },
			views = views,
		}
	end,
})

return M
