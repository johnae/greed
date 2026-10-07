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
	doc = 'What a new terminal runs, e.g. "fish -l"; empty for your $SHELL',
	default = "",
})

greed.option.define({
	name = "link-opener",
	doc = 'What opens a link, e.g. "firefox"; empty for xdg-open, or open on macOS',
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

type Term = {
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
}

local M = {}

-- Terminals by the id of their buffer.
local terms: { [number]: Term } = {}

-- The terminal last typed into, where text sent from files goes.
local last_used: Term? = nil

local function term_of(buffer: greed.Buffer): Term?
	return terms[buffer:id()]
end

local function shown(term: Term): boolean
	return greed.view():buffer() == term.buffer
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

-- Styles and images for `rows`, which start at line `line` of the buffer.
-- An image gets one mark, where its first row in the buffer is, reaching
-- to its last so it's drawn whenever any of it shows; `marked` holds the
-- images that have one already.
local function marks(
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
		term.marks_made = made
		local failures = {}
		local start: greed.TerminalMark? = nil
		for _, mark in term.terminal:marks(term.next - term.history) do
			if mark.kind == "prompt" or mark.kind == "command" then
				start = mark
			elseif mark.kind == "done" and start and mark.code and mark.code ~= 0 then
				table.insert(failures, { mark = start, code = mark.code })
			end
		end
		term.failures = failures
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
	mark_failures(term)
	follow(term, screen, before)
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
	terms[term.buffer:id()] = nil
	if last_used == term then
		last_used = nil
	end
	term.terminal:close()
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
		term.terminal:close()
	end
end)

-- Floating terminals belong to the tab they open in.
local FLOAT: greed.FloatSpec = { title = "terminal", width = "80%", height = "80%", tab = true }

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

--- Opens a terminal running `command` (the user's shell without) and
--- types into it: in the focused view, a new pane or a float.
function M.open(command: { string }?, options: OpenOptions?): Term
	local opts: OpenOptions = options or {}
	-- Opened from a terminal, it starts in the folder that one's shell is in.
	local here = M.cwd(greed.view():buffer())
	local buffer = greed.create_buffer("terminal", "")
	buffer:set_readonly(true)
	buffer:set_line_numbers(false)
	-- Every bit of output replaces the screen; keeping each one to undo
	-- would grow without end in a long-running terminal.
	buffer:forget_history()
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
	local limit = greed.option.get("terminal-scrollback") :: number
	local given = if command and #command > 0 then command else shell()
	-- Programs in it can tell which session they're in: `greed FILE` opens
	-- the file here instead of starting another editor inside this one,
	-- and `greed ctl` talks to this session.
	local env = table.clone(M.env)
	local session = greed.session.current()
	if session then
		env.GREED_TERMINAL = session
		env.GREED_SESSION = session
	end
	local spawned, started = pcall(function()
		return greed.terminal.spawn({
			command = given,
			cwd = opts.cwd or here or greed.project.current().root,
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
		marks_made = 0,
		failures = {},
		keep = opts.keep == true,
	}
	terms[buffer:id()] = term
	M.enter(view)
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
end)

greed.on("view.resized", function(event: greed.ViewResized)
	local term = term_of(event.view:buffer())
	if term and term.terminal:exit_code() == nil then
		term.terminal:resize(event.rows, event.cols)
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

-- Two escs this close together (ms) leave the terminal.
local DOUBLE_ESC = 300

-- When esc last went to a program.
local last_esc = -math.huge

-- Sends `key` to the program in the buffer's terminal; once it has exited,
-- stops typing into it instead.
local function send(ctx: greed.Context, key: string)
	local term = term_of(ctx.buffer)
	if term == nil or term.terminal:exit_code() ~= nil then
		greed.mode.set(core.style.home())
		return
	end
	term.terminal:key(key)
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
			greed.run("terminal-leave")
			return
		end
		last_esc = now
		send(ctx, "esc")
	end,
})

greed.command({
	name = "terminal-input",
	doc = "Type into the terminal's program",
	run = function(ctx)
		local term = term_of(ctx.buffer)
		if term and term.terminal:exit_code() == nil then
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
	doc = "Stop typing into the terminal and press space, for the keys after it",
	run = function()
		greed.mode.set(core.style.home())
		-- Styles without space keys (edit mode) just stop typing into it.
		if #greed.keymap.next("space") > 0 then
			greed.keys.feed("space")
		end
	end,
})

-- Text pasted into the client goes to the program in the terminal pane
-- you're in, marked as a paste if it asked for that.
greed.on("client.paste", function(event: greed.ClientPaste)
	local term = term_of(greed.view():buffer())
	if term then
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

-- The file `text` (a match of PATH) names in `buffer`, and the line and
-- column after it, when that file is there: a relative path is taken from
-- the folder the terminal's shell is in, or the project's.
local function resolve(buffer: greed.Buffer, text: string): (string?, number?, number?)
	local before, row, col = string.match(text, "^(.-):(%d+):?(%d*)$")
	local name = before or text
	local path = core.project.resolve(name, M.cwd(buffer))
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
			return resolve(buffer, buffer:slice(found.from, found.to))
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

--- The places in files that the output in `buffer` points at, in order,
--- for files that are there.
function M.references(buffer: greed.Buffer): { Reference }
	local list: { Reference } = {}
	-- Files named again and again, as test runs do, are looked for once.
	local there: { [string]: boolean } = {}
	for _, found in find_all(buffer, REFERENCE) do
		local text = buffer:slice(found.from, found.to)
		local name = string.match(text, "^(.-):%d") :: string
		local path, line, col = nil, nil, nil
		if there[name] ~= false then
			path, line, col = resolve(buffer, text)
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

--- Opens `path` in the main view, at 1-based `line` and `col` if given.
function M.open_file(path: string, line: number?, col: number?)
	greed.open(path)
	if line then
		local view = greed.view()
		local buffer = view:buffer()
		local row = math.clamp(line - 1, 0, buffer:line_count() - 1)
		local at =
			math.min(buffer:line_start(row) + math.max((col or 1) - 1, 0), buffer:line_end(row))
		view:set_cursor(at)
	end
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
			M.open_file(ref.path, ref.line, ref.col)
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

--- Opens `uri` with the link-opener option, or the system's opener.
function M.open_link(uri: string)
	local given = greed.option.get("link-opener") :: string
	local done, err
	if given ~= "" then
		local command = string.split(given, " ")
		table.insert(command, uri)
		done, err = greed.process.run(command)
	else
		done, err = greed.process.run({ "xdg-open", uri })
		if done == nil then
			done, err = greed.process.run({ "open", uri })
		end
	end
	if done == nil then
		greed.echo(`can't open {uri}: {err}`)
	elseif done.code ~= 0 then
		greed.echo(`can't open {uri}: {done.stderr}`)
	end
end

-- Opens the link at `pos` in `buffer`, or else the file named there; false
-- when there's neither.
local function open_at(buffer: greed.Buffer, pos: number): boolean
	local uri = M.link_at(buffer, pos)
	if uri then
		M.open_link(uri)
		return true
	end
	local path, line, col = M.file_at(buffer, pos)
	if path then
		M.open_file(path, line, col)
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
		M.open_link(target.value)
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

greed.keymap.bind("normal", { ["space t"] = "pick-terminal", ["space T"] = "terminal-send" })

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
for _, mode in { "normal", "vim" } do
	greed.keymap.bind({ mode = mode, kind = "terminal" }, {
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
		["space d"] = "terminal-references",
	})
end
greed.keymap.bind({ mode = "edit", kind = "terminal" }, { enter = "terminal-input" })

--- Whether `term` is still open.
function M.is_open(term: Term): boolean
	return terms[term.buffer:id()] == term
end

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
		if t:exit_code() == nil and (term.asked or t:busy()) then
			local what = if term.asked then term.command else t:title() or "a command"
			table.insert(found, `{what} in a terminal`)
		end
	end
	return found
end)

return M
