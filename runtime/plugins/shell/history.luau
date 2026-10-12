-- The commands typed at every shell, newest last, kept in the data folder
-- as one JSON object a line ({data}/shell/history.jsonl), so they're there
-- after a restart and in every session. `up` and `down` at the prompt go
-- through those starting with what's typed; ctrl-r picks one.

local greed = require("@greed")

local M = {}

greed.option.define({
	name = "shell-history-size",
	doc = "How many commands typed at shells are kept",
	default = 5000,
})

--- A command typed at a shell: what, in which folder, and when (seconds
--- since 1970).
export type Entry = { command: string, cwd: string, time: number }

-- The entries, oldest first, once read.
local entries: { Entry }? = nil

--- Where the history is kept; nil without a data folder.
function M.path(): string?
	local data = greed.fs.dirs().data
	return if data then `{data}/shell/history.jsonl` else nil
end

-- The entries in `text`, one JSON object a line; lines that aren't one
-- are skipped.
local function parse(text: string): { Entry }
	local list: { Entry } = {}
	for _, line in string.split(text, "\n") do
		if line ~= "" then
			local entry = greed.json.decode(line)
			if type(entry) == "table" and type(entry.command) == "string" then
				table.insert(list, {
					command = entry.command,
					cwd = if type(entry.cwd) == "string" then entry.cwd else "",
					time = if type(entry.time) == "number" then entry.time else 0,
				})
			end
		end
	end
	return list
end

-- The file's entries now, which other sessions may have added to.
local function read(): { Entry }
	local path = M.path()
	if path == nil then
		return {}
	end
	local file: string = path
	-- The file is the shell's own, whichever plugin ran the line (greed.vouch).
	local text = greed.vouch(function()
		return greed.fs.read(file)
	end)
	return if text then parse(text) else {}
end

--- Every command kept, oldest first.
function M.entries(): { Entry }
	if entries == nil then
		entries = read()
	end
	return entries :: { Entry }
end

--- Keeps `command`, typed in `cwd`, at the end of the history, and writes
--- the file again with what other sessions added meanwhile, up to
--- `shell-history-size` commands.
function M.add(command: string, cwd: string)
	local entry: Entry = { command = command, cwd = cwd, time = os.time() }
	local list = read()
	table.insert(list, entry)
	local size = math.max(greed.option.get("shell-history-size") :: number, 1)
	if #list > size then
		list = table.move(list, #list - size + 1, #list, 1, {})
	end
	entries = list
	local path = M.path()
	if path == nil then
		return
	end
	local file: string = path
	local lines = table.create(#list)
	for i, e in list do
		lines[i] = greed.json.encode(e)
	end
	greed.vouch(function()
		greed.fs.write(file, table.concat(lines, "\n") .. "\n", { private = true })
	end)
end

--- The commands kept, newest first, each once.
function M.commands(): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	local list = M.entries()
	for i = #list, 1, -1 do
		local command = list[i].command
		if not seen[command] then
			seen[command] = true
			table.insert(out, command)
		end
	end
	return out
end

--- The newest command that starts with `typed` and goes on past it, on one
--- line, to suggest as it's typed; nil when there's none.
function M.suggest(typed: string): string?
	if typed == "" then
		return nil
	end
	local list = M.entries()
	for i = #list, 1, -1 do
		local command = list[i].command
		if
			#command > #typed
			and string.sub(command, 1, #typed) == typed
			and not string.find(command, "\n", 1, true)
		then
			return command
		end
	end
	return nil
end

--- `line` with a shell's history expansion: `!!` is `previous`, `!$` its
--- last word, and a line `^old^new` is `previous` with the first `old`
--- changed to `new`. Single quotes keep `!` as it is, and an `old` with
--- spaces at its ends is a `^NAME` command instead. Nil and why when
--- there's nothing to expand from or `old` isn't in `previous`.
function M.expand(line: string, previous: string?): (string?, string?)
	local old, new = string.match(line, "^%^([^%s^][^^]-)%^([^^]*)%^?$")
	if old and new and not string.match(old, "%s$") then
		if previous == nil then
			return nil, "there's no command before to change"
		end
		local at = string.find(previous, old, 1, true)
		if at == nil then
			return nil, `{old} isn't in {previous}`
		end
		return string.sub(previous, 1, at - 1) .. new .. string.sub(previous, at + #old), nil
	end
	local out: { string } = {}
	local quoted = false
	local i = 1
	while i <= #line do
		local ch = string.sub(line, i, i)
		local after = string.sub(line, i + 1, i + 1)
		if ch == "'" then
			quoted = not quoted
		elseif not quoted and ch == "!" and (after == "!" or after == "$") then
			if previous == nil then
				return nil, `there's no command before for !{after}`
			end
			table.insert(
				out,
				if after == "!" then previous else string.match(previous, "(%S+)%s*$") or ""
			)
			i += 2
			continue
		end
		table.insert(out, ch)
		i += 1
	end
	return table.concat(out), nil
end

return M
