-- The command line: press ":" and type a command, like in Vim or Helix.
--
-- Every command can be run by name (`:save`, `:pick-file`), and the short
-- names Vim and Helix users know are aliases (`:w`, `:q`, `:wq`, `:e`).
-- Words after the command are its arguments (`:open src/main.rs`), and a
-- trailing "!" forces it (`:q!` quits with unsaved changes). `:lua` runs
-- Luau and `:=` shows the value of an expression.
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

local kern = require("@kern")
local parse = require("@self/parse")
local complete = require("@self/complete")

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
	for _, command in kern.commands() do
		docs[command.name] = command.doc
		table.insert(items, { text = command.name, doc = command.doc })
	end
	for alias, name in aliases do
		table.insert(items, { text = alias, doc = name .. ": " .. (docs[name] or "") })
	end
	return items
end

type Open = {
	buffer: kern.Buffer,
	view: kern.View,
	-- The mode to go back to when the command line closes.
	mode: string,
	-- The text after ":", as last seen.
	text: string,
	candidates: { complete.Candidate },
	-- The match tab last filled in, or 0.
	current: number,
	-- Where the word tab fills in starts, while going through matches.
	word_start: number?,
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
	for i, candidate in o.candidates do
		if i > SHOWN then
			break
		end
		local mark = if i == o.current then "> " else "  "
		local doc = if candidate.doc and candidate.doc ~= "" then "  " .. candidate.doc else ""
		table.insert(lines, mark .. candidate.text .. doc)
	end
	table.insert(lines, ":" .. o.text)
	local text = table.concat(lines, "\n")
	local new_start = #text - #o.text - 1
	local head = if to_end then #text else new_start + math.clamp(column, 1, #o.text + 1)
	o.buffer:edit(function(e)
		e:replace(0, o.buffer:len(), text)
		e:select({ ranges = { { anchor = head, head = head } }, primary = 1 })
	end)
	-- Two rows of border.
	o.view:configure({ height = #lines + 2 })
end

local function close()
	if open then
		local view, mode = open.view, open.mode
		open = nil
		view:close()
		kern.mode.set(mode)
	end
end

local function update(o: Open, text: string)
	o.text = text
	o.candidates = complete.candidates(text, first_words(), resolve)
	o.current = 0
	o.word_start = nil
end

-- Shows `text` on the prompt with fresh matches, cursor at the end.
local function set_text(o: Open, text: string)
	update(o, text)
	render(o, true)
end

kern.on("buffer.changed", function(event: kern.BufferChanged)
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

-- Runs a command line: Luau for "=" and "lua", otherwise a command.
local function execute(text: string)
	local expression = string.match(text, "^%s*=%s*(.*)$")
	local code = string.match(text, "^%s*lua%s+(.*)$")
	if expression or code then
		local ok, result = kern.eval((expression or code) :: string)
		if not ok then
			error(result, 0)
		end
		if result ~= "" or expression then
			kern.echo(if result == "" then "nil" else result)
		end
		return
	end
	local parsed = parse.parse(text)
	if parsed == nil then
		return
	end
	local name = resolve(parsed.name)
	for _, command in kern.commands() do
		if command.name == name then
			kern.run(name, { args = parsed.args, force = parsed.force })
			return
		end
	end
	error("no command called " .. parsed.name, 0)
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

kern.command({
	name = "command-line",
	doc = "Type a command to run, with completion",
	run = function()
		close()
		local buffer = kern.create_buffer("cmdline", ":")
		local view = kern.float(buffer, { width = "100%", height = 3, anchor = "bottom" })
		view:set_selection({ ranges = { { anchor = 1, head = 1 } }, primary = 1 })
		local o: Open = {
			buffer = buffer,
			view = view,
			mode = kern.mode.get(),
			text = "",
			candidates = {},
			current = 0,
			history_index = 0,
		}
		open = o
		kern.mode.set("insert")
		set_text(o, "")
	end,
})

kern.command({
	name = "command-line-run",
	doc = "Run what's typed on the command line",
	run = function()
		local o = open
		if o == nil then
			return
		end
		local text = o.text
		close()
		remember(text)
		execute(text)
	end,
})

kern.command({
	name = "command-line-close",
	doc = "Close the command line without running anything",
	run = close,
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
end

kern.command({
	name = "command-line-next",
	doc = "Fill in the next match on the command line",
	run = function()
		cycle(1)
	end,
})

kern.command({
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

kern.command({
	name = "command-line-older",
	doc = "Show the previous command line that starts with what's typed",
	run = function()
		step(-1)
	end,
})

kern.command({
	name = "command-line-newer",
	doc = "Show the next command line that starts with what's typed",
	run = function()
		step(1)
	end,
})

kern.command({
	name = "set",
	doc = "Set an option",
	args = {
		{ name = "option", doc = "The option to set", complete = "option" },
		{ name = "value", doc = "true, false, a number or text" },
	},
	run = function(ctx)
		local name, value = ctx.args[1], ctx.args[2]
		if name == nil or value == nil then
			error("set needs an option and a value, e.g. :set tab-width 2", 0)
		end
		local parsed: kern.OptionValue = if value == "true"
			then true
			elseif value == "false" then false
			else tonumber(value) or value
		kern.option.set(name, parsed)
	end,
})

local M = {}

--- Makes `name` run `command` on the command line, e.g. `alias("w", "save")`.
function M.alias(name: string, command: string)
	aliases[name] = command
end

--- Adds a way to complete arguments, for commands whose argument specs
--- name it in `complete`.
function M.completer(name: string, completer: complete.Completer)
	complete.register(name, completer)
end

-- The short names Vim and Helix use.
local defaults: { [string]: string } = {
	w = "save",
	write = "save",
	q = "quit",
	qa = "quit",
	quitall = "quit",
	wq = "save-quit",
	x = "save-quit",
	xit = "save-quit",
	e = "open",
	edit = "open",
	o = "open",
	h = "describe-command",
	help = "describe-command",
}
for name, command in defaults do
	M.alias(name, command)
end

kern.keymap.bind({ mode = "insert", kind = "cmdline" }, {
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

kern.keymap.bind("normal", {
	[":"] = "command-line",
})

return M
