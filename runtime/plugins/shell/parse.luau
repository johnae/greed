-- Reading a line typed at a shell's prompt: a builtin the shell runs
-- itself, or anything else, which goes to a real shell (your own, or `sh`
-- for an agent). A leading `!` runs the line in a terminal.
--
-- Data from the editor goes in at the start of a line, `$3 | sort` (block
-- 3's output), `buf:NAME | wc -l`, `@sel | jq .` or `@file | head`, and
-- `... > buf:NAME` (or `>>` to add to it) sends what a command prints to a
-- buffer. One of those alone, like `$3 > buf:keep`, passes it on as it is.

local M = {}

--- A command the shell runs itself: how it's typed, what it does, and
--- what its arguments are, for completion: "folder", "path" (files and
--- `buf:` buffers), "assignment" (NAME=VALUE), "variable" or "topic" (of
--- `help`); nil for none. `help`, completion and the shell's page in the
--- docs all show these. `plugin` is the plugin that added it, for those
--- not the shell's own.
export type Builtin = { usage: string, doc: string, args: string?, plugin: string? }

--- The commands the shell runs itself, by name.
M.BUILTINS = {
	cd = {
		usage = "cd [DIR]",
		doc = "Change the shell's folder: a path, `-` for the one before, nothing for home",
		args = "folder",
	},
	export = {
		usage = "export NAME=VALUE ...",
		doc = "Set variables for the commands after",
		args = "assignment",
	},
	unset = {
		usage = "unset NAME ...",
		doc = "Leave variables out of the commands after",
		args = "variable",
	},
	env = {
		usage = "env [reload]",
		doc = "List the variables this shell sets or leaves out, and the environment its folder brings (devenv, direnv); reload loads that again",
	},
	history = { usage = "history", doc = "The commands typed before" },
	clear = { usage = "clear", doc = "Take the finished blocks away" },
	open = {
		usage = "open PATH ...",
		doc = "Open files, or `buf:NAME` buffers, in the editor",
		args = "path",
	},
	help = {
		usage = "help [TOPIC]",
		doc = "What works here, and the keys in the style you use; a topic for one part",
		args = "topic",
	},
	which = {
		usage = "which NAME ...",
		doc = "What a word at the start of a line runs: a builtin, a table stage, one of your aliases or a program",
	},
	watch = {
		usage = "watch [-n SECONDS] COMMAND",
		doc = "Run a command again and again, every two seconds, its block showing what it printed last with the changes marked",
	},
} :: { [string]: Builtin }

--- The parts of `help`, each a topic `help TOPIC` shows alone.
M.HELP_TOPICS = {
	{ name = "builtins", about = "what the shell runs itself" },
	{ name = "line", about = "what the shell reads in a line" },
	{ name = "tables", about = "filtering blocks, and tables after $3 |" },
	{ name = "prompt", about = "what the prompt shows before the folder" },
	{ name = "keys", about = "the keys in the style you use" },
}

--- The builtins' names, in order.
function M.builtin_names(): { string }
	local names: { string } = {}
	for name in M.BUILTINS do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

--- What a line asks for.
--- - "empty": nothing but spaces.
--- - "builtin": `name` with `args`.
--- - "argv": a program and its arguments, quotes taken off.
--- - "shell": anything else, for a real shell to run as `line`.
--- - "source": nothing but `input`, to pass on.
--- `terminal` is true for a line typed with a leading `!`, whose `line` is
--- the rest. `input` is what goes to the command's input (`$3`, `buf:NAME`,
--- `@sel` or `@file`), and `into` the buffer its output goes to. `error`
--- says why a line can't be read, like an unclosed quote. `raw` is true
--- for a command typed `^NAME`, which runs the program NAME even where the
--- shell has a builtin or table stage of that name; `line` is without the
--- `^`.
export type Parsed = {
	kind: "empty" | "builtin" | "argv" | "shell" | "source",
	line: string,
	name: string?,
	args: { string }?,
	argv: { string }?,
	terminal: boolean,
	input: string?,
	into: Into?,
	error: string?,
	raw: boolean?,
}

--- A buffer a command's output goes to: `> buf:NAME`, or with `append`
--- `>> buf:NAME`.
export type Into = { name: string, append: boolean }

--- Whether `word` names data from the editor a command can read: `$3`,
--- `buf:NAME`, `@sel` or `@file`.
function M.is_source(word: string): boolean
	return string.match(word, "^%$%d+$") ~= nil
		or string.match(word, "^buf:[^%s|<>]+$") ~= nil
		or word == "@sel"
		or word == "@file"
end

-- Characters that mean something to a shell outside quotes, so a line with
-- one needs a real shell.
local SPECIAL = "[|&;<>()$`*?%[%]{}#]"

-- Splits `line` into words the way a shell would for plain arguments:
-- spaces separate them, quotes and backslashes keep characters together.
-- Returns nil and false when the line needs a real shell (an unquoted
-- special character, a variable inside double quotes, a line break), or
-- nil and a message when a quote isn't closed.
function M.words(line: string, home: string?): ({ string }?, (string | boolean)?)
	local words: { string } = {}
	local word: { string }? = nil
	local i = 1
	local n = #line
	while i <= n do
		local ch = string.sub(line, i, i)
		if ch == "\n" then
			return nil, false
		elseif ch == " " or ch == "\t" then
			if word then
				table.insert(words, table.concat(word))
				word = nil
			end
			i += 1
		elseif ch == "'" then
			local close = string.find(line, "'", i + 1, true)
			if close == nil then
				return nil, "a ' isn't closed"
			end
			word = word or {}
			table.insert(word :: { string }, string.sub(line, i + 1, close - 1))
			i = close + 1
		elseif ch == '"' then
			local parts = word or {}
			local j = i + 1
			local closed = false
			while j <= n do
				local c = string.sub(line, j, j)
				if c == '"' then
					closed = true
					break
				elseif c == "$" or c == "`" then
					return nil, false
				elseif c == "\\" then
					local after = string.sub(line, j + 1, j + 1)
					if after == '"' or after == "\\" or after == "$" or after == "`" then
						table.insert(parts, after)
						j += 2
					else
						table.insert(parts, c)
						j += 1
					end
				else
					table.insert(parts, c)
					j += 1
				end
			end
			if not closed then
				return nil, "a \" isn't closed"
			end
			word = parts
			i = j + 1
		elseif ch == "\\" then
			if i == n then
				return nil, false
			end
			word = word or {}
			table.insert(word :: { string }, string.sub(line, i + 1, i + 1))
			i += 2
		elseif string.match(ch, SPECIAL) then
			return nil, false
		elseif ch == "~" and word == nil then
			-- `~` and `~/...` are home; `~user` is left to a real shell.
			local after = string.sub(line, i + 1, i + 1)
			if
				home == nil or not (after == "" or after == "/" or after == " " or after == "\t")
			then
				return nil, false
			end
			word = { home }
			i += 1
		else
			word = word or {}
			table.insert(word :: { string }, ch)
			i += 1
		end
	end
	if word then
		table.insert(words, table.concat(word))
	end
	return words, nil
end

-- `line` without a `> buf:NAME` or `>> buf:NAME` at its end, and that.
local function split_into(line: string): (string, Into?)
	local before, arrow, name = string.match(line, "^(.-)%s*(>>?)%s*buf:([%w_.%-/]+)$")
	if before == nil or arrow == nil or name == nil then
		return line, nil
	end
	return before, { name = name, append = arrow == ">>" }
end

-- `line` without a `SOURCE |` at its start, and that source.
local function split_input(line: string): (string, string?)
	local first, rest = string.match(line, "^(%S+)%s*|%s*(.*)$")
	if first == nil or rest == nil or string.sub(rest, 1, 1) == "|" or not M.is_source(first) then
		return line, nil
	end
	return rest, first
end

-- Reads a command without data going in or out of it.
local function parse_command(line: string, terminal: boolean, home: string?): Parsed
	local raw = string.match(line, "^%^[^%s^]") ~= nil
	local rest = if raw then string.sub(line, 2) else line
	local words, why = M.words(rest, home)
	if words == nil then
		local err = if type(why) == "string" then why else nil
		return { kind = "shell", line = rest, terminal = terminal, error = err, raw = raw }
	end
	local first = words[1]
	-- `NAME=value program` sets a variable for one program; a shell does that.
	if string.find(first, "=", 1, true) then
		return { kind = "shell", line = rest, terminal = terminal, raw = raw }
	end
	if M.BUILTINS[first] and not terminal and not raw then
		local args = table.clone(words)
		table.remove(args, 1)
		return { kind = "builtin", line = rest, name = first, args = args, terminal = false }
	end
	return { kind = "argv", line = rest, argv = words, terminal = terminal, raw = raw }
end

--- Reads `line`, typed at a prompt. `home` expands a leading `~`.
function M.parse(line: string, home: string?): Parsed
	local terminal = false
	local rest = string.match(line, "^%s*(.-)%s*$") or ""
	if string.sub(rest, 1, 1) == "!" then
		terminal = true
		rest = string.match(string.sub(rest, 2), "^%s*(.-)$") or ""
	end
	if rest == "" then
		return { kind = "empty", line = rest, terminal = terminal }
	end
	local into: Into?, input: string? = nil, nil
	rest, into = split_into(rest)
	rest, input = split_input(rest)
	if into or input then
		local why: string? = nil
		if terminal then
			why = "! runs a line in a terminal, which can't read or write buffers"
		elseif rest == "" then
			why = if input then "nothing after |" else "nothing to write to the buffer"
		end
		if why then
			return { kind = "shell", line = rest, terminal = terminal, error = why }
		end
	end
	if input == nil and not terminal and M.is_source(rest) then
		return { kind = "source", line = rest, terminal = false, input = rest, into = into }
	end
	local parsed = parse_command(rest, terminal, home)
	parsed.input = input
	parsed.into = into
	return parsed
end

--- `name=value` split in two, or nil when `text` isn't an assignment to a
--- valid name.
function M.assignment(text: string): (string?, string?)
	local name, value = string.match(text, "^([%a_][%w_]*)=(.*)$")
	return name, value
end

--- Whether `name` can be an environment variable's name.
function M.valid_name(name: string): boolean
	return string.match(name, "^[%a_][%w_]*$") ~= nil
end

--- `text` quoted for a POSIX shell, so it's one word.
function M.quote(text: string): string
	if text ~= "" and string.match(text, "^[%w_./:=@%%+,-]+$") then
		return text
	end
	return "'" .. string.gsub(text, "'", "'\\''") .. "'"
end

return M
