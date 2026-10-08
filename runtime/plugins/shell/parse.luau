-- Reading a line typed at a shell's prompt: a builtin the shell runs
-- itself, a program with plain arguments it starts on its own, or anything
-- else (pipes, globs, variables, redirects), which goes to a real shell.
-- A leading `!` runs the line in a terminal.

local M = {}

--- The commands the shell runs itself.
M.BUILTINS = {
	cd = "Change the shell's folder: a path, `-` for the one before, nothing for home",
	export = "Set environment variables for the commands after: NAME=VALUE ...",
	unset = "Leave environment variables out of the commands after: NAME ...",
	env = "List the variables this shell sets or leaves out",
	history = "List the commands typed before",
	clear = "Remove every block",
	open = "Open files in the editor: PATH ...",
} :: { [string]: string }

--- What a line asks for.
--- - "empty": nothing but spaces.
--- - "builtin": `name` with `args`.
--- - "argv": a program and its arguments, quotes taken off.
--- - "shell": anything else, for a real shell to run as `line`.
--- `terminal` is true for a line typed with a leading `!`, whose `line` is
--- the rest. `error` says why a line can't be read, like an unclosed quote.
export type Parsed = {
	kind: "empty" | "builtin" | "argv" | "shell",
	line: string,
	name: string?,
	args: { string }?,
	argv: { string }?,
	terminal: boolean,
	error: string?,
}

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
	local words, why = M.words(rest, home)
	if words == nil then
		local err = if type(why) == "string" then why else nil
		return { kind = "shell", line = rest, terminal = terminal, error = err }
	end
	local first = words[1]
	-- `NAME=value program` sets a variable for one program; a shell does that.
	if string.find(first, "=", 1, true) then
		return { kind = "shell", line = rest, terminal = terminal }
	end
	if M.BUILTINS[first] and not terminal then
		local args = table.clone(words)
		table.remove(args, 1)
		return { kind = "builtin", line = rest, name = first, args = args, terminal = false }
	end
	return { kind = "argv", line = rest, argv = words, terminal = terminal }
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
