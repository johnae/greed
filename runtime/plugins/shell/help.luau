-- The `help` builtin: what the shell runs itself, what it reads in a line,
-- tables, the prompt and the keys, by topic.

local greed = require("@greed")
local core = require("@core")
local parse = require("./parse")
local state = require("./state")
local run = require("./run")
local fallback = require("./fallback")
local tables = require("./tables")
local segments = require("./segments")

type Shell = state.Shell
type Block = state.Block

local M = {}

-- The keys `help` lists, in the vscode style and in the others.
local HELP_KEYS = {
	vscode = {
		{ "enter", "run what's at the prompt; alt-enter starts another line" },
		{ "esc", "blocks mode: up and down between commands, right into rows, a key to act" },
		{ "up  down", "commands typed before, starting with what's typed" },
		{ "right  end", "take the rest of the command the prompt suggests" },
		{ "ctrl-r", "pick a command typed before" },
		{ "tab", "complete a program, its flags, a file, $3, buf:; again for each in the menu" },
		{ "ctrl-c", "copy a selection, or interrupt the running block" },
		{ "ctrl-t", "type into the running block's program" },
		{ "ctrl-up  ctrl-down", "the block before or after the cursor" },
		{ "f8  shift-f8", "the next or previous file:line the output names" },
		{ "ctrl-space r  R", "run the block again, as it ran or here" },
		{ "ctrl-space C", "change the block's command, run in its place" },
		{ "ctrl-space y  Y", "copy its output or its command" },
		{ "ctrl-space x  v  c", "stop it, open its output, clear finished blocks" },
		{ "ctrl-f", "keep a block's lines with what's typed, or a table's rows (COL=VALUE)" },
		{ "ctrl-space s  S", "sort a table by the column here; show it as it came" },
	},
	other = {
		{ "enter", "run what's at the prompt; on a block, edit its command" },
		{ "esc", "blocks mode: up and down between commands, right into rows, a key to act" },
		{ "up  down", "commands typed before, starting with what's typed" },
		{ "right  end", "take the rest of the command the prompt suggests" },
		{ "ctrl-r", "pick a command typed before" },
		{ "tab", "complete a program, its flags, a file, $3, buf:; again for each in the menu" },
		{ "ctrl-c", "interrupt the running block" },
		{ "ctrl-t", "type into the running block's program" },
		{ "[ p  ] p", "the block before or after the cursor (normal mode)" },
		{ "] e  [ e", "the next or previous file:line the output names" },
		{ "g o", "select the block's output" },
		{ "space r  R", "run the block again, as it ran or here" },
		{ "space C", "change the block's command, run in its place" },
		{ "space y  Y", "copy its output or its command" },
		{ "space x  v  c", "stop it, open its output, clear finished blocks" },
		{ "/", "keep a block's lines with what's typed, or a table's rows (COL=VALUE)" },
		{ "space s  S", "sort a table by the column here; show it as it came" },
	},
}

-- Adds `rows` to `lines` as two columns, the first padded to line the
-- second up.
local function add_columns(lines: { string }, rows: { { string } })
	local wide = 0
	for _, row in rows do
		wide = math.max(wide, core.text.width(row[1]))
	end
	for _, row in rows do
		table.insert(lines, `  {row[1]}{string.rep(" ", wide - core.text.width(row[1]))}  {row[2]}`)
	end
end

-- The lines of each part of `help` (parse.HELP_TOPICS), by topic.
local TOPICS: { [string]: () -> { string } } = {
	builtins = function()
		local rows: { { string } } = {}
		for _, name in parse.builtin_names() do
			local builtin = parse.BUILTINS[name]
			table.insert(rows, { builtin.usage, builtin.doc })
		end
		local lines = { "Run by the shell itself:" }
		add_columns(lines, rows)
		local program, carries = fallback.which()
		local carry = if carries
			then "cd and export there carry over"
			else "cd and export there don't carry over"
		table.insert(lines, "")
		table.insert(
			lines,
			`Everything else runs in {program} ({carry}); :set shell-fallback picks another.`
		)
		return lines
	end,
	line = function()
		local lines = { "Read by the shell in a line:" }
		add_columns(lines, {
			{ "$3 | cmd", "block 3's output as cmd's input; $3 alone shows it again" },
			{ "buf:NAME | cmd", "a buffer's text as input; open buf:NAME shows it" },
			{ "@sel | cmd", "the selection in the file you're in" },
			{ "@file | cmd", "the file you're in" },
			{ "cmd > buf:NAME", "cmd's output into a buffer; >> adds to it" },
			{ "!cmd", "run cmd in a terminal from the start" },
			{ "? question", "ask a model for a command, put at the prompt to run" },
			{ "cmd ? question", "the same, starting from what's typed; or end with ?" },
		})
		return lines
	end,
	tables = function()
		local lines = {
			"/ on a block's output keeps the lines with what's typed (/ again for a regex);",
			"in a table, COL=VALUE, COL~TEXT and COL>N look in a column.",
			"",
			"Run by the shell on a table, or on text to make one, after $3 |:",
		}
		local rows: { { string } } = {}
		for _, stage in tables.STAGES do
			table.insert(rows, { stage.usage, stage.doc })
		end
		add_columns(lines, rows)
		return lines
	end,
	prompt = function()
		local lines = { "Before the folder, the prompt shows:" }
		add_columns(lines, {
			{ "⎇ main", "the branch of the repository the shell is in" },
			{ "❄ devenv", "the environment the folder brings (env says more)" },
		})
		local production = greed.option.get("shell-production-contexts")
		table.insert(lines, "")
		table.insert(
			lines,
			`A segment that warns, like a context matching shell-production-contexts ({production}), shows in red, and so does ❯.`
		)
		table.insert(lines, "")
		table.insert(
			lines,
			"Above it, a line for each running block before the last: enter there opens the block in a float, and its keys (ctrl-c, space x, /) act on it."
		)
		local others: { string } = {}
		for _, name in segments.names() do
			if name ~= "git" and name ~= "environment" then
				table.insert(others, name)
			end
		end
		if #others > 0 then
			table.insert(lines, `From plugins: {table.concat(others, ", ")}.`)
		end
		return lines
	end,
	keys = function()
		local style = core.style.current().name
		local lines = { `Keys ({style} style):` }
		add_columns(lines, if style == "vscode" then HELP_KEYS.vscode else HELP_KEYS.other)
		return lines
	end,
}

-- The topics' names, for saying which there are.
local function topic_names(): string
	local names: { string } = {}
	for _, topic in parse.HELP_TOPICS do
		table.insert(names, topic.name)
	end
	return table.concat(names, ", ")
end

--- The page `help` prints: what the shell runs itself and which shell runs
--- the rest, what it reads in a line, tables, and the keys in the style in
--- use; with `topic`, only that part. Nil for a topic it doesn't know.
function M.help(topic: string?): string?
	local lines: { string } = {}
	for _, part in parse.HELP_TOPICS do
		if topic == nil or topic == part.name then
			if #lines > 0 then
				table.insert(lines, "")
			end
			local more = TOPICS[part.name]()
			table.move(more, 1, #more, #lines + 1, lines)
		end
	end
	if #lines == 0 then
		return nil
	end
	if topic == nil then
		table.insert(lines, "")
		table.insert(lines, `help TOPIC shows one part: {topic_names()}.`)
		table.insert(lines, "The shell page in Greed's docs has the rest.")
	end
	return table.concat(lines, "\n") .. "\n"
end

run.builtins.help = function(shell: Shell, block: Block, args: { string }): number
	local page = M.help(args[1])
	if page == nil then
		run.write(shell, block, `help: no topic {args[1]}; there's {topic_names()}\n`, "stderr")
		return 1
	end
	run.write(shell, block, page, "stdout")
	return 0
end

return M
