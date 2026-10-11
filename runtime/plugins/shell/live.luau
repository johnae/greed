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

-- A row (or line) of a live block's output as it was on one run: what it's
-- called, its cells and the columns that change by themselves when it's a
-- table's row, and its words.
type Seen = {
	label: string,
	cells: { [string]: string }?,
	columns: { string }?,
	ticking: { [string]: boolean }?,
	sig: string,
}

-- A run's rows by what they're known by, in the order they came.
type Snapshot = { order: { string }, rows: { [string]: Seen } }

-- `cell` without what changes in it by itself, as the "(5m ago)" of
-- kubectl's RESTARTS, and with its spaces made one.
local function settled(cell: string): string
	local without = string.gsub(cell, "%s*%([^()]*ago%)", "")
	return (string.gsub(without, "%s+", " "))
end

-- Columns of how long ago something was, which change by themselves even
-- when they're only minutes ("3m"), which `tables.durations` can't tell
-- from a size.
local AGES = { AGE = true, ["LAST SEEN"] = true, CREATED = true, UPTIME = true }

-- The columns of `tbl` that change by themselves, as durations like AGE do.
local function ticking(tbl: tables.Table): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for _, column in tbl.columns do
		if AGES[string.upper(column)] or tables.durations(tbl, column) then
			out[column] = true
		end
	end
	return out
end

-- `row` of `tbl` (or a line, `text`, outside a table) as `Seen`. A line
-- has changed when its words did, as columns lined up again when one grows
-- aren't a change; a row as `differs` says.
local function seen(
	label: string,
	text: string,
	tbl: tables.Table?,
	row: { [string]: string }?,
	skip: { [string]: boolean }
): Seen
	local words = string.gsub(text, "%s+", " ")
	if tbl == nil or row == nil then
		return { label = label, sig = words }
	end
	return { label = label, cells = row, columns = tbl.columns, ticking = skip, sig = words }
end

-- `lines`, `block`'s output, as a snapshot. A line is known by the thing
-- its row is, when a kind reads its table, as the same file or pod can
-- move up or down; else by its first word and how many lines before had
-- it, as every row of `ls -l` starts alike.
local function snapshot(lines: { string }, block: Block): Snapshot
	local shot: Snapshot = { order = {}, rows = {} }
	local counts: { [string]: number } = {}
	local tbl = block.table
	local skip = if tbl then ticking(tbl) else {}
	local first = if tbl and tbl.first
		then tbl.first + (if tbl.header ~= false then 1 else 0)
		else nil
	for i, text in lines do
		local index = if first and i >= first then i - first + 1 else nil
		local row = if tbl and index then tbl.rows[index] else nil
		local thing = if index then kinds.thing(block, index) else nil
		local word = string.match(text, "^%s*(%S+)") or ""
		local key
		if thing then
			key = `\1{thing.kind}\0{thing.label}`
		else
			counts[word] = (counts[word] or 0) + 1
			key = `{word}\0{counts[word]}`
		end
		table.insert(shot.order, key)
		shot.rows[key] = seen(if thing then thing.label else word, text, tbl, row, skip)
	end
	return shot
end

-- Whether `was` and `is`, the same row (or line) on two runs, differ: the
-- first column whose cell changed, but for columns that change by
-- themselves on either run, as a column of durations stops looking like
-- one when it reads "2m"; "" for lines whose words changed; nil when
-- nothing did.
local function differs(was: Seen, is: Seen): string?
	local before, now, columns = was.cells, is.cells, is.columns
	if before == nil or now == nil or columns == nil then
		return if was.sig ~= is.sig then "" else nil
	end
	local old, new = was.ticking or {}, is.ticking or {}
	for _, column in columns do
		local a, b = before[column] or "", now[column] or ""
		if not old[column] and not new[column] and settled(a) ~= settled(b) then
			return column
		end
	end
	return nil
end

-- How `was` and `is`, the same row on two runs, differ, as `describe` says.
local function difference(was: Seen, is: Seen, column: string): string
	local before, now = was.cells, is.cells
	if column == "" or before == nil or now == nil then
		return `{is.label} changed`
	end
	return `{is.label}: {column} {before[column] or ""} → {now[column] or ""}`
end

-- What changed in a table from one run to the next, in a few words,
-- naming its rows: "new worker-abc", "api-7d9: STATUS Running → Error",
-- "worker-abc gone", and how many more changed. Nil when nothing did, or
-- it isn't a table.
local function describe(before: Snapshot, now: Snapshot): string?
	local said: { string } = {}
	for _, key in now.order do
		local was, is = before.rows[key], now.rows[key]
		if is.cells then
			local column = if was then differs(was, is) else nil
			if was == nil then
				table.insert(said, `new {is.label}`)
			elseif column then
				table.insert(said, difference(was, is, column))
			end
		end
	end
	for _, key in before.order do
		local was = before.rows[key]
		if was.cells and now.rows[key] == nil then
			table.insert(said, `{was.label} gone`)
		end
	end
	if #said == 0 then
		return nil
	end
	return if #said == 1 then said[1] else `{said[1]} +{#said - 1} more`
end

-- After a run of `block` that changed what it shows (`said`, as `describe`
-- puts it): the strip says so, and so does a notification when you asked
-- for them.
local function tell(block: Block, said: string?)
	if said == nil then
		return
	end
	block.change = `{said} · {os.date("%H:%M")}`
	if block.notify then
		greed.client.notify(string.match(block.command, "^[^\n]*") or block.command, said)
	end
end

-- What `block` printed this time as the lines it shows: its output, those
-- that are new or changed since `before` marked, then its errors. Also how
-- many changed, and the snapshot of this run.
local function lines_of(block: Block, before: Snapshot?): ({ Line }, number, Snapshot)
	local lines: { Line } = {}
	local changed = 0
	local out = split(block.stdout)
	local now = snapshot(out, block)
	for i, key in now.order do
		local text = out[i]
		local marks: { greed.Mark } = {}
		local was = before and before.rows[key]
		if before and not block.drawn and (was == nil or differs(was, now.rows[key]) ~= nil) then
			changed += 1
			table.insert(marks, { from = 0, to = #text, style = "shell.changed" })
		end
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
		local before: Snapshot? = nil
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
			-- A chart's characters aren't a table.
			block.table = if block.drawn
				then nil
				else tables.from_value(block.value) or tables.parse(out, line, block)
			kinds.finished(shell, block)
			local lines, changed, now = lines_of(block, before)
			if before and not block.drawn then
				tell(block, describe(before, now))
			end
			before = now
			block.note = if block.drawn
				then `every {every}s · {os.date("%H:%M:%S")}`
				else `every {every}s · {changed} changed · {os.date("%H:%M:%S")}`
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
		local last: Snapshot? = nil
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
				local now = snapshot(drawn, block)
				if last then
					tell(block, describe(last, now))
				end
				last = now
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
