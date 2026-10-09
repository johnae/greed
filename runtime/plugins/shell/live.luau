-- Live blocks: `watch COMMAND` runs a command again and again, every two
-- seconds unless `-n` says otherwise, and the block shows what it printed
-- last in place of what it printed before, the lines that changed since
-- marked. Its table and what its rows are follow along, so `space .` on a
-- pod in `watch kubectl get pods` acts on that pod as it is now.
--
-- ctrl-c (or `space x`) stops it, as do closing the shell and
-- `shell-watch-minutes` going by; it ends as its last run did. `^watch`
-- runs the watch program instead, in a terminal.

local greed = require("@greed")
local state = require("./state")
local log = require("./log")
local run = require("./run")
local tables = require("./tables")
local kinds = require("./kinds")
local rows = require("./rows")
local peek = require("./peek")

type Shell = state.Shell
type Block = state.Block
type Line = log.Line

local M = {}

greed.option.define({
	name = "shell-watch-minutes",
	doc = "How long a shell's watch runs before it stops by itself, in minutes; 0 for until it's stopped",
	default = 60,
})

--- How a live block runs its command once: what it printed, its errors,
--- and how it exited (nil when it was stopped).
export type Capture = (shell: Shell, block: Block, line: string) -> (string, string, number?)

--- `line` read as `watch [-n SECONDS] COMMAND`: the command and how many
--- seconds apart it runs; nil when it isn't a watch, and nil with why when
--- it's one that can't run.
function M.read(line: string): (string?, number, string?)
	local rest = if string.match(line, "^%s*watch%s*$")
		then ""
		else string.match(line, "^%s*watch%s+(.*)$")
	if rest == nil then
		return nil, 0, nil
	end
	local every = 2
	while true do
		local seconds, after = string.match(rest, "^%-n%s*([%d.]+)%s+(.*)$")
		if seconds == nil then
			seconds, after = string.match(rest, "^%-%-interval[=%s]([%d.]+)%s+(.*)$")
		end
		if seconds and after then
			every = math.max(tonumber(seconds) or every, 0.5)
			rest = after
		else
			local flag, more = string.match(rest, "^(%-[dt])%s+(.*)$")
			if flag == nil or more == nil then
				break
			end
			-- Changes are always marked, and there's no title to leave out.
			rest = more
		end
	end
	rest = string.match(rest, "^%s*(.-)%s*$") or ""
	-- The command in quotes, as the watch program takes it, is the command.
	rest = string.match(rest, "^'([^']*)'$") or string.match(rest, '^"([^"]*)"$') or rest
	if rest == "" then
		return nil,
			every,
			"watch COMMAND runs it again every two seconds; -n SECONDS for another pace"
	end
	return rest, every, nil
end

-- `text` cut into its lines, without the empty one after its last newline.
local function split(text: string): { string }
	local lines = string.split(string.gsub(text, "\r", ""), "\n")
	if lines[#lines] == "" then
		table.remove(lines)
	end
	return lines
end

-- What each of `lines`, `block`'s output, is known by between runs: the
-- thing its row is, when a kind reads its table, as the same file or pod
-- can move up or down; else its first word and how many lines before had
-- it, as every row of `ls -l` starts alike.
local function keys_of(lines: { string }, block: Block): { string }
	local keys: { string } = {}
	local seen: { [string]: number } = {}
	local tbl = block.table
	local first = if tbl and tbl.first
		then tbl.first + (if tbl.header ~= false then 1 else 0)
		else nil
	for i, text in lines do
		local thing = if first and i >= first then kinds.thing(block, i - first + 1) else nil
		if thing then
			keys[i] = `\1{thing.kind}\0{thing.label}`
		else
			local word = string.match(text, "^%s*(%S+)") or ""
			seen[word] = (seen[word] or 0) + 1
			keys[i] = `{word}\0{seen[word]}`
		end
	end
	return keys
end

-- What `block` printed this time as the lines it shows: its output, those
-- whose key is new or whose text changed since `before` marked, then its
-- errors. Also how many changed, and the output's lines now (their words), by
-- key.
local function lines_of(
	block: Block,
	before: { [string]: string }?
): ({ Line }, number, { [string]: string })
	local lines: { Line } = {}
	local now: { [string]: string } = {}
	local changed = 0
	local out = split(block.stdout)
	for i, key in keys_of(out, block) do
		local text = out[i]
		-- Columns lined up again when one grows aren't a change.
		local words = string.gsub(text, "%s+", " ")
		local marks: { greed.Mark } = {}
		if before and before[key] ~= words then
			changed += 1
			table.insert(marks, { from = 0, to = #text, style = "shell.changed" })
		end
		now[key] = words
		table.insert(lines, { text = text, marks = marks })
	end
	for _, text in split(block.stderr) do
		table.insert(
			lines,
			{ text = text, marks = { { from = 0, to = #text, style = "shell.stderr" } } }
		)
	end
	return lines, changed, now
end

--- Runs `line` in `block` again and again, `every` seconds apart, with
--- `capture`, showing what it printed each time; it ends when stopped.
function M.start(shell: Shell, block: Block, line: string, every: number, capture: Capture)
	block.watching = line
	block.via = "shell"
	block.runner = "pipe"
	local stopped = false
	local wake: greed.Signal? = nil
	local function stop()
		stopped = true
		local waiting = wake
		if waiting then
			waiting:send(true)
		end
	end
	local own: state.Job = { interrupt = stop, kill = stop }
	block.job = own
	local minutes = greed.option.get("shell-watch-minutes") :: number
	local started = greed.now()
	greed.spawn(function()
		local before: { [string]: string }? = nil
		local code: number? = 0
		local why = "stopped"
		while not stopped do
			local out, errors
			out, errors, code = capture(shell, block, line)
			block.job = own
			if code == nil then
				break
			end
			if not shell.buffer:valid() then
				block.job = nil
				return
			end
			block.stdout, block.stderr, block.output = out, errors, out .. errors
			block.value = tables.json(out)
			block.table = tables.from_value(block.value) or tables.parse(out, line, block)
			kinds.finished(shell, block)
			local lines, changed, now = lines_of(block, before)
			before = now
			block.note = `every {every}s · {changed} changed · {os.date("%H:%M:%S")}`
			rows.renew(shell, block, lines)
			peek.follow(block)
			if minutes > 0 and greed.now() - started >= minutes * 60000 then
				why = `stopped after {minutes} minutes; space r watches again`
				break
			end
			local signal = greed.signal()
			wake = signal
			greed.spawn(function()
				greed.sleep(every * 1000)
				signal:send(true)
			end)
			signal:wait()
			wake = nil
		end
		block.note = why
		run.finish(shell, block, code, if code == nil then "INT" else nil)
	end)
end

--- A program printing what `line` prints as it comes, for `follow`, and
--- what to do once it's done.
export type Open = (shell: Shell, block: Block, line: string) -> (greed.Child?, string?, () -> ())

-- `text`'s cells: what's between runs of two spaces or more, as programs
-- that don't line their rows up with their header still keep them apart.
local function cells(text: string): { string }
	local out: { string } = {}
	for cell in string.gmatch(string.gsub(text, "%s%s+", "\0"), "[^%z]+") do
		local trimmed = string.match(cell, "^%s*(.-)%s*$") or cell
		if trimmed ~= "" then
			table.insert(out, trimmed)
		end
	end
	return out
end

-- `header` and the rows of `order`, each as `rows` has it now, as a table:
-- a row with more cells than the header has the rest in its last column.
local function stream_table(
	header: string,
	order: { string },
	texts: { [string]: string }
): tables.Table
	local columns = cells(header)
	local rows: { { [string]: string } } = {}
	for _, key in order do
		local parts = cells(texts[key])
		local row: { [string]: string } = {}
		for i, column in columns do
			row[column] = if i == #columns then table.concat(parts, "  ", i) else parts[i] or ""
		end
		table.insert(rows, row)
	end
	return { columns = columns, rows = rows }
end

--- Shows what `line`, a command printing rows again as they change (`kubectl
--- get pods -w`, as its kind says), prints as its rows: each in its place,
--- lined up under the header, those that changed since they first came
--- marked. A row is known by its first cell, or its first two under a
--- NAMESPACE column. It ends when the command does, or is stopped.
function M.follow(shell: Shell, block: Block, line: string, open: Open)
	block.watching = line
	block.via = "shell"
	block.runner = "pipe"
	local child, why, done = open(shell, block, line)
	if child == nil then
		run.fail(shell, block, why or `can't start {line}`, 127)
		return
	end
	local c = child :: greed.Child
	c:close()
	block.job = {
		interrupt = function()
			c:signal("INT")
		end,
		kill = function()
			c:kill()
		end,
	}
	greed.spawn(function()
		local header: string? = nil
		local two = false
		local order: { string } = {}
		local texts: { [string]: string } = {}
		local errors: { string } = {}
		local partial = ""
		local shown = false
		local changes = 0
		while true do
			local piece, from = c:read()
			if piece == nil then
				break
			end
			if from == "stderr" then
				table.insert(errors, piece)
				continue
			end
			partial ..= string.gsub(piece, "\r", "")
			local updated: { [string]: boolean } = {}
			while true do
				local stop = string.find(partial, "\n", 1, true)
				if stop == nil then
					break
				end
				local text = string.sub(partial, 1, stop - 1)
				partial = string.sub(partial, stop + 1)
				if header == nil then
					header = text
					two = string.match(text, "^%s*NAMESPACE%s") ~= nil
				elseif text ~= header and string.match(text, "%S") then
					local key = if two
						then string.match(text, "^%s*(%S+%s+%S+)")
						else string.match(text, "^%s*(%S+)")
					local at: string = key or text
					if texts[at] == nil then
						table.insert(order, at)
					end
					if shown and texts[at] ~= text then
						updated[at] = true
						changes += 1
					end
					texts[at] = text
				end
			end
			local head = header
			if head and #order > 0 and shell.buffer:valid() then
				local tbl = stream_table(head, order, texts)
				local drawn, starts = tables.draw(tbl)
				tbl.starts, tbl.first, tbl.header = starts, 1, true
				block.table = tbl
				block.stdout = table.concat(drawn, "\n") .. "\n"
				block.stderr = table.concat(errors)
				block.output = block.stdout .. block.stderr
				kinds.finished(shell, block)
				local lines: { Line } = {}
				for i, text in drawn do
					local key = order[i - 1]
					local marked = key and updated[key]
					local marks: { greed.Mark } = if marked
						then { { from = 0, to = #text, style = "shell.changed" } }
						else {}
					table.insert(lines, { text = text, marks = marks })
				end
				for _, text in split(block.stderr) do
					table.insert(lines, {
						text = text,
						marks = { { from = 0, to = #text, style = "shell.stderr" } },
					})
				end
				block.note = `{changes} changed · {os.date("%H:%M:%S")}`
				rows.renew(shell, block, lines)
				peek.follow(block)
				shown = true
			end
		end
		local code, signal = c:wait()
		done()
		run.finish(shell, block, code, signal)
	end)
end

return M
