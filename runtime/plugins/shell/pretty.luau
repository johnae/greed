-- JSON lines, as many programs log (`kubectl logs` of a Go service,
-- `docker logs`), shown readably: each line's time, level and message
-- first, the other fields after it, dimmed. The buffer keeps each line as
-- it came, so a filter (`level=error`), copying and `$3` see the JSON. Even
-- the line the cursor is on stays readable, as a followed log keeps the
-- cursor on its newest line; `shell-pretty` shows them as they came.

local greed = require("@greed")
local state = require("./state")
local log = require("./log")

type Shell = state.Shell
type Block = state.Block

local M = {}

greed.option.define({
	name = "shell-json-lines",
	doc = 'How a block whose lines are JSON objects, as many logs are, shows them: "pretty" (time, level and message first, the other fields after) or "raw"',
	default = "pretty",
	choices = { "pretty", "raw" },
})

-- The fields a line's time, level and message are in, the likeliest first.
local TIME = { "ts", "time", "timestamp", "@timestamp", "t" }
local LEVEL = { "level", "lvl", "severity", "levelname", "log.level" }
local MESSAGE = { "msg", "message", "@message", "M" }

-- The style of each level, by how logs spell it.
local LEVELS: { [string]: string } = {
	error = "shell.log.error",
	err = "shell.log.error",
	fatal = "shell.log.error",
	panic = "shell.log.error",
	critical = "shell.log.error",
	crit = "shell.log.error",
	warn = "shell.log.warn",
	warning = "shell.log.warn",
	info = "shell.log.info",
	notice = "shell.log.info",
	debug = "shell.log.debug",
	trace = "shell.log.debug",
}

-- The object `text` is, if it's a line of JSON with one.
local function object(text: string): { [string]: any }?
	if string.sub(text, 1, 1) ~= "{" then
		return nil
	end
	local value = greed.json.decode(text)
	return if type(value) == "table" then value else nil
end

-- The first of `names` that `fields` has, taken out of it.
local function take(fields: { [string]: any }, names: { string }): any
	for _, name in names do
		local value = fields[name]
		if value ~= nil then
			fields[name] = nil
			return value
		end
	end
	return nil
end

-- A time as a log line shows it: the time of day of an ISO time, or of
-- seconds (or milliseconds) since 1970.
local function clock(time: any): string
	if type(time) == "number" then
		local seconds: number = if time > 1e11 then time // 1000 else time // 1
		local format: string = "!%H:%M:%S"
		return os.date(format, seconds)
	end
	local text = tostring(time)
	return string.match(text, "[T ](%d%d:%d%d:%d%d)") or text
end

-- A field's value as text: as it is, quoted with spaces in it, objects and
-- arrays as JSON.
local function shown(value: any): string
	if type(value) == "table" then
		return greed.json.encode(value)
	end
	local text = tostring(value)
	return if string.find(text, "%s") then string.format("%q", text) else text
end

-- Adds `fields` to `into` as `name=value`, by name, those of an object in
-- them as `object.name=value`, as a filter names them.
local function flatten(fields: { [string]: any }, prefix: string, into: { string })
	local names: { string } = {}
	for name in fields do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		local value = fields[name]
		-- An object, but not an array or one with nothing in it.
		if type(value) == "table" and next(value) ~= nil and value[1] == nil then
			flatten(value, `{prefix}{name}.`, into)
		else
			table.insert(into, `{prefix}{name}={shown(value)}`)
		end
	end
end

--- The marks showing the JSON object on `text` readably, from its start,
--- or nil for a line that isn't one with a time, level or message.
function M.marks(text: string): { greed.Mark }?
	local fields = object(text)
	if fields == nil then
		return nil
	end
	local time, level, message = take(fields, TIME), take(fields, LEVEL), take(fields, MESSAGE)
	if time == nil and level == nil and message == nil then
		return nil
	end
	-- What shows in place of the line, in order, each piece with its style.
	local pieces: { { text: string, style: string } } = {}
	if time ~= nil then
		table.insert(pieces, { text = clock(time) .. " ", style = "shell.log.time" })
	end
	if level ~= nil then
		local name = string.lower(tostring(level))
		table.insert(
			pieces,
			{ text = string.format("%-5s ", name), style = LEVELS[name] or "shell.log.field" }
		)
	end
	if message ~= nil then
		table.insert(pieces, { text = tostring(message), style = "shell.log.message" })
	end
	local rest: { string } = {}
	flatten(fields, "", rest)
	if #rest > 0 then
		local gap = if message ~= nil then "  " else ""
		table.insert(pieces, { text = gap .. table.concat(rest, " "), style = "shell.log.field" })
	end
	-- Each piece hides a character of the line, the last the rest of it, so
	-- they all go with the line: a mark whose text is deleted goes too. A
	-- JSON object has at least as many characters as there are pieces.
	local marks: { greed.Mark } = {}
	for i, piece in pieces do
		local to = if i == #pieces then #text else i
		table.insert(marks, {
			from = i - 1,
			to = to,
			style = piece.style,
			text = piece.text,
			conceal = true,
			reveal = "never" :: "never",
		})
	end
	-- A line a row, as `tail` shows a log: the fields after the message
	-- go past the edge, rather than wrapping under it.
	marks[1].nowrap = true
	return marks
end

local function ns(block: Block): string
	return `shell.pretty.{block.uid}`
end

-- Whether `block` shows its lines readably, deciding on its first line.
local function pretty(block: Block, lines: { log.Line }): boolean
	if block.pretty == nil then
		for _, line in lines do
			if line.text ~= "" then
				block.pretty = greed.option.get("shell-json-lines") == "pretty"
					and object(line.text) ~= nil
				break
			end
		end
	end
	return block.pretty == true
end

-- Shows `lines` of `block`, put in the buffer from `from` on, readably;
-- whether any of them are shown so.
local function place(shell: Shell, block: Block, from: number, lines: { log.Line }): boolean
	if not pretty(block, lines) then
		return false
	end
	local marks: { greed.Mark } = {}
	local at = from
	for _, line in lines do
		for _, mark in M.marks(line.text) or ({} :: { greed.Mark }) do
			mark.from += at
			mark.to += at
			table.insert(marks, mark)
		end
		at += #line.text + 1
	end
	shell.buffer:decorate(ns(block), marks, { from = from, to = at })
	return #marks > 0
end

log.on_placed(function(shell, block, from, lines)
	place(shell, block, from, lines)
end)

--- Shows `block`'s JSON lines readably, or as they came; whether any show
--- readably.
function M.set(shell: Shell, block: Block, on: boolean): boolean
	block.pretty = on
	local from = log.output_range(shell, block)
	shell.buffer:decorate(ns(block), {})
	if not on or from == nil then
		return not on
	end
	local shown_any = place(shell, block, from, log.output_lines(shell, block))
	block.pretty = shown_any
	return shown_any
end

return M
