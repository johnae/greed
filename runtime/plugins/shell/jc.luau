-- jc (https://github.com/kellyjonbrazil/jc) reads the output of many
-- commands as JSON: ifconfig, dig, mount, uptime and a hundred more. When
-- it's installed, a block of one of those commands the shell found no
-- table in gets jc's reading of what it printed. The command isn't run
-- again; jc only reads its output.

local greed = require("@greed")
local tables = require("./tables")

local M = {}

-- The arguments jc reads each command's output with ("uptime" to
-- "--uptime"), for each jc program, from `jc -a`.
local known: { [string]: { [string]: string } } = {}

--- The program `name` in one of the folders of `path`, if it's there.
function M.find(name: string, path: string?): string?
	for dir in string.gmatch(path or "", "[^:]+") do
		local candidate = `{dir}/{name}`
		local info = greed.fs.stat(candidate)
		if info and info.kind ~= "dir" then
			return candidate
		end
	end
	return nil
end

-- What jc at `program` reads, by command.
local function parsers(program: string): { [string]: string }
	local found = known[program]
	if found then
		return found
	end
	local commands: { [string]: string } = {}
	local result = greed.process.run({ program, "-a" })
	local about = if result and result.code == 0 then greed.json.decode(result.stdout) else nil
	if type(about) == "table" and type(about.parsers) == "table" then
		for _, parser in about.parsers do
			if type(parser) == "table" and type(parser.argument) == "string" then
				for _, command in
					if type(parser.magic_commands) == "table" then parser.magic_commands else {}
				do
					if type(command) == "string" then
						commands[command] = parser.argument
					end
				end
			end
		end
	end
	known[program] = commands
	return commands
end

-- The argument jc reads `command`'s output with: for the longest of the
-- commands it knows that the line starts with, its program named without
-- its folder.
local function argument(commands: { [string]: string }, command: string): string?
	local line = string.gsub(command, "^%s*sudo%s+", "")
	line = string.gsub(line, "^%S*/", "")
	local best: string?, longest = nil, 0
	for name, arg in commands do
		local starts = string.sub(line, 1, #name) == name
		local whole = #line == #name
			or string.match(string.sub(line, #name + 1, #name + 1), "%s") ~= nil
		if starts and whole and #name > longest then
			best, longest = arg, #name
		end
	end
	return best
end

--- `text`, what `command` printed, as jc reads it, when jc is on `path`
--- and knows the command. It runs jc, so it waits.
function M.parse(text: string, command: string, path: string?): tables.Table?
	local program = M.find("jc", path)
	if program == nil then
		return nil
	end
	local arg = argument(parsers(program), command)
	if arg == nil then
		return nil
	end
	local result = greed.process.run({ program, arg }, { stdin = text })
	if result == nil or result.code ~= 0 then
		return nil
	end
	return tables.from_json(result.stdout)
end

return M
