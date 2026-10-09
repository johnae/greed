-- Your shell's aliases, so `ll` works as it does in a terminal. They're
-- read once from the shell that runs your lines (fallback.luau), with its
-- startup files, and a line starting with one has it put in place before
-- it runs; the block shows what you typed. The shell's own builtins win
-- over an alias of the same name, and `^NAME` skips the alias.

local greed = require("@greed")
local parse = require("./parse")
local state = require("./state")
local fallback = require("./fallback")

local M = {}

greed.option.define({
	name = "shell-aliases",
	doc = "Whether a line can start with one of your shell's aliases, read once from its startup files",
	default = true,
})

-- How long reading them may take, in milliseconds: startup files can be slow.
local TIMEOUT = 5000

-- The aliases once read, and what waits for them while they're read.
local known: { [string]: string }? = nil
local waiters: { greed.Signal }? = nil

-- `text` with a shell's quotes taken off: 'single', "double" and \x.
local function unquote(text: string): string
	local out: { string } = {}
	local i = 1
	while i <= #text do
		local ch = string.sub(text, i, i)
		if ch == "'" or ch == '"' then
			local close = string.find(text, ch, i + 1, true) or #text + 1
			table.insert(out, string.sub(text, i + 1, close - 1))
			i = close + 1
		elseif ch == "\\" then
			table.insert(out, string.sub(text, i + 1, i + 1))
			i += 2
		else
			table.insert(out, ch)
			i += 1
		end
	end
	return table.concat(out)
end

--- The aliases in `text`, as `alias` prints them: `alias NAME='VALUE'`
--- (bash), `NAME=VALUE` (zsh) or `alias NAME 'VALUE'` (fish), or for
--- `family` "nu" a JSON list of `{ name, expansion }`.
function M.read(text: string, family: string): { [string]: string }
	local aliases: { [string]: string } = {}
	if family == "nu" then
		local list = greed.json.decode(text)
		if type(list) == "table" then
			for _, entry in list do
				if
					type(entry) == "table"
					and type(entry.name) == "string"
					and type(entry.expansion) == "string"
					and not string.find(entry.name, " ", 1, true)
				then
					aliases[entry.name] = entry.expansion
				end
			end
		end
		return aliases
	end
	for _, line in string.split(text, "\n") do
		local rest = string.match(line, "^alias%s+(.*)$") or line
		local name, value = string.match(rest, "^([%w_.:%-]+)=(.*)$")
		if name == nil then
			name, value = string.match(rest, "^([%w_.:%-]+)%s+(.+)$")
		end
		if name and value then
			aliases[name] = unquote(value)
		end
	end
	return aliases
end

-- How to make the shell `family` list its aliases, startup files read.
local function lister(family: string): { string }?
	if family == "nu" then
		return { "nu", "-l", "-c", "scope aliases | select name expansion | to json" }
	elseif family == "fish" or family == "bash" or family == "zsh" or family == "ksh" then
		local argv: { string } = { family, "-ic", "alias" }
		return argv
	end
	return nil
end

-- Reads the aliases from the shell that runs your lines. Only in your own
-- home: a test's never reads your startup files.
local function load(): { [string]: string }
	local family = fallback.which()
	local argv = lister(family)
	local home = greed.fs.dirs().home
	if argv == nil or home == nil or home ~= state.editor_environment().HOME then
		return {}
	end
	local child = greed.process.spawn(argv, { cwd = home, group = true })
	if child == nil then
		return {}
	end
	local c = child :: greed.Child
	c:close()
	local done = false
	greed.spawn(function()
		greed.sleep(TIMEOUT)
		if not done then
			c:kill()
		end
	end)
	local parts: { string } = {}
	while true do
		local piece = c:read()
		if piece == nil then
			break
		end
		table.insert(parts, piece)
	end
	c:wait()
	done = true
	return M.read(table.concat(parts), family)
end

--- Your shell's aliases by name, read the first time they're asked for;
--- waits for that, so only in a command, handler or greed.spawn.
function M.known(): { [string]: string }
	if known then
		return known
	end
	if waiters then
		local signal = greed.signal()
		table.insert(waiters, signal)
		signal:wait()
		return known or {}
	end
	local waiting: { greed.Signal } = {}
	waiters = waiting
	local ok, found = pcall(load)
	known = if ok then found else {}
	waiters = nil
	for _, signal in waiting do
		signal:send(true)
	end
	return known or {}
end

--- The aliases if they've been read, else none, without waiting.
function M.loaded(): { [string]: string }
	return known or {}
end

--- Uses `aliases` from now on, or with nil reads your shell's again the
--- next time they're needed, as after changing its startup files.
function M.use(aliases: { [string]: string }?)
	known = aliases
end

--- `line` with its first word put in place when it's an alias, again for
--- the alias that gives, as a shell does; one that names itself, like
--- `ls='ls --color'`, isn't put in again. A `!` before it stays.
function M.expand(line: string): string
	if not greed.option.get("shell-aliases") or not coroutine.isyieldable() then
		return line
	end
	local aliases = M.known()
	local seen: { [string]: boolean } = {}
	while true do
		local lead, word, rest = string.match(line, "^(%s*!?%s*)([^%s|;&<>()'\"\\^]+)(.*)$")
		if word == nil or lead == nil or rest == nil then
			return line
		end
		local value = aliases[word]
		if value == nil or seen[word] or parse.BUILTINS[word] then
			return line
		end
		seen[word] = true
		line = lead .. value .. rest
	end
end

return M
