-- Tables in a block's output, an extra on top of its text: aligned columns
-- under a header row, as kubectl, docker, ps and df print them, `ls -l`'s
-- lines, and JSON arrays of objects. A block keeps its table as a value
-- (`block.table`), and the table stages work on it: `$3 | where STATUS =
-- Running`, `$3 | select NAME,AGE`, `$3 | sort AGE`.
--
-- Finding a table is careful, since prose must never be one: a header of
-- capitals (or a command known to print one, like df), columns that start
-- where the same blank column runs through every line, and rows with
-- something in at least two columns. When it isn't sure, it's text, and
-- the converters say what it is instead: `$3 | columns`, `from csv`,
-- `from tsv`, `from json`, `split SEP` and `lines`. Plugins read their
-- commands' output first with `parser`.

local greed = require("@greed")
local core = require("@core")

local M = {}

--- Rows under named columns. Every cell is text, "" when empty. `starts`
--- is the screen column each column starts at in the lines the table was
--- read from or drawn as; `first` the line of the output (from 1) the
--- table starts on, with its header there when `header` is true (`ls -l`
--- has none). Tables made from JSON or by a stage have neither until
--- they're drawn.
export type Table = {
	columns: { string },
	rows: { { [string]: string } },
	starts: { number }?,
	first: number?,
	header: boolean?,
}

-- Commands whose header isn't in capitals, but whose output is a table.
local KNOWN: { [string]: boolean } = { df = true }

-- Commands printing names in columns, which can look like a header.
local NEVER: { [string]: boolean } =
	{ ls = true, exa = true, eza = true, tree = true, column = true }

-- The most lines and bytes looked through for a table.
local MAX_LINES = 20000
local MAX_BYTES = 4 * 1024 * 1024

-- The program a command line runs: its first word that isn't a variable
-- set for it, `sudo` or a `$3 |` before it, without its folder.
function M.program(command: string): string?
	local rest = string.gsub(command, "^.*|", "")
	for word in string.gmatch(rest, "%S+") do
		if not string.find(word, "=", 1, true) and word ~= "sudo" and word ~= "!" then
			local name = string.match(word, "([^/]+)$") or word
			return (string.gsub(name, "^!", ""))
		end
	end
	return nil
end

-- A run of non-blank characters in a line: its first and last screen
-- column (from 0), and where it is in the line's bytes.
type Run = { from: number, to: number, byte: number, stop: number }

-- The runs of non-blank characters in `line`.
local function runs(line: string): { Run }
	local out: { Run } = {}
	local ascii = not string.find(line, "[\128-\255]")
	local at = 1
	while true do
		local byte, last = string.find(line, "%S+", at)
		if byte == nil or last == nil then
			break
		end
		local from = if ascii then byte - 1 else core.text.width(string.sub(line, 1, byte - 1))
		local wide = if ascii
			then last - byte + 1
			else core.text.width(string.sub(line, byte, last))
		table.insert(out, { from = from, to = from + wide - 1, byte = byte, stop = last + 1 })
		at = last + 1
	end
	return out
end

-- Whether `word` reads as a column's name: capitals, digits and a few
-- marks, with a capital in it ("NAME", "%CPU", "NOMINATED NODE").
local function caps(word: string): boolean
	return string.match(word, "^[%u%d%%%-_/%.():#]+$") ~= nil and string.find(word, "%u") ~= nil
end

-- A column found in the lines: where it starts and ends on screen, and
-- the header's words in it.
type Field = { from: number, to: number, words: { Run } }

-- The cell of `line` (with its `cells` runs) between screen columns
-- `from` and `to`, spaces inside kept.
local function cell(line: string, cells: { Run }, from: number, to: number): string
	local start, stop = 0, 0
	for _, run in cells do
		if run.from >= from and run.from <= to then
			if start == 0 then
				start = run.byte
			end
			stop = run.stop
		end
	end
	return if start == 0 then "" else string.sub(line, start, stop - 1)
end

-- `text` cut into `count` words, the last taking the rest of it when
-- `rest`; nil when it has fewer words, or more without `rest`.
local function words_of(text: string, count: number, rest: boolean): { string }?
	local parts: { string } = {}
	local at = 1
	while #parts < count do
		local from, to = string.find(text, "%S+", at)
		if from == nil or to == nil then
			return nil
		end
		if #parts == count - 1 and rest then
			table.insert(parts, string.sub(text, from))
		else
			table.insert(parts, string.sub(text, from, to))
		end
		at = to + 1
	end
	if not rest and string.find(text, "%S", at) then
		return nil
	end
	return parts
end

-- Lines that may come before a table's header: warnings a tool printed
-- first, like kubectl's.
local function preamble(line: string): boolean
	return string.match(line, "^Warning:") ~= nil or string.match(line, "^[IWEF]%d%d%d%d ") ~= nil
end

-- `ls -l`'s lines, or nil when `lines` aren't all of them.
local function long_listing(lines: { string }, offset: number): Table?
	local rows: { { [string]: string } } = {}
	local columns = { "MODE", "LINKS", "OWNER", "GROUP", "SIZE", "MODIFIED", "NAME" }
	for _, line in lines do
		local mode, links, owner, group, size, month, day, time, name = string.match(
			line,
			"^([%-dlcbpsD][%-rwxsStT]+[@+.]?)%s+(%d+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%a+)%s+(%d+)%s+(%S+)%s(.+)$"
		)
		if mode == nil or links == nil or owner == nil or group == nil or size == nil then
			return nil
		end
		if month == nil or day == nil or time == nil or name == nil then
			return nil
		end
		local row: { [string]: string } = {
			MODE = mode,
			LINKS = links,
			OWNER = owner,
			GROUP = group,
			SIZE = size,
			MODIFIED = `{month} {day} {time}`,
			NAME = name,
		}
		table.insert(rows, row)
	end
	-- `ls -l` lines its columns up, so the first line's words say where
	-- they start: the date's month, and the name after the time.
	local words = runs(lines[1] or "")
	if #rows == 0 or #words < 9 then
		return nil
	end
	local starts: { number } = {}
	for _, i in { 1, 2, 3, 4, 5, 6, 9 } do
		table.insert(starts, words[i].from)
	end
	return { columns = columns, rows = rows, starts = starts, first = offset + 1, header = false }
end

-- `text`'s lines, without the blank ones at its end.
local function lines_of(text: string): { string }
	local lines = string.split(string.gsub(text, "\r", ""), "\n")
	while #lines > 0 and string.match(lines[#lines], "^%s*$") do
		table.remove(lines)
	end
	return lines
end

-- The columns lined up in `lines` from line `offset` + 1 on, under a header
-- there when `header` is true. `strict` is for output nobody said was a
-- table: then a column under several words far apart, or a row with less
-- than two cells, means it isn't one.
local function aligned(lines: { string }, offset: number, header: boolean, strict: boolean): Table?
	local head = if header then lines[offset + 1] else ""
	local words = runs(head)
	-- Every line's runs, merged where they touch or overlap: what's left
	-- between them is blank in every line, so columns start after it.
	local all: { Run } = table.clone(words)
	local row_runs: { { Run } } = {}
	local above = offset + (if header then 1 else 0)
	for i = above + 1, #lines do
		local found = runs(lines[i])
		if #found == 0 and strict then
			return nil
		end
		table.insert(row_runs, found)
		for _, run in found do
			table.insert(all, run)
		end
	end
	table.sort(all, function(a: Run, b: Run)
		return a.from < b.from
	end)
	local fields: { Field } = {}
	for _, run in all do
		local last = fields[#fields]
		if last and run.from <= last.to + 1 then
			last.to = math.max(last.to, run.to)
		else
			local field: Field = { from = run.from, to = run.to, words = {} }
			table.insert(fields, field)
		end
	end
	for _, word in words do
		for _, field in fields do
			if word.from >= field.from and word.from <= field.to then
				table.insert(field.words, word)
				break
			end
		end
	end
	-- Fields without a header word hold the rest of a cell before them, like
	-- the arguments of ps's COMMAND.
	local columns: { Field } = {}
	for _, field in fields do
		if #field.words > 0 or not header then
			table.insert(columns, field)
		elseif #columns == 0 then
			return nil
		else
			columns[#columns].to = field.to
		end
	end
	if #columns == 0 or (strict and #columns < 2) then
		return nil
	end
	-- Each column runs up to the next one's start.
	local bounds: { { number } } = {}
	for i, field in columns do
		local next_field = columns[i + 1]
		table.insert(bounds, { field.from, if next_field then next_field.from - 1 else math.huge })
	end
	local cells: { { string } } = {}
	for i, found in row_runs do
		local line = lines[above + i]
		local row: { string } = {}
		local filled = 0
		for j, bound in bounds do
			local value = cell(line, found, bound[1], bound[2])
			row[j] = value
			if value ~= "" then
				filled += 1
			end
		end
		if strict and (row[1] == "" or filled < 2) then
			return nil
		end
		table.insert(cells, row)
	end
	-- A column under several header words is several columns when every
	-- row has a word for each: ps's RSS and TTY run together when RSS is
	-- wider than its header, and the last column, like ps's COMMAND, takes
	-- the rest of the line. Otherwise it's one column with a long name,
	-- like docker's "CONTAINER ID".
	local i = 1
	while i <= #columns do
		local field = columns[i]
		local count = #field.words
		local split: { { string } }? = if count > 1 then {} else nil
		for r, row in cells do
			if split == nil then
				break
			end
			local parts = words_of(row[i], count, i == #columns)
			if parts == nil then
				split = nil
			else
				split[r] = parts
			end
		end
		if split == nil then
			-- One name of several words has single spaces in it; words
			-- further apart are columns the rows don't line up under, as
			-- in prose.
			for w = 2, count do
				if strict and field.words[w].from - field.words[w - 1].to > 2 then
					return nil
				end
			end
			i += 1
		else
			table.remove(columns, i)
			for w = count, 1, -1 do
				local word = field.words[w]
				table.insert(columns, i, { from = word.from, to = word.to, words = { word } })
			end
			for r, row in cells do
				table.remove(row, i)
				for w = count, 1, -1 do
					table.insert(row, i, split[r][w])
				end
			end
			i += count
		end
	end
	-- A header word a single space after the one before, over nothing, is
	-- the rest of that column's name: df's "Mounted on".
	local j = 2
	while header and j <= #columns do
		local gap = columns[j].words[1].from - columns[j - 1].words[#columns[j - 1].words].to
		local empty = true
		for _, row in cells do
			if row[j] ~= "" then
				empty = false
				break
			end
		end
		if gap == 2 and empty then
			for _, word in columns[j].words do
				table.insert(columns[j - 1].words, word)
			end
			table.remove(columns, j)
			for _, row in cells do
				table.remove(row, j)
			end
		else
			j += 1
		end
	end
	if strict and #columns < 2 then
		return nil
	end
	local names: { string } = {}
	local starts: { number } = {}
	local taken: { [string]: boolean } = {}
	for c, field in columns do
		local parts: { string } = {}
		for _, word in field.words do
			table.insert(parts, string.sub(head, word.byte, word.stop - 1))
		end
		local name = if header then table.concat(parts, " ") else tostring(c)
		local unique, n = name, 2
		while taken[unique] do
			unique = `{name} {n}`
			n += 1
		end
		taken[unique] = true
		table.insert(names, unique)
		table.insert(starts, field.from)
	end
	local rows: { { [string]: string } } = {}
	for _, row in cells do
		local named: { [string]: string } = {}
		for c, name in names do
			named[name] = row[c]
		end
		table.insert(rows, named)
	end
	return { columns = names, rows = rows, starts = starts, first = offset + 1, header = header }
end

--- The table in `text`, a command's output, if it's one: aligned columns
--- under a header, or for `ls -l` its lines. `command` is what printed it.
--- When it can't be sure, it's text: nil.
function M.detect(text: string, command: string?): Table?
	if #text > MAX_BYTES or string.find(text, "\t", 1, true) then
		return nil
	end
	local program = if command then M.program(command) else nil
	local lines = lines_of(text)
	if #lines < 2 or #lines > MAX_LINES then
		return nil
	end
	if program == "ls" then
		local from = if string.match(lines[1], "^total %d") then 2 else 1
		return long_listing(table.move(lines, from, #lines, 1, {}), from - 1)
	end
	if program and NEVER[program] then
		return nil
	end
	local offset = 0
	while offset < #lines - 2 and preamble(lines[offset + 1]) do
		offset += 1
	end
	local header = lines[offset + 1]
	local known = program ~= nil and KNOWN[program] == true
	local words = runs(header)
	if #words < 2 then
		return nil
	end
	local wide_gap = false
	for i, word in words do
		local name = string.sub(header, word.byte, word.stop - 1)
		if not (caps(name) or (known and string.match(name, "^[%w%%%-_/%.():#]+$"))) then
			return nil
		end
		if i > 1 and word.from - words[i - 1].to > 2 then
			wide_gap = true
		end
	end
	if not wide_gap then
		return nil
	end
	return aligned(lines, offset, true, true)
end

--- `text` read as columns because someone said it's a table (`$3 |
--- columns`): lined up under its first line, or with `header` false under
--- none, named 1, 2, ... When they don't line up, each line's words are
--- the cells, the last taking the rest of the line.
function M.columns(text: string, header: boolean): Table?
	local lines = lines_of(text)
	if #lines == 0 or #lines > MAX_LINES then
		return nil
	end
	local found = aligned(lines, 0, header, false)
	if found and #found.columns > 1 then
		return found
	end
	local names: { string } = {}
	local first = 1
	if header then
		for word in string.gmatch(lines[1], "%S+") do
			table.insert(names, word)
		end
		first = 2
	else
		local most = 0
		for _, line in lines do
			local count = 0
			for _ in string.gmatch(line, "%S+") do
				count += 1
			end
			most = math.max(most, count)
		end
		for c = 1, most do
			table.insert(names, tostring(c))
		end
	end
	if #names == 0 then
		return found
	end
	local rows: { { [string]: string } } = {}
	for l = first, #lines do
		local row: { [string]: string } = {}
		local parts = words_of(lines[l], #names, true)
		for c, name in names do
			row[name] = if parts then parts[c] else ""
		end
		if parts == nil then
			-- Fewer words than columns: each in its own, from the first.
			local c = 1
			for word in string.gmatch(lines[l], "%S+") do
				row[names[c]] = word
				c += 1
			end
		end
		table.insert(rows, row)
	end
	return { columns = names, rows = rows }
end

--- `text` split at each `sep` in every line, a column for each piece,
--- named 1, 2, ...: `split :` reads /etc/passwd.
function M.split(text: string, sep: string): Table
	local rows: { { [string]: string } } = {}
	local most = 0
	for _, line in lines_of(text) do
		local parts: { string } = if sep == "" then { line } else string.split(line, sep)
		local row: { [string]: string } = {}
		for c, part in parts do
			row[tostring(c)] = part
		end
		most = math.max(most, #parts)
		table.insert(rows, row)
	end
	local names: { string } = {}
	for c = 1, most do
		table.insert(names, tostring(c))
		for _, row in rows do
			row[tostring(c)] = row[tostring(c)] or ""
		end
	end
	return { columns = names, rows = rows }
end

--- `text`'s lines as a table of one column, `line`.
function M.lines(text: string): Table
	local rows: { { [string]: string } } = {}
	for _, line in lines_of(text) do
		local row: { [string]: string } = { line = line }
		table.insert(rows, row)
	end
	return { columns = { "line" }, rows = rows }
end

-- One record of comma (or `sep`) separated values starting at `at` in
-- `text`, with quotes ("a ""b"", c") as CSV has them, and where the next
-- starts.
local function record(text: string, at: number, sep: string): ({ string }, number)
	local fields: { string } = {}
	local i = at
	local n = #text
	-- What's from `from` to the separator or the line's end, and where that
	-- is.
	local function rest(from: number): (string, number)
		local stop = from
		while stop <= n and not string.find(sep .. "\n", string.sub(text, stop, stop), 1, true) do
			stop += 1
		end
		return (string.gsub(string.sub(text, from, stop - 1), "\r$", "")), stop
	end
	while true do
		local value = ""
		if string.sub(text, i, i) == '"' then
			local parts: { string } = {}
			local j = i + 1
			while j <= n do
				local ch = string.sub(text, j, j)
				if ch == '"' then
					if string.sub(text, j + 1, j + 1) == '"' then
						table.insert(parts, '"')
						j += 2
					else
						j += 1
						break
					end
				else
					table.insert(parts, ch)
					j += 1
				end
			end
			-- Anything after the closing quote, up to the separator, is kept.
			local after, stop = rest(j)
			value, i = table.concat(parts) .. after, stop
		else
			value, i = rest(i)
		end
		table.insert(fields, value)
		local ch = string.sub(text, i, i)
		if ch == sep then
			i += 1
		else
			return fields, i + 1
		end
	end
end

--- `text` read as CSV (or with `sep` "\t", TSV): its first record names
--- the columns.
function M.csv(text: string, sep: string?): Table?
	local by = sep or ","
	local records: { { string } } = {}
	local at = 1
	while at <= #text do
		local fields, next_at = record(text, at, by)
		if not (#fields == 1 and fields[1] == "") then
			table.insert(records, fields)
		end
		at = next_at
	end
	if #records == 0 then
		return nil
	end
	local names: { string } = {}
	local taken: { [string]: boolean } = {}
	for c, name in records[1] do
		local unique = if name == "" or taken[name] then `{name}{c}` else name
		taken[unique] = true
		table.insert(names, unique)
	end
	local rows: { { [string]: string } } = {}
	for r = 2, #records do
		local row: { [string]: string } = {}
		for c, name in names do
			row[name] = records[r][c] or ""
		end
		table.insert(rows, row)
	end
	return { columns = names, rows = rows }
end

-- A JSON value as a cell's text.
local function as_text(value: any): string
	if value == nil then
		return ""
	elseif type(value) == "string" then
		return value
	elseif type(value) == "number" then
		return if value == math.floor(value) and math.abs(value) < 1e15
			then string.format("%d", value)
			else tostring(value)
	elseif type(value) == "table" then
		return greed.json.encode(value)
	end
	return tostring(value)
end

-- Keys a JSON object names itself by, which go first.
local FIRST: { [string]: number } = { name = 1, id = 2 }

--- `value` (JSON read from output) as a table, when it's an array of
--- objects: a column for each key, the ones naming a row first.
function M.from_value(value: any): Table?
	if type(value) ~= "table" or #value == 0 then
		return nil
	end
	local seen: { [string]: boolean } = {}
	local columns: { string } = {}
	for i, item in value do
		if type(i) ~= "number" or type(item) ~= "table" or #item > 0 or next(item) == nil then
			return nil
		end
		for key in item do
			if type(key) ~= "string" then
				return nil
			end
			if not seen[key] then
				seen[key] = true
				table.insert(columns, key)
			end
		end
	end
	table.sort(columns, function(a: string, b: string)
		local ra, rb = FIRST[string.lower(a)] or 99, FIRST[string.lower(b)] or 99
		if ra ~= rb then
			return ra < rb
		end
		return a < b
	end)
	local rows: { { [string]: string } } = {}
	for _, item in value do
		local row: { [string]: string } = {}
		for _, column in columns do
			row[column] = as_text(item[column])
		end
		table.insert(rows, row)
	end
	return { columns = columns, rows = rows }
end

--- `text` read as JSON for a table (`$3 | from json`): an array of objects,
--- an object as one row, an array of other values as a `value` column, or
--- JSON lines, an object on each.
function M.from_json(text: string): Table?
	local value = greed.json.decode(text)
	if type(value) == "table" then
		local list = if #value == 0 and next(value) ~= nil then { value } else value
		local found = M.from_value(list)
		if found or #list == 0 then
			return found
		end
		local rows: { { [string]: string } } = {}
		for _, item in list do
			local row: { [string]: string } = { value = as_text(item) }
			table.insert(rows, row)
		end
		return { columns = { "value" }, rows = rows }
	end
	local items: { any } = {}
	for _, line in lines_of(text) do
		if string.find(line, "%S") then
			local item = greed.json.decode(line)
			if type(item) ~= "table" then
				return nil
			end
			table.insert(items, item)
		end
	end
	return M.from_value(items)
end

--- The indexes of all of `tbl`'s rows, in order.
function M.all(tbl: Table): { number }
	local rows: { number } = {}
	for i = 1, #tbl.rows do
		rows[i] = i
	end
	return rows
end

--- `tbl` drawn as aligned lines, the header first, with `rows` (indexes
--- into its rows; all of them by default), and where each column starts.
function M.draw(tbl: Table, rows: { number }?): ({ string }, { number })
	local order = rows or M.all(tbl)
	local widths: { number } = {}
	for i, column in tbl.columns do
		widths[i] = core.text.width(column)
		for _, index in order do
			widths[i] = math.max(widths[i], core.text.width(tbl.rows[index][column] or ""))
		end
	end
	local starts: { number } = {}
	local at = 0
	for i in tbl.columns do
		starts[i] = at
		at += widths[i] + 3
	end
	local function line(cells: { string }): string
		local parts: { string } = {}
		for i, text in cells do
			local pad = if i < #cells
				then string.rep(" ", widths[i] - core.text.width(text) + 3)
				else ""
			table.insert(parts, text .. pad)
		end
		return (string.gsub(table.concat(parts), "%s+$", ""))
	end
	local lines = { line(tbl.columns) }
	for _, index in order do
		local cells: { string } = {}
		for i, column in tbl.columns do
			cells[i] = tbl.rows[index][column] or ""
		end
		table.insert(lines, line(cells))
	end
	return lines, starts
end

--- `tbl` as text, a line per row under the header, as a stage prints it;
--- `tbl` notes where its header and columns are in it.
function M.text(tbl: Table): string
	local lines, starts = M.draw(tbl)
	tbl.starts, tbl.first, tbl.header = starts, 1, true
	return table.concat(lines, "\n") .. "\n"
end

-- Seconds in each unit of a duration.
local UNITS: { [string]: number } =
	{ s = 1, m = 60, h = 3600, d = 86400, w = 7 * 86400, y = 365 * 86400 }

-- What a size suffix multiplies by: k, M, G (powers of 1000), Ki, Mi, Gi
-- (of 1024), with or without B, and m for thousandths (kubectl's CPU).
local SCALE: { [string]: number } = { [""] = 1, B = 1, m = 1e-3 }
for i, letter in { "K", "M", "G", "T", "P", "E" } do
	SCALE[letter] = 1000 ^ i
	SCALE[letter .. "B"] = 1000 ^ i
	SCALE[letter .. "i"] = 1024 ^ i
	SCALE[letter .. "iB"] = 1024 ^ i
end
SCALE.k = 1000
SCALE.kB = 1000

-- `token` read as a duration like kubectl's ages ("45s", "3d16h"), in
-- seconds.
local function duration(token: string): number?
	local total = 0
	local rest = token
	repeat
		local amount, unit, after = string.match(rest, "^(%d+%.?%d*)([ywdhms])(.*)$")
		local n = tonumber(amount)
		if n == nil or unit == nil or after == nil then
			return nil
		end
		total += n * UNITS[unit]
		rest = after
	until rest == ""
	return total
end

--- Whether a column's cells read as durations, like an AGE column: one of
--- them has hours, days, seconds, weeks or years in it. Then "12m" is
--- twelve minutes in it, where elsewhere it's 0.012 (kubectl's CPU).
function M.durations(tbl: Table, column: string): boolean
	for _, row in tbl.rows do
		local token = string.match(row[column] or "", "^%S+")
		if token and string.find(token, "[ywdhs]") and duration(token) then
			return true
		end
	end
	return false
end

--- `text` read as a number: its first word, with a size suffix (`512Mi`,
--- `1.5G`, `250m`), a `%`, or a duration in seconds (`3d16h`; a lone `m`
--- is minutes only with `durations`). "3 (3d16h ago)" is 3. Nil when it
--- isn't one.
function M.number(text: string, durations: boolean?): number?
	local token = string.match(text, "^%s*(%S+)")
	if token == nil then
		return nil
	end
	local plain = tonumber(token)
	if plain then
		return plain
	end
	local amount, suffix = string.match(token, "^([-+]?%d*%.?%d+)(%a*)%%?$")
	local n = tonumber(amount)
	if n == nil or suffix == nil then
		return duration(token)
	end
	if suffix == "m" and durations then
		return n * 60
	end
	local scale = SCALE[suffix]
	if scale then
		return n * scale
	end
	return duration(token)
end

-- `name` without case, spaces and marks, to compare column names.
local function normal(name: string): string
	return (string.gsub(string.lower(name), "[^%w]", ""))
end

--- The column of `tbl` that `name` names, without minding case, spaces or
--- marks: "container_id" is "CONTAINER ID".
function M.column(tbl: Table, name: string): string?
	local want = normal(name)
	for _, column in tbl.columns do
		if normal(column) == want then
			return column
		end
	end
	return nil
end

-- `a` before `b`: as numbers when both are, numbers first, then as text
-- without minding case. Nil when they're the same.
local function before(a: string, b: string, durations: boolean): boolean?
	local na, nb = M.number(a, durations), M.number(b, durations)
	if na and nb then
		if na == nb then
			return nil
		end
		return na < nb
	elseif na or nb then
		return na ~= nil
	end
	local la, lb = string.lower(a), string.lower(b)
	if la == lb then
		return nil
	end
	return la < lb
end

-- `text` without blanks at its start and end.
local function trim(text: string): string
	return string.match(text, "^%s*(.-)%s*$") or ""
end

-- `text` without the quotes around it, if it has them.
local function unquote(text: string): string
	return string.match(text, '^"(.*)"$') or string.match(text, "^'(.*)'$") or text
end

-- Why `name` names no column of `tbl`.
local function no_column(tbl: Table, name: string): string
	return `no column {name}; there's {table.concat(tbl.columns, ", ")}`
end

--- The comparisons `where` and a filter know.
M.OPS = { "!=", "<=", ">=", "!~", "=", "~", "<", ">" }

--- A stage the shell runs on a table after `$3 |`: how it's typed, what
--- it does, and what its arguments are, for completion: "condition"
--- (COL OP VALUE), "columns" (COL,...), "column" (COL and -r), "header"
--- (-H), "format" (csv, tsv, json), "path" (a field of JSON); nil for none.
export type Stage = { name: string, usage: string, doc: string, args: string? }

--- The stages, in the order `help` lists them.
M.STAGES = {
	{
		name = "where",
		usage = "where COL OP VALUE",
		doc = "The rows passing a test: = != ~ !~ < > <= >=",
		args = "condition",
	},
	{
		name = "select",
		usage = "select COL,...",
		doc = "Only those columns, in that order",
		args = "columns",
	},
	{
		name = "sort",
		usage = "sort COL [-r]",
		doc = "Sorted by a column, from the greatest with -r",
		args = "column",
	},
	{
		name = "columns",
		usage = "columns [-H]",
		doc = "Text lined up in columns, under a header or with -H none",
		args = "header",
	},
	{
		name = "from",
		usage = "from csv|tsv|json",
		doc = "CSV, tab separated values, or JSON or JSON lines",
		args = "format",
	},
	{ name = "split", usage = "split SEP", doc = "Each line cut at SEP into columns 1, 2, ..." },
	{ name = "lines", usage = "lines", doc = "A row for each line, in a column `line`" },
	{
		name = "get",
		usage = "get PATH",
		doc = "A field of JSON, like items or items.0.name (arrays count from 0)",
		args = "path",
	},
} :: { Stage }

--- Whether `cell` (in a column of durations or not) passes `op` `value`:
--- = and != without minding case, or as numbers when both are; ~ and !~
--- for text in it; <, >, <= and >= as numbers when both are, else as text.
function M.test(cell: string, op: string, value: string, durations: boolean?): boolean
	if op == "~" or op == "!~" then
		local found = string.find(string.lower(cell), string.lower(value), 1, true) ~= nil
		return found == (op == "~")
	end
	local nc, nv = M.number(cell, durations), M.number(value, durations)
	local same = if nc and nv then nc == nv else string.lower(cell) == string.lower(value)
	if op == "=" then
		return same
	elseif op == "!=" then
		return not same
	end
	local less = before(cell, value, durations == true)
	if op == "<" then
		return less == true
	elseif op == ">" then
		return less == false
	elseif op == "<=" then
		return less ~= false
	elseif op == ">=" then
		return less ~= true
	end
	return false
end

--- A condition: `COLUMN op VALUE`, read from text like "STATUS=Running" or
--- `AGE < 1h`, with quotes around the value taken off.
export type Condition = { column: string, op: string, value: string }

--- `text` read as a condition on a column of `tbl`, or nil and why not.
function M.condition(tbl: Table, text: string): (Condition?, string?)
	for _, op in M.OPS do
		local at = string.find(text, op, 1, true)
		if at then
			local name = trim(string.sub(text, 1, at - 1))
			local column = M.column(tbl, name)
			if column == nil then
				return nil, no_column(tbl, name)
			end
			local value = unquote(trim(string.sub(text, at + #op)))
			return { column = column, op = op, value = value }, nil
		end
	end
	return nil, "where COLUMN = VALUE (or !=, ~, !~, <, >, <=, >=)"
end

--- The rows (indexes) of `tbl` that pass `condition`, from `rows` (all by
--- default).
function M.matching(tbl: Table, condition: Condition, rows: { number }?): { number }
	-- "1h" says the column holds durations, even when every age in it is in
	-- minutes.
	local durations = M.durations(tbl, condition.column)
		or string.match(condition.value, "^%d+%.?%d*[ywdhs]") ~= nil
	local out: { number } = {}
	for _, i in rows or M.all(tbl) do
		if
			M.test(tbl.rows[i][condition.column] or "", condition.op, condition.value, durations)
		then
			table.insert(out, i)
		end
	end
	return out
end

--- The rows (indexes) of `tbl` a filter typed in a block keeps: each word
--- of `text` is a condition on a column (`STATUS=Running`, `NAME~api`,
--- `RESTARTS>0`), or else text some cell of the row has in it, without
--- minding case. A row has to pass them all.
function M.filter(tbl: Table, text: string): { number }
	local rows = M.all(tbl)
	for word in string.gmatch(text, "%S+") do
		local condition = M.condition(tbl, word)
		if condition then
			rows = M.matching(tbl, condition, rows)
		else
			local want = string.lower(word)
			local kept: { number } = {}
			for _, i in rows do
				for _, column in tbl.columns do
					if string.find(string.lower(tbl.rows[i][column] or ""), want, 1, true) then
						table.insert(kept, i)
						break
					end
				end
			end
			rows = kept
		end
	end
	return rows
end

--- `rows` (indexes into `tbl`'s) sorted by `column`, from the least, or the
--- greatest with `desc`; rows that compare the same keep their order.
function M.sorted(tbl: Table, rows: { number }, column: string, desc: boolean?): { number }
	local durations = M.durations(tbl, column)
	local out = table.clone(rows)
	table.sort(out, function(a: number, b: number): boolean
		local less = before(tbl.rows[a][column] or "", tbl.rows[b][column] or "", durations)
		if less == nil then
			return a < b
		end
		return if desc then not less else less
	end)
	return out
end

-- A new table of `tbl`'s `rows`, with `columns` (all by default).
local function subset(tbl: Table, rows: { number }, columns: { string }?): Table
	local keep = columns or tbl.columns
	local out: { { [string]: string } } = {}
	for _, index in rows do
		local row: { [string]: string } = {}
		for _, column in keep do
			row[column] = tbl.rows[index][column]
		end
		table.insert(out, row)
	end
	return { columns = table.clone(keep), rows = out }
end

--- The rows of `tbl` passing `COLUMN op VALUE`, as a new table.
function M.where(tbl: Table, text: string): (Table?, string?)
	local condition, why = M.condition(tbl, text)
	if condition == nil then
		return nil, why
	end
	return subset(tbl, M.matching(tbl, condition)), nil
end

--- `tbl` with only the columns `text` names ("NAME,AGE" or "NAME AGE"),
--- in that order.
function M.select(tbl: Table, text: string): (Table?, string?)
	local columns: { string } = {}
	for name in string.gmatch(text, "[^,%s]+") do
		local column = M.column(tbl, name)
		if column == nil then
			return nil, no_column(tbl, name)
		end
		table.insert(columns, column)
	end
	if #columns == 0 then
		return nil, "select COLUMN,..."
	end
	return subset(tbl, M.all(tbl), columns), nil
end

-- `sort`'s words: the column and whether to reverse, or nil when they
-- don't name a column (then it's the sort program).
local function sort_args(tbl: Table, text: string): (string?, boolean)
	local column: string? = nil
	local desc = false
	for word in string.gmatch(text, "%S+") do
		if word == "-r" or word == "desc" or word == "--reverse" then
			desc = true
		elseif word == "asc" then
			desc = false
		elseif column == nil then
			column = M.column(tbl, word)
			if column == nil then
				return nil, false
			end
		else
			return nil, false
		end
	end
	return column, desc
end

--- `tbl` sorted by the column `text` names, reversed with `-r` or `desc`.
function M.sort(tbl: Table, text: string): (Table?, string?)
	local column, desc = sort_args(tbl, text)
	if column == nil then
		return nil, "sort COLUMN [-r]"
	end
	return subset(tbl, M.sorted(tbl, M.all(tbl), column, desc)), nil
end

-- `line` cut at each `|` outside quotes.
local function stages(line: string): { string }
	local parts: { string } = {}
	local start, quote = 1, nil :: string?
	for i = 1, #line do
		local ch = string.sub(line, i, i)
		if quote then
			if ch == quote then
				quote = nil
			end
		elseif ch == "'" or ch == '"' then
			quote = ch
		elseif ch == "|" then
			table.insert(parts, string.sub(line, start, i - 1))
			start = i + 1
		end
	end
	table.insert(parts, string.sub(line, start))
	return parts
end

-- The stage reading text as a table that `word rest` names (`columns`,
-- `from csv`, `split :`, ...), or nil when it names none. It returns the
-- table, or nil and why not.
local function converter(word: string, rest: string): ((text: string) -> (Table?, string))?
	if word == "columns" and (rest == "" or rest == "-H" or rest == "--no-header") then
		local header = rest == ""
		return function(text: string): (Table?, string)
			return M.columns(text, header), "there's nothing in it"
		end
	elseif word == "from" and (rest == "csv" or rest == "tsv") then
		local sep = if rest == "csv" then "," else "\t"
		return function(text: string): (Table?, string)
			return M.csv(text, sep), "there's nothing in it"
		end
	elseif word == "from" and rest == "json" then
		return function(text: string): (Table?, string)
			return M.from_json(text), "it isn't JSON, or JSON lines"
		end
	elseif word == "split" and rest ~= "" and string.sub(rest, 1, 1) ~= "-" then
		local sep = unquote(rest)
		if sep == rest and string.find(rest, "%s") then
			return nil
		end
		return function(text: string): (Table?, string)
			return M.split(text, sep), ""
		end
	elseif word == "lines" and rest == "" then
		return function(text: string): (Table?, string)
			return M.lines(text), ""
		end
	end
	return nil
end

-- Whether `value` is a JSON object (and not an array).
local function is_object(value: any): boolean
	return type(value) == "table" and #value == 0 and next(value) ~= nil
end

--- A JSON value as a stage prints it: a string as it is, a number as
--- written, anything else as JSON.
function M.value_text(value: any): string
	return as_text(value)
end

--- What `path` names in JSON `value`: dots between an object's fields and
--- an array's items, from 0 (`items.0.name`); a field after an array is
--- that field of each item (`items.name`). Nil and why when it isn't there.
function M.get(value: any, path: string): (any, string?)
	local current = value
	local walked = ""
	for part in string.gmatch(path, "[^%.]+") do
		local here = if walked == "" then "the JSON" else walked
		local index = tonumber(part)
		local found: any = nil
		if type(current) ~= "table" then
			return nil, `{here} is {as_text(current)}, with no {part} in it`
		elseif is_object(current) then
			found = current[part]
			if found == nil then
				local keys: { string } = {}
				for key in current do
					table.insert(keys, tostring(key))
				end
				table.sort(keys)
				return nil, `{here} has no {part}; it has {table.concat(keys, ", ")}`
			end
		elseif index then
			found = current[index + 1]
			if found == nil then
				return nil, `{here} has {#current} items, from 0`
			end
		else
			local each: { any } = {}
			for _, item in current do
				if type(item) == "table" and item[part] ~= nil then
					table.insert(each, item[part])
				end
			end
			if #each == 0 then
				return nil, `no item of {here} has {part}`
			end
			found = greed.json.array(each)
		end
		current = found
		walked = if walked == "" then part else `{walked}.{part}`
	end
	return current, nil
end

-- The names of columns a stage's arguments `rest` name: where's column,
-- select's columns, sort's column.
local function named_columns(word: string, rest: string): { string }
	local names: { string } = {}
	if word == "where" then
		for _, op in M.OPS do
			local at = string.find(rest, op, 1, true)
			if at then
				table.insert(names, trim(string.sub(rest, 1, at - 1)))
				break
			end
		end
	elseif word == "select" then
		for name in string.gmatch(rest, "[^,%s]+") do
			table.insert(names, name)
		end
	else
		for name in string.gmatch(rest, "%S+") do
			if string.sub(name, 1, 1) ~= "-" and name ~= "asc" and name ~= "desc" then
				table.insert(names, name)
			end
		end
	end
	return names
end

--- The tables a JSON object gives the stages: itself as one row, a column
--- for each field, and the array of objects one of its fields holds, when
--- just one does, like kubectl's `items`.
function M.object_tables(object: any): (Table?, Table?)
	if not is_object(object) then
		return nil, nil
	end
	local inner: Table? = nil
	local arrays = 0
	for _, field in object do
		local found = M.from_value(field)
		if found then
			arrays += 1
			inner = found
		end
	end
	return M.from_value({ object }), if arrays == 1 then inner else nil
end

-- The table stage `word` with `rest` works on in JSON object `object`: its
-- own fields when they're the columns named, else the array of objects a
-- field holds.
local function object_table(object: any, word: string, rest: string): Table?
	local own, inner = M.object_tables(object)
	if own == nil or inner == nil then
		return own
	end
	for _, name in named_columns(word, rest) do
		if M.column(own, name) == nil then
			return inner
		end
	end
	return if word == "sort" then inner else own
end

-- The stages only the shell runs: no program has their names.
local OWN: { [string]: boolean } = { where = true, select = true, get = true }

-- Why `word`, a stage, can't read text.
local function not_a_table(word: string): string
	return `{word} works on a table, and this isn't one; columns, from csv/tsv/json, split or lines make one`
end

--- Runs the table stages at the start of `line` (what follows `$3 |`) on
--- `tbl`, or on `text` for those reading text as a table, or on `value`
--- when the text was JSON: `where`, `select`, `sort` naming a column,
--- `columns`, `from csv`, `from tsv`, `from json`, `split SEP`, `lines`
--- and `get PATH`. Returns the table they made, the rest of the line after
--- them for a program to read as text, why they can't run (like a column
--- that isn't there) when they can't, and the JSON `get` picked when it
--- isn't a table. All nil when `line` starts with no stage.
function M.pipeline(
	tbl: Table?,
	text: string?,
	line: string,
	value: any?
): (Table?, string?, string?, any?)
	local current = tbl
	-- The JSON the stages read, while they've read nothing else.
	local json = value
	local parts = stages(line)
	local done = 0
	for _, part in parts do
		local word, args = string.match(part, "^%s*(%S+)%s*(.-)%s*$")
		local rest = args or ""
		local convert = if word then converter(word, rest) else nil
		-- What a stage on a table reads: an object's fields or array.
		local input = current
		if input == nil and is_object(json) and word then
			input = object_table(json, word, rest)
		end
		if convert then
			-- The text as it came, or what the stages before made.
			local from = if done > 0 and current
				then M.text(current)
				elseif done > 0 and json ~= nil then M.value_text(json)
				else text or ""
			local made, why = convert(from)
			if made == nil then
				return nil, nil, `{word}: {why}`
			end
			current, json = made, nil
		elseif word == "get" then
			if json == nil and done == 0 and text and string.match(text, "^%s*[%[{]") then
				json = greed.json.decode(text)
			end
			if json == nil then
				return nil,
					nil,
					"get works on JSON, as many programs print when asked (kubectl get -o json); from json reads JSON lines"
			elseif rest == "" then
				return nil, nil, "get PATH, like get items.0.name"
			end
			local found, why = M.get(json, rest)
			if why then
				return nil, nil, `get: {why}`
			end
			json = found
			current = M.from_value(found)
		elseif word == "where" or word == "select" then
			if input == nil then
				return nil, nil, not_a_table(word)
			end
			local made: Table?, why: string?
			if word == "where" then
				made, why = M.where(input, rest)
			else
				made, why = M.select(input, rest)
			end
			if made == nil then
				return nil, nil, `{word}: {why}`
			end
			current, json = made, nil
		elseif word == "sort" and input and sort_args(input, rest) then
			current, json = M.sort(input, rest), nil
		else
			break
		end
		done += 1
	end
	-- A stage after a program would go to the program's shell, which has
	-- no such command.
	for i = done + 2, #parts do
		local word = string.match(parts[i], "^%s*(%S+)")
		if word and OWN[word] then
			if current == nil and json == nil and done == 0 then
				return nil, nil, not_a_table(word)
			end
			local program = string.match(parts[done + 1], "^%s*(%S+)") or "a program"
			return nil,
				nil,
				`{word} can't read what {program} prints: the shell's stages go first, right after $3 |`
		end
	end
	if done == 0 then
		return nil, nil, nil
	end
	local after = trim(table.concat(parts, "|", done + 1))
	return current, if after == "" then nil else after, nil, if current then nil else json
end

--- Reads a command's output as a table: `text`, and the block it's from.
--- It returns a table (`{ columns, rows }`), a list of objects as JSON
--- has them, or nil to leave it to the shell.
export type Parser = (text: string, block: any) -> any

local parsers: { { match: string, parse: Parser } } = {}

-- Characters that make a parser's `match` a pattern.
local MAGIC = "[%^%$%%%*%+%?%[%(%.]"

--- Reads the output of the commands `match` names with `parse`, ahead of
--- the shell's own look for a table: a program's name ("kubectl"), or a
--- Luau pattern for the whole command line ("^helm list"). The latest
--- added is asked first. It goes when the plugin that added it does.
function M.parser(match: string, parse: Parser)
	greed.plugin.tie(core.registry.put(parsers, { match = match, parse = parse }))
end

--- `text`, what `command` printed, read as a table: by a parser a plugin
--- added for the command, or else by the shell's careful look for one
--- (`detect`). Nil when it's text.
function M.parse(text: string, command: string, block: any?): Table?
	local program = M.program(command)
	for i = #parsers, 1, -1 do
		local entry = parsers[i]
		local match = entry.match
		local hit = match == program
		if not hit and string.find(match, MAGIC) then
			-- A pattern that isn't one matches nothing.
			local ok, found = pcall(function(): boolean
				return string.find(command, match) ~= nil
			end)
			hit = ok and found
		end
		if hit then
			local ok, found = pcall(entry.parse, text, block)
			if ok and type(found) == "table" then
				local tbl = if type(found.columns) == "table"
						and type(found.rows) == "table"
					then found :: Table
					else M.from_value(found)
				if tbl then
					return tbl
				end
			end
		end
	end
	return M.detect(text, command)
end

return M
