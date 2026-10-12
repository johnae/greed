-- The command line: press ":" (alt-x in the vscode style) and type a command, like
-- in Vim or Helix.
--
-- Every command can be run by name (`:save`, `:pick-file`), and the short
-- names Vim and Helix users know are aliases (`:w`, `:q`, `:wq`, `:e`).
-- Words after the command are its arguments (`:open src/main.rs`), and a
-- trailing "!" forces it (`:q!` quits with unsaved changes). `:lua` runs
-- Luau and `:=` shows the value of an expression. A line range in front
-- (`:%s/a/b/g`, `:5,10d`) selects those lines first; `ex.luau` has Vim's
-- line commands, and `:g/regex/command` is here.
--
-- Matches show above the prompt as you type. Tab and shift-tab go through
-- them, up and down go through earlier command lines starting with what's
-- typed, enter runs and esc closes.
--
-- Other plugins add aliases and argument completion through
-- `require("@cmdline")`:
--
--     local cmdline = require("@cmdline")
--     cmdline.alias("gs", "git-status")
--     cmdline.completer("branch", function(word)
--         return { { text = "main" }, { text = "dev" } }
--     end)
--
-- A command then uses `args = { { name = "branch", complete = "branch" } }`.

local greed = require("@greed")
local parse = require("@self/parse")
local complete = require("@self/complete")
local ex = require("@self/ex")
require("@self/eval")
require("@self/set")
local core = require("@core")
local ui = core.ui

greed.option.define({
	name = "substitute-preview",
	doc = "Show what :s will change as you type it, before it runs",
	default = true,
})

-- At most this many matches are shown.
local SHOWN = 8
-- At most this many command lines are remembered.
local HISTORY = 100

local aliases: { [string]: string } = {}
local history: { string } = {}

-- The commands whose argument can follow their short name with no space.
local JOINED: { [string]: boolean } = {
	["move-lines"] = true,
	["copy-lines"] = true,
	["delete-lines"] = true,
	["yank-lines"] = true,
	["join-lines"] = true,
	buffer = true,
}

local function resolve(name: string): string
	return aliases[name] or name
end

-- What the first word can be: commands, aliases and the Luau prompts.
local function first_words(): { complete.Candidate }
	local items: { complete.Candidate } = {
		{ text = "lua", doc = "Run Luau code" },
		{ text = "=", doc = "Show the value of a Luau expression" },
	}
	local docs = {}
	for _, command in greed.commands() do
		docs[command.name] = command.doc
		table.insert(items, { text = command.name, doc = command.doc })
	end
	for alias, name in aliases do
		table.insert(items, { text = alias, doc = name .. ": " .. (docs[name] or "") })
	end
	return items
end

type Open = {
	-- The client it's open for; each has its own.
	client: number,
	buffer: greed.Buffer,
	view: greed.View,
	-- What draws the matches over the prompt, and whether it's drawing, so
	-- its own edits aren't taken for typing.
	drawn: core.UiView,
	drawing: boolean?,
	-- The view it was opened from, which what's typed runs in.
	target: greed.View,
	float: core.TypingFloat,
	-- Closing to run what's typed.
	running: boolean?,
	-- The text after ":", as last seen.
	text: string,
	candidates: { complete.Candidate },
	-- The word the candidates were found for.
	word: string,
	-- The match tab last filled in, or 0.
	current: number,
	-- Where the word tab fills in starts, while going through matches.
	word_start: number?,
	-- What shows the candidate tab is on, and the one that last showed
	-- something, to undo it if nothing runs.
	preview: complete.Preview?,
	previewed: complete.Preview?,
	-- While going through history: what was typed before, and where we are.
	history_prefix: string?,
	history_index: number,
}

-- The command line open for each client, by its id.
local opened: { [number]: Open } = {}

-- The prompt line, which is always the last one.
local function prompt_start(o: Open): number
	return o.drawn:input_start()
end

-- The matches, a row each, what's typed picked out and the current one
-- marked.
local function draw(o: Open): core.UiNode
	-- A match's doc is cut to the width rather than wrapped, so every match
	-- keeps one row and the first ones stay in sight.
	local _, cols = o.view:size()
	local shown = table.move(o.candidates, 1, math.min(#o.candidates, SHOWN), 1, {})
	return ui.list(shown, function(candidate: complete.Candidate): { core.UiSpan }
		local spans: { core.UiSpan } = { ui.span(" ") }
		local matched = greed.fuzzy_positions(o.word, candidate.text, { case = core.search.case() })
		for _, span in ui.matched(candidate.text, matched) do
			table.insert(spans, span)
		end
		local doc = candidate.doc
		if doc and doc ~= "" then
			local room = (cols or 1000) - core.text.width(" " .. candidate.text) - 3
			table.insert(spans, ui.span("  "))
			table.insert(
				spans,
				ui.span(if room > 1 then core.text.clip(doc, room) else "", "ui.menu.doc")
			)
		end
		return spans
	end, { current = o.current })
end

-- Draws the matches above, then ":" and `o.text`. The cursor stays where it
-- was in the prompt, or goes to its end with `to_end`.
local function render(o: Open, to_end: boolean?)
	local column = o.view:cursor() - prompt_start(o)
	o.drawing = true
	o.drawn:redraw()
	local start = prompt_start(o)
	local prompt = ":" .. o.text
	if o.buffer:slice(start, o.buffer:len()) ~= prompt then
		o.buffer:edit(function(e)
			e:replace(start, o.buffer:len(), prompt)
		end)
	end
	o.drawing = nil
	local head = if to_end then o.buffer:len() else start + math.clamp(column, 1, #o.text + 1)
	o.view:set_selection({ ranges = { { anchor = head, head = head } }, primary = 1 })
	-- Two rows of border.
	o.view:configure({ height = o.buffer:line_count() + 2 })
end

-- Closes the command line; unless what's typed is about to run, a preview
-- shown while going through matches is undone (see command-line).
local function close(running: boolean?)
	local o = opened[greed.client.id()]
	if o then
		o.running = running
		o.float.close()
	end
end

local function update(o: Open, text: string)
	o.text = text
	o.candidates, o.word, o.preview = complete.candidates(text, first_words(), resolve)
	o.current = 0
	o.word_start = nil
end

local preview_substitute: (o: Open) -> ()

-- Shows `text` on the prompt with fresh matches, cursor at the end.
local function set_text(o: Open, text: string)
	update(o, text)
	render(o, true)
	preview_substitute(o)
end

local function changed(o: Open)
	if opened[o.client] ~= o or o.drawing then
		return
	end
	local line = o.buffer:slice(prompt_start(o), o.buffer:len())
	if string.sub(line, 1, 1) ~= ":" then
		-- Backspace over the ":" closes, like in Vim.
		close()
		return
	end
	local text = string.sub(line, 2)
	if text ~= o.text then
		o.history_prefix = nil
		update(o, text)
		render(o)
		preview_substitute(o)
	end
end

-- Splits `text` at each unescaped `delimiter`; `\` before the delimiter
-- takes it as is, other backslashes stay for the regex.
local function split_at(text: string, delimiter: string): { string }
	local parts, part = {}, {}
	local i = 1
	while i <= #text do
		local c = string.sub(text, i, i)
		if c == "\\" and string.sub(text, i + 1, i + 1) == delimiter then
			table.insert(part, delimiter)
			i += 2
		else
			if c == delimiter then
				table.insert(parts, table.concat(part))
				part = {}
			else
				table.insert(part, c)
			end
			i += 1
		end
	end
	table.insert(parts, table.concat(part))
	return parts
end

-- Vim's commands written with a pattern right after the name: :s/a/b/g,
-- :g/regex/command and :v/regex/command (or :g!). Returns the name, the
-- parts, and whether a :g is inverted, or nil for anything else.
local function pattern_command(text: string): (string?, { string }, boolean)
	local name, bang, delimiter, rest = string.match(text, '^%s*([sgv])(!?)([^%w%s\\"|])(.*)$')
	if name == nil or delimiter == nil or rest == nil or (bang == "!" and name ~= "g") then
		return nil, {}, false
	end
	local parts = split_at(rest, delimiter)
	if name == "s" then
		return "substitute",
			{ parts[1], parts[2] or "", string.gsub(parts[3] or "", "%s", "") },
			false
	end
	-- What :g runs is the rest of the line, delimiters and all.
	local command = table.concat(parts, delimiter, 2)
	return "global", { parts[1], command }, name == "v" or bang == "!"
end

-- The marks showing what :s would change.
local PREVIEW = "substitute-preview"

-- How a line break in a replacement shows in the preview.
local BREAK = "⏎"

-- Shows on `o`'s view what the :s typed would change, on the lines in sight:
-- its matches while only the pattern is typed, then each match struck
-- through with its replacement beside it. Anything else, or a pattern half
-- typed, shows nothing.
function preview_substitute(o: Open)
	local view = o.target
	if not view:valid() then
		return
	end
	local buffer = view:buffer()
	buffer:decorate(PREVIEW, {})
	if not greed.option.get("substitute-preview") then
		return
	end
	local selection = view:selection()
	local selected_first, selected_last = ex.selected_lines(view)
	local ok, first, last, rest = pcall(parse.range, o.text, {
		buffer = buffer,
		current = buffer:line_of(core.motions.cursor(buffer, selection.ranges[selection.primary])),
		first = selected_first,
		last = selected_last,
	})
	if not ok then
		return
	end
	local delimiter, body = string.match(rest, '^%s*s([^%w%s\\"|])(.*)$')
	if delimiter == nil or body == nil then
		return
	end
	local parts = split_at(body, delimiter)
	-- Only what's in sight: a whole file's matches would slow every key.
	local shown_from, shown_to = view:visible()
	local from = math.max(first or selected_first, buffer:line_of(shown_from))
	local to = math.min(last or selected_last, buffer:line_of(shown_to))
	if from > to then
		return
	end
	local found, edits = pcall(function(): { ex.Substitution }
		return (ex.substitutions(buffer, parts[1], parts[2] or "", parts[3] or "", from, to))
	end)
	if not found then
		return
	end
	local marks: { greed.Mark } = {}
	for _, edit in edits do
		if parts[2] == nil then
			table.insert(marks, { from = edit.from, to = edit.to, style = "ui.search.match" })
		else
			table.insert(marks, { from = edit.from, to = edit.to, style = "diff.minus" })
			if edit.text ~= "" then
				local shown = string.gsub(edit.text, "\n", BREAK)
				table.insert(
					marks,
					{ from = edit.to, to = edit.to, style = "diff.plus", text = shown }
				)
			end
		end
	end
	buffer:decorate(PREVIEW, marks)
end

local execute: (text: string, lines: { first: number, last: number }?) -> ()

-- :g/regex/command runs `command` on each line from `first` to `last` that
-- matches (or, `inverted`, doesn't); with no command it selects those lines.
local function global(
	pattern: string,
	command: string,
	inverted: boolean,
	first: number,
	last: number
)
	local view = greed.view()
	local buffer = view:buffer()
	local regex = core.search.pattern(if pattern == "" then core.search.last() or "" else pattern)
	local starts: { number } = {}
	for line = first, last do
		local from, to = buffer:line_start(line), buffer:line_end(line)
		-- The match's start and end, or nil, nil and the error for a bad pattern.
		local found, _, err = buffer:find(regex, from)
		if found == nil and err then
			error(err, 0)
		end
		local matches = found ~= nil and found <= to and buffer:line_of(found) == line
		if matches ~= inverted then
			table.insert(starts, from)
		end
	end
	if command == "" then
		local ranges = {}
		for _, from in starts do
			table.insert(ranges, { anchor = from, head = buffer:line_end(buffer:line_of(from)) })
		end
		if #ranges > 0 then
			view:set_selection({ ranges = ranges, primary = 1 })
		end
		return
	end
	-- Tracking each line keeps its place as commands change the lines around
	-- it, and tells when one deleted it.
	local lines: { greed.Tracked } = {}
	for _, from in starts do
		local stop = math.min(buffer:line_end(buffer:line_of(from)) + 1, buffer:len())
		table.insert(lines, buffer:track_range(from, stop))
	end
	greed.history.start_group()
	for _, tracked in lines do
		local from = tracked:range()
		if from then
			local line = buffer:line_of(from)
			execute(command, { first = line, last = line })
		end
		tracked:forget()
	end
	greed.history.end_group()
end

-- Runs a command line: Luau for "=" and "lua", otherwise a command, with
-- a line range before it (`:%s/a/b/`, `:5,10d`) or `lines` selected first.
-- A range alone goes to its last line.
function execute(text: string, lines: { first: number, last: number }?)
	local expression = string.match(text, "^%s*=%s*(.*)$")
	local code = string.match(text, "^%s*lua%s+(.*)$")
	if expression or code then
		local ok, result = greed.eval((expression or code) :: string)
		if not ok then
			error(result, 0)
		end
		if result ~= "" or expression then
			greed.echo(if result == "" then "nil" else result)
		end
		return
	end
	local view = greed.view()
	local buffer = view:buffer()
	local first: number?, last: number? = nil, nil
	if lines then
		first, last = lines.first, lines.last
	else
		local selection = view:selection()
		local selected_first, selected_last = ex.selected_lines(view)
		first, last, text = parse.range(text, {
			buffer = buffer,
			current = buffer:line_of(
				core.motions.cursor(buffer, selection.ranges[selection.primary])
			),
			first = selected_first,
			last = selected_last,
		})
	end
	if first and last then
		if string.match(text, "^%s*$") then
			ex.go_to_line(view, last)
			return
		end
		view:set_selection({
			ranges = { { anchor = buffer:line_start(first), head = buffer:line_end(last) } },
			primary = 1,
		})
	end
	local special, pattern_args, inverted = pattern_command(text)
	if special == "global" then
		global(
			pattern_args[1],
			pattern_args[2],
			inverted,
			first or 0,
			last or buffer:line_count() - 1
		)
		return
	elseif special then
		greed.run(special, { args = pattern_args })
		return
	end
	-- :!cmd runs it in this project's shell, where its output stays; with
	-- lines (:%!sort), they go through it, as | does with a selection.
	local bang = string.match(text, "^%s*!(.*)$")
	if bang then
		greed.run(if first then "pipe" else "shell-line", { args = { bang } })
		return
	end
	local parsed = parse.parse(text)
	if parsed == nil then
		return
	end
	local names: { [string]: boolean } = {}
	for _, command in greed.commands() do
		names[command.name] = true
	end
	local name, args = resolve(parsed.name), parsed.args
	-- Vim lets an address follow a line command's name directly (:m0, :t$,
	-- :m-2), and :b# goes to the last file. Anything else typed onto a
	-- name, like :write-all, is a name of its own.
	local short, rest = string.match(parsed.name, "^(%a+)([^%a].*)$")
	if not names[name] and short and rest and not string.match(rest, "^%-%a") then
		local joined = resolve(short)
		if JOINED[joined] and names[joined] then
			name = joined
			table.insert(args, 1, rest)
		end
	end
	if not names[name] then
		error("no command called " .. parsed.name, 0)
	end
	greed.run(name, { args = args, force = parsed.force })
end

local function remember(text: string)
	if string.match(text, "^%s*$") or history[#history] == text then
		return
	end
	table.insert(history, text)
	if #history > HISTORY then
		table.remove(history, 1)
	end
end

greed.command({
	name = "command-line",
	doc = "Type a command to run, with completion, starting with the text given",
	args = { { name = "text" } },
	run = function(ctx)
		close()
		local client = greed.client.id()
		local o: Open
		local float = core.floats.typing(
			greed.create_buffer("cmdline", ":"),
			{ width = "100%", height = 3, anchor = "bottom" },
			{
				-- Both can come before `o` is set, while the line is opening.
				on_change = function()
					if o :: Open? then
						changed(o)
					end
				end,
				-- However it closed, if it's not to run what's typed.
				on_close = function()
					if not (o :: Open?) then
						return
					end
					if opened[client] == o then
						opened[client] = nil
					end
					if o.previewed and not o.running then
						o.previewed(nil)
					end
					if o.target:valid() then
						o.target:buffer():decorate(PREVIEW, {})
					end
				end,
			}
		)
		float.view:set_cursor(1)
		o = {
			client = client,
			buffer = float.buffer,
			view = float.view,
			drawn = ui.mount(float.buffer, function()
				return draw(o)
			end, nil, { ns = "cmdline", keys = false, input = true, draw = false }),
			target = ctx.view,
			float = float,
			text = "",
			candidates = {},
			word = "",
			current = 0,
			history_index = 0,
		} :: Open
		opened[client] = o
		set_text(o, ctx.args[1] or "")
	end,
})

greed.command({
	name = "command-line-run",
	doc = "Run what's typed on the command line",
	run = function()
		local o = opened[greed.client.id()]
		if o == nil then
			return
		end
		local text = o.text
		close(true)
		remember(text)
		execute(text)
	end,
})

greed.command({
	name = "command-line-close",
	doc = "Close the command line without running anything",
	run = function()
		close()
	end,
})

-- Fills in the next (`delta` 1) or previous (-1) match.
local function cycle(delta: number)
	local o = opened[greed.client.id()]
	if o == nil or #o.candidates == 0 then
		return
	end
	local count = math.min(#o.candidates, SHOWN)
	local word_start = o.word_start or (string.find(o.text, "%S*$") :: number)
	o.word_start = word_start
	o.current = (o.current - 1 + delta) % count + 1
	o.text = string.sub(o.text, 1, word_start - 1) .. parse.quote(o.candidates[o.current].text)
	render(o, true)
	if o.preview then
		o.preview(o.candidates[o.current].text)
		o.previewed = o.preview
	end
end

greed.command({
	name = "command-line-next",
	doc = "Fill in the next match on the command line",
	run = function()
		cycle(1)
	end,
})

greed.command({
	name = "command-line-prev",
	doc = "Fill in the previous match on the command line",
	run = function()
		cycle(-1)
	end,
})

-- Steps through history (`delta` -1 is older), only through lines that
-- start with what was typed when stepping began.
local function step(delta: number)
	local o = opened[greed.client.id()]
	if o == nil then
		return
	end
	if o.history_prefix == nil then
		o.history_prefix = o.text
		o.history_index = #history + 1
	end
	local prefix = o.history_prefix :: string
	local i = o.history_index + delta
	while i >= 1 and i <= #history do
		if string.sub(history[i], 1, #prefix) == prefix then
			o.history_index = i
			set_text(o, history[i])
			return
		end
		i += delta
	end
	if delta > 0 then
		o.history_index = #history + 1
		set_text(o, prefix)
	end
end

greed.command({
	name = "command-line-older",
	doc = "Show the previous command line that starts with what's typed",
	run = function()
		step(-1)
	end,
})

greed.command({
	name = "command-line-newer",
	doc = "Show the next command line that starts with what's typed",
	run = function()
		step(1)
	end,
})

complete.register("editing-style", function()
	local items = {}
	for _, style in core.style.list() do
		table.insert(items, { text = style.name, doc = style.doc })
	end
	return items
end)

local M = {}

--- Makes `name` run `command` on the command line, e.g. `alias("w", "save")`,
--- until the plugin (or config) that called this goes.
function M.alias(name: string, command: string)
	greed.plugin.tie(core.registry.set(aliases, name, command))
end

--- Adds a way to complete arguments, for commands whose argument specs
--- name it in `complete`. `preview`, if given, shows the match tab is on
--- (like a theme) and gets nil to undo that when nothing runs.
function M.completer(name: string, completer: complete.Completer, preview: complete.Preview?)
	complete.register(name, completer, preview)
end

-- The short names Vim and Helix use.
local defaults: { [string]: string } = {
	w = "save",
	write = "save",
	wa = "save-all",
	wall = "save-all",
	["write-all"] = "save-all",
	q = "quit",
	cq = "quit-abort",
	cquit = "quit-abort",
	qa = "quit-all",
	qall = "quit-all",
	quitall = "quit-all",
	wq = "save-quit",
	x = "save-quit",
	xit = "save-quit",
	["write-quit"] = "save-quit",
	wqa = "save-quit-all",
	wqall = "save-quit-all",
	xa = "save-quit-all",
	xall = "save-quit-all",
	["write-quit-all"] = "save-quit-all",
	e = "open",
	edit = "open",
	o = "open",
	h = "describe-command",
	help = "describe-command",
	b = "buffer",
	ls = "pick-buffer",
	buffers = "pick-buffer",
	files = "pick-buffer",
	bn = "buffer-next",
	bnext = "buffer-next",
	bp = "buffer-prev",
	bN = "buffer-prev",
	bprev = "buffer-prev",
	bprevious = "buffer-prev",
	bNext = "buffer-prev",
	["buffer-previous"] = "buffer-prev",
	bc = "buffer-close",
	bclose = "buffer-close",
	bd = "buffer-close",
	bdelete = "buffer-close",
	bco = "buffer-close-others",
	bcloseother = "buffer-close-others",
	rl = "reload",
	rla = "reload-all",
	noh = "search-clear",
	nohlsearch = "search-clear",
	toggle = "toggle-option",
	get = "get-option",
	["set-option"] = "set",
	fmt = "format",
	u = "undo",
	red = "redo",
	clo = "pane-close",
	close = "pane-close",
	on = "pane-only",
	only = "pane-only",
	sp = "pane-split-down",
	split = "pane-split-down",
	hs = "pane-split-down",
	hsplit = "pane-split-down",
	vs = "pane-split-right",
	vsplit = "pane-split-right",
	new = "pane-new-down",
	vnew = "pane-new-right",
	tabnew = "tab-new",
	tabn = "tab-next",
	tabnext = "tab-next",
	tabp = "tab-previous",
	tabprevious = "tab-previous",
	tabN = "tab-previous",
	tabc = "tab-close",
	tabclose = "tab-close",
	term = "terminal",
	config = "config-open",
	colo = "theme",
	colorscheme = "theme",
	checkhealth = "health",
	setf = "language",
	setfiletype = "language",
	sort = "sort-lines",
	s = "substitute",
	d = "delete-lines",
	delete = "delete-lines",
	y = "yank-lines",
	yank = "yank-lines",
	m = "move-lines",
	move = "move-lines",
	t = "copy-lines",
	co = "copy-lines",
	copy = "copy-lines",
	j = "join-lines",
	join = "join-lines",
	norm = "normal",
	[">"] = "indent",
	["<"] = "dedent",
}
for name, command in defaults do
	M.alias(name, command)
end

core.style.typing_kind("cmdline")
core.style.label_kind("cmdline", "command")
greed.keymap.bind({ kind = "cmdline" }, {
	enter = "command-line-run",
	esc = "command-line-close",
	["ctrl-c"] = "command-line-close",
	tab = "command-line-next",
	["shift-tab"] = "command-line-prev",
	up = "command-line-older",
	down = "command-line-newer",
	["ctrl-p"] = "command-line-older",
	["ctrl-n"] = "command-line-newer",
})

greed.keymap.bind({ role = "command" }, {
	[":"] = "command-line",
})

-- Without modes ":" types, so in the vscode style the command line is on alt-x.
greed.keymap.bind({ style = "vscode", role = "typing" }, {
	["alt-x"] = "command-line",
})

return M
