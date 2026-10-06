-- The command line: press ":" (alt-x in edit mode) and type a command, like
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
local core = require("@core")
local menu = core.menu

-- At most this many matches are shown.
local SHOWN = 8
-- At most this many command lines are remembered.
local HISTORY = 100

local aliases: { [string]: string } = {}
local history: { string } = {}

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
	buffer: greed.Buffer,
	view: greed.View,
	-- The mode to go back to when the command line closes.
	mode: string,
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

local open: Open? = nil

-- The prompt line, which is always the last one.
local function prompt_start(o: Open): number
	return o.buffer:line_start(o.buffer:line_count() - 1)
end

-- Rewrites the buffer: matches above, then ":" and `o.text`. The cursor
-- stays where it was in the prompt, or goes to its end with `to_end`.
local function render(o: Open, to_end: boolean?)
	local start = prompt_start(o)
	local column = o.view:selection().ranges[1].head - start
	local lines = {}
	local marks: { greed.Mark } = {}
	local from = 0
	for i, candidate in o.candidates do
		if i > SHOWN then
			break
		end
		local line = " " .. candidate.text
		if candidate.doc and candidate.doc ~= "" then
			line ..= "  "
			table.insert(marks, { from = from + #line, to = from + #line + #candidate.doc, style = "ui.menu.doc" })
			line ..= candidate.doc
		end
		menu.mark_row(marks, from, line, i == o.current, greed.fuzzy_positions(o.word, candidate.text), 1)
		table.insert(lines, line)
		from += #line + 1
	end
	table.insert(lines, ":" .. o.text)
	local text = table.concat(lines, "\n")
	local new_start = #text - #o.text - 1
	local head = if to_end then #text else new_start + math.clamp(column, 1, #o.text + 1)
	o.buffer:edit(function(e)
		e:replace(0, o.buffer:len(), text)
		e:select({ ranges = { { anchor = head, head = head } }, primary = 1 })
	end)
	o.buffer:decorate("cmdline", marks)
	-- Two rows of border.
	o.view:configure({ height = #lines + 2 })
end

-- Closes the command line; unless what's typed is about to run, a preview
-- shown while going through matches is undone.
local function close(running: boolean?)
	if open then
		local view, mode, previewed = open.view, open.mode, open.previewed
		open = nil
		view:close()
		greed.mode.set(mode)
		if previewed and not running then
			previewed(nil)
		end
	end
end

local function update(o: Open, text: string)
	o.text = text
	o.candidates, o.word, o.preview = complete.candidates(text, first_words(), resolve)
	o.current = 0
	o.word_start = nil
end

-- Shows `text` on the prompt with fresh matches, cursor at the end.
local function set_text(o: Open, text: string)
	update(o, text)
	render(o, true)
end

greed.on("buffer.changed", function(event: greed.BufferChanged)
	local o = open
	if o == nil or event.buffer:id() ~= o.buffer:id() then
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
	end
end)

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
	local name, bang, delimiter, rest = string.match(text, "^%s*([sgv])(!?)([^%w%s\\\"|])(.*)$")
	if name == nil or delimiter == nil or rest == nil or (bang == "!" and name ~= "g") then
		return nil, {}, false
	end
	local parts = split_at(rest, delimiter)
	if name == "s" then
		return "substitute", { parts[1], parts[2] or "", string.gsub(parts[3] or "", "%s", "") }, false
	end
	-- What :g runs is the rest of the line, delimiters and all.
	local command = table.concat(parts, delimiter, 2)
	return "global", { parts[1], command }, name == "v" or bang == "!"
end

local execute: (text: string, lines: { first: number, last: number }?) -> ()

-- :g/regex/command runs `command` on each line from `first` to `last` that
-- matches (or, `inverted`, doesn't); with no command it selects those lines.
local function global(pattern: string, command: string, inverted: boolean, first: number, last: number)
	local view = greed.view()
	local buffer = view:buffer()
	local regex = core.search.smart_case(if pattern == "" then core.search.last() or "" else pattern)
	-- Marks over each line keep its place as commands change the lines
	-- around it; one that ends up empty was deleted, unless it was empty.
	local marks: { greed.Mark } = {}
	local lengths: { [string]: number } = {}
	for line = first, last do
		local from, to = buffer:line_start(line), buffer:line_end(line)
		-- The match's start and end, or nil and the error for a bad pattern.
		local found, err = buffer:find(regex, from)
		if found == nil and err then
			error(err, 0)
		end
		local matches = found ~= nil and found <= to and buffer:line_of(found) == line
		if matches ~= inverted then
			local name = tostring(#marks + 1)
			local stop = math.min(to + 1, buffer:len())
			table.insert(marks, { from = from, to = stop, style = name })
			lengths[name] = stop - from
		end
	end
	if command == "" then
		local ranges = {}
		for _, mark in marks do
			table.insert(ranges, { anchor = mark.from, head = buffer:line_end(buffer:line_of(mark.from)) })
		end
		if #ranges > 0 then
			view:set_selection({ ranges = ranges, primary = 1 })
		end
		return
	end
	buffer:decorate("cmdline-global", marks)
	greed.history.start_group()
	for i = 1, #marks do
		for _, mark in buffer:decorations("cmdline-global") do
			if mark.style == tostring(i) and (mark.to > mark.from or lengths[mark.style] == 0) then
				local line = buffer:line_of(mark.from)
				execute(command, { first = line, last = line })
			end
		end
	end
	greed.history.end_group()
	buffer:decorate("cmdline-global", {})
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
			current = buffer:line_of(core.motions.cursor(buffer, selection.ranges[selection.primary])),
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
	local parsed = parse.parse(text)
	if parsed == nil then
		return
	end
	local names: { [string]: boolean } = {}
	for _, command in greed.commands() do
		names[command.name] = true
	end
	local name, args = resolve(parsed.name), parsed.args
	-- Vim lets an argument follow a short name directly: :m0, :t$, :>.
	local short, rest = string.match(parsed.name, "^(%a+)([^%a].*)$")
	if not names[name] and short and rest and names[resolve(short)] then
		name = resolve(short)
		table.insert(args, 1, rest)
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
		local buffer = greed.create_buffer("cmdline", ":")
		local view = greed.float(buffer, { width = "100%", height = 3, anchor = "bottom" })
		view:set_selection({ ranges = { { anchor = 1, head = 1 } }, primary = 1 })
		local o: Open = {
			buffer = buffer,
			view = view,
			mode = greed.mode.get(),
			text = "",
			candidates = {},
			word = "",
			current = 0,
			history_index = 0,
		}
		open = o
		greed.mode.set("insert")
		set_text(o, ctx.args[1] or "")
	end,
})

greed.command({
	name = "command-line-run",
	doc = "Run what's typed on the command line",
	run = function()
		local o = open
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
	local o = open
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
	local o = open
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

local set_args: { greed.ArgSpec } = {
	{ name = "option", doc = "The option to set", complete = "option" },
	{ name = "value", doc = "true, false, a number or text" },
}

greed.command({
	name = "set",
	doc = "Set an option",
	args = set_args,
	run = function(ctx)
		local name = ctx.args[1]
		-- Text values can have spaces.
		local value = table.concat(ctx.args, " ", 2)
		if name == nil or value == "" then
			error("set needs an option and a value, e.g. :set tab-width 2", 0)
		end
		local parsed: greed.OptionValue = if value == "true"
			then true
			elseif value == "false" then false
			else tonumber(value) or value
		greed.option.set(name, parsed)
	end,
})

local M = {}

--- Makes `name` run `command` on the command line, e.g. `alias("w", "save")`.
function M.alias(name: string, command: string)
	aliases[name] = command
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
	q = "quit",
	qa = "quit-all",
	quitall = "quit-all",
	wq = "save-quit",
	x = "save-quit",
	xit = "save-quit",
	e = "open",
	edit = "open",
	o = "open",
	h = "describe-command",
	help = "describe-command",
	bc = "buffer-close",
	bclose = "buffer-close",
	bd = "buffer-close",
	bdelete = "buffer-close",
	bco = "buffer-close-others",
	clo = "pane-close",
	close = "pane-close",
	sp = "pane-split-down",
	split = "pane-split-down",
	vs = "pane-split-right",
	vsplit = "pane-split-right",
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

core.style.kind_modes.cmdline = "insert"
greed.keymap.bind({ mode = "insert", kind = "cmdline" }, {
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

greed.keymap.bind("normal", {
	[":"] = "command-line",
})

-- In edit mode ":" types, so the command line is on alt-x there.
greed.keymap.bind("edit", {
	["alt-x"] = "command-line",
})

return M
