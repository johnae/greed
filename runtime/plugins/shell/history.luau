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
	local text = if path then greed.fs.read(path) else nil
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
	local lines = table.create(#list)
	for i, e in list do
		lines[i] = greed.json.encode(e)
	end
	greed.fs.write(path, table.concat(lines, "\n") .. "\n", { private = true })
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

--- Where a shell is in going through the history: the text typed before
--- it started, which commands it goes through, the one shown and the text
--- it put at the prompt.
export type Walk = {
	typed: string,
	matches: { string },
	index: number,
	shown: string,
}

--- A walk through the commands starting with `typed`, newest first.
function M.walk(typed: string): Walk
	local matches: { string } = {}
	for _, command in M.commands() do
		if command ~= typed and string.sub(command, 1, #typed) == typed then
			table.insert(matches, command)
		end
	end
	return { typed = typed, matches = matches, index = 0, shown = typed }
end

--- The command `step` (1 older, -1 newer) from where `walk` is, or what
--- was typed past the newest; nil past the oldest.
function M.step(walk: Walk, step: number): string?
	local index = walk.index + step
	if index > #walk.matches then
		return nil
	end
	walk.index = math.max(index, 0)
	walk.shown = if walk.index == 0 then walk.typed else walk.matches[walk.index]
	return walk.shown
end

return M
