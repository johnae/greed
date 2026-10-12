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

core.search.kind("shell-filter", "ignore", "filtering a shell block with /")

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
	--- The line of the output (from 1) each row is on, when they aren't
	--- all after `first`, as in nu's tables, drawn with borders.
	at: { number }?,
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

-- The columns of a header's `words` over rows' runs (`row_runs`), leaving
-- out the rows in `skip`: what's blank in every line between runs is where
-- one column ends and the next starts. Nil when they don't make columns.
local function columns_of(
	words: { Run },
	row_runs: { { Run } },
	header: boolean,
	skip: { [number]: boolean }
): { Field }?
	-- Every line's runs, merged where they touch or overlap.
	local all: { Run } = table.clone(words)
	for i, found in row_runs do
		if not skip[i] then
			table.move(found, 1, #found, #all + 1, all)
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
	return columns
end

-- The rows in `row_runs` whose first cell runs into the second column:
-- with text between the first two header words where the header and all
-- but a few rows (one in twenty) are blank. ps's row for a user name
-- longer than its column is one, every cell after it moved along. A table
-- of fewer than twenty rows has none: there, one row is as good as another.
local function out_of_line(words: { Run }, row_runs: { { Run } }): { [number]: boolean }
	local out: { [number]: boolean } = {}
	local second = words[2]
	local few = #row_runs // 20
	if second == nil or few == 0 then
		return out
	end
	local headed: { [number]: boolean } = {}
	for _, word in words do
		for c = word.from, word.to do
			headed[c] = true
		end
	end
	local cover: { [number]: number } = {}
	for _, found in row_runs do
		for _, run in found do
			for c = run.from, math.min(run.to, second.from - 1) do
				cover[c] = (cover[c] or 0) + 1
			end
		end
	end
	for i, found in row_runs do
		for _, run in found do
			for c = run.from, math.min(run.to, second.from - 1) do
				if not headed[c] and cover[c] <= few then
					out[i] = true
				end
			end
		end
	end
	return out
end

-- The cells of `line`, a row out of line with `columns`, by its words: as
-- many for each column as its header has, joined by a space, and the rest
-- of the line in the last.
local function cells_by_words(line: string, columns: { Field }): { string }
	local spans: { { number } } = {}
	for from, to in string.gmatch(line, "()%S+()") do
		table.insert(spans, { from :: number, (to :: number) - 1 })
	end
	local out: { string } = {}
	local next_word = 1
	for j, column in columns do
		if j == #columns then
			local span = spans[next_word]
			out[j] = if span then string.match(string.sub(line, span[1]), "^(.-)%s*$") or "" else ""
		else
			local taken: { string } = {}
			for _ = 1, math.max(#column.words, 1) do
				local span = spans[next_word]
				if span then
					table.insert(taken, string.sub(line, span[1], span[2]))
					next_word += 1
				end
			end
			out[j] = table.concat(taken, " ")
		end
	end
	return out
end

-- The columns lined up in `lines` from line `offset` + 1 on, under a header
-- there when `header` is true. `strict` is for output nobody said was a
-- table: then a column under several words far apart, or a row with less
-- than two cells, means it isn't one.
local function aligned(lines: { string }, offset: number, header: boolean, strict: boolean): Table?
	local head = if header then lines[offset + 1] else ""
	local words = runs(head)
	local row_runs: { { Run } } = {}
	local above = offset + (if header then 1 else 0)
	for i = above + 1, #lines do
		local found = runs(lines[i])
		if #found == 0 and strict then
			return nil
		end
		table.insert(row_runs, found)
	end
	local laid: { Field }? = columns_of(words, row_runs, header, {})
	-- A few rows out of line don't decide where the columns are, when the
	-- rest make more of them: their cells are their words instead.
	local odd: { [number]: boolean } = {}
	if header then
		local outliers = out_of_line(words, row_runs)
		local without = if next(outliers)
			then columns_of(words, row_runs, header, outliers)
			else nil
		if without and (laid == nil or #without > #laid) then
			laid, odd = without, outliers
		end
	end
	if laid == nil then
		return nil
	end
	local columns: { Field } = laid
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
		local by_words = if odd[i] then cells_by_words(line, columns) else nil
		for j, bound in bounds do
			local value = if by_words then by_words[j] else cell(line, found, bound[1], bound[2])
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

--- `text`, a command's output, read as JSON when it's an object or an
--- array; nil otherwise.
function M.json(text: string): any
	if string.match(text, "^%s*[%[{]") == nil then
		return nil
	end
	local value = greed.json.decode(text)
	return if type(value) == "table" then value else nil
end

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

-- What's left of `line` after a border at its start, as nu draws one.
local function unbordered(line: string): string
	for _, border in { "│", "┃", "|" } do
		local rest = string.match(line, "^%s*" .. border .. "(.*)$")
		if rest then
			return rest
		end
	end
	return line
end

--- The table `value` (an array of objects) is, drawn as `text` by a shell
--- that numbers its rows from 0 at the start of each, as nu does: each
--- row's line is the one starting with its number, in order (`at`). Nil
--- when `value` isn't a table; without the lines when the numbers aren't
--- all there, as with the numbers switched off.
function M.drawn(value: any, text: string): Table?
	local tbl = M.from_value(value)
	if tbl == nil then
		return nil
	end
	local at: { number } = {}
	for i, line in string.split(text, "\n") do
		local number = tonumber(string.match(unbordered(line), "^%s*(%d+)%s"))
		if number == #at and #at < #tbl.rows then
			table.insert(at, i)
		end
	end
	tbl.at = if #at == #tbl.rows then at else nil
	return tbl
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

-- The widest a cell shows when the shell draws a table; past it, it's cut
-- with `…`, and the whole of it is in the row's state (`space h i`).
local WIDEST = 48

-- Columns whose whole numbers are sizes in bytes, as nu's `ls` gives them.
local SIZES: { [string]: boolean } = { size = true, bytes = true, filesize = true }

-- `text` read as a date and time in ISO 8601 ("2026-10-10T10:55:08.68+02:00"),
-- in seconds since 1970; nil when it isn't one.
local function iso_time(text: string): number?
	local y, mo, d, h, mi, s, rest =
		string.match(text, "^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)[%.%d]*(.*)$")
	if y == nil or rest == nil then
		return nil
	end
	local offset = 0
	if rest ~= "Z" and rest ~= "" then
		local sign, oh, om = string.match(rest, "^([+-])(%d%d):?(%d%d)$")
		if sign == nil then
			return nil
		end
		offset = (tonumber(oh) :: number * 3600 + tonumber(om) :: number * 60)
			* (if sign == "-" then -1 else 1)
	end
	-- Days since 1970 of the date, as the proleptic Gregorian calendar
	-- counts them.
	local year, month, day = tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number
	year -= if month <= 2 then 1 else 0
	local era = year // 400
	local yoe = year - era * 400
	local doy = (153 * (month + (if month > 2 then -3 else 9)) + 2) // 5 + day - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	local days = era * 146097 + doe - 719468
	return days * 86400
		+ tonumber(h) :: number * 3600
		+ tonumber(mi) :: number * 60
		+ tonumber(s) :: number
		- offset
end

--- `text` read as a date and time in ISO 8601, in seconds since 1970; nil
--- when it isn't one.
M.iso_time = iso_time

-- A size in bytes as people read it, as nu shows them: "899 B", "142.6 kB".
local function bytes(n: number): string
	if n < 1000 then
		return `{n} B`
	end
	local units = { "kB", "MB", "GB", "TB", "PB" }
	local value, unit = n / 1000, 1
	while value >= 1000 and unit < #units do
		value /= 1000
		unit += 1
	end
	return string.format("%.1f %s", value, units[unit])
end

-- A moment, `seconds` since 1970: how long ago in the last week, else
-- its date and time.
local function when(seconds: number): string
	local ago = os.time() - seconds
	if ago >= 0 and ago < 7 * 86400 then
		return core.text.ago(ago)
	end
	return os.date("%Y-%m-%d %H:%M", seconds) :: string
end

-- Nested JSON in a cell, in a few words: "{4 fields}", "[12 items]".
local function nested(text: string): string?
	local first = string.sub(text, 1, 1)
	if first ~= "{" and first ~= "[" then
		return nil
	end
	local ok, value = pcall(greed.json.decode, text)
	if not ok or type(value) ~= "table" then
		return nil
	end
	local count = 0
	for _ in value do
		count += 1
	end
	if first == "[" then
		return `[{count} item{if count == 1 then "" else "s"}]`
	end
	return `\{{count} field{if count == 1 then "" else "s"}\}`
end

--- How a column's cells show when the shell draws a table: `show` turns a
--- cell into what's drawn (sizes, dates and nested JSON as people read
--- them), and `right` lines numbers up on the right. The cells themselves
--- stay as they are, so stages sort and compare the real values.
export type Look = { show: ((text: string) -> string)?, right: boolean }

--- How `column`'s cells in `rows` of `tbl` show.
function M.look(tbl: Table, column: string, rows: { number }?): Look
	local all_numbers, all_times, any = true, true, false
	local whole = true
	for _, index in rows or M.all(tbl) do
		local text = tbl.rows[index][column] or ""
		if text ~= "" then
			any = true
			local number = tonumber(text)
			all_numbers = all_numbers and number ~= nil
			whole = whole and number ~= nil and number == math.floor(number)
			all_times = all_times and iso_time(text) ~= nil
		end
	end
	if not any then
		return { right = false }
	elseif all_times then
		return {
			show = function(text)
				local seconds = iso_time(text)
				return if seconds then when(seconds) else text
			end,
			right = false,
		}
	elseif all_numbers and whole and SIZES[string.lower(column)] then
		return {
			show = function(text)
				local n = tonumber(text)
				return if n then bytes(n) else text
			end,
			right = true,
		}
	elseif all_numbers and whole then
		return { right = true }
	elseif all_numbers then
		-- Fractions to two places, as `map kb = n.size / 1024` makes them.
		return {
			show = function(text)
				local n = tonumber(text)
				return if n then (string.gsub(string.format("%.2f", n), "%.?0+$", "")) else text
			end,
			right = true,
		}
	end
	return {
		show = function(text)
			return nested(text) or text
		end,
		right = false,
	}
end

-- `text` cut to `WIDEST` cells, ending in `…` when it was longer.
local function cut(text: string): string
	if core.text.width(text) <= WIDEST then
		return text
	end
	local out, wide = {}, 0
	for _, code in utf8.codes(text) do
		local char = utf8.char(code)
		local w = core.text.width(char)
		if wide + w > WIDEST - 1 then
			break
		end
		table.insert(out, char)
		wide += w
	end
	return table.concat(out) .. "…"
end

--- `tbl` drawn as aligned lines, the header first, with `rows` (indexes
--- into its rows; all of them by default), and where each column starts.
--- Cells show as `look` says, cut when very wide.
function M.draw(tbl: Table, rows: { number }?): ({ string }, { number })
	local order = rows or M.all(tbl)
	local looks: { Look } = {}
	local shown: { { string } } = {}
	local widths: { number } = {}
	for i, column in tbl.columns do
		looks[i] = M.look(tbl, column, order)
		local show = looks[i].show
		shown[i] = {}
		widths[i] = core.text.width(column)
		for j, index in order do
			local text = tbl.rows[index][column] or ""
			shown[i][j] = cut(if show and text ~= "" then show(text) else text)
			widths[i] = math.max(widths[i], core.text.width(shown[i][j]))
		end
	end
	local starts: { number } = {}
	local at = 0
	for i in tbl.columns do
		starts[i] = at
		at += widths[i] + 3
	end
	-- Numbers line up on the right of their column, the rest on the left.
	local function line(cells: { string }): string
		local parts: { string } = {}
		for i, text in cells do
			local room = string.rep(" ", widths[i] - core.text.width(text))
			local gap = if i < #cells then "   " else ""
			table.insert(parts, if looks[i].right then room .. text .. gap else text .. room .. gap)
		end
		return (string.gsub(table.concat(parts), "%s+$", ""))
	end
	local lines = { line(tbl.columns) }
	for j in order do
		local cells: { string } = {}
		for i in tbl.columns do
			cells[i] = shown[i][j]
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

--- Whether a column's cells read as durations, like an AGE column: one of
--- them has hours, days, seconds, weeks or years in it. Then "12m" is
--- twelve minutes in it, where elsewhere it's 0.012 (kubectl's CPU).
function M.durations(tbl: Table, column: string): boolean
	for _, row in tbl.rows do
		if greed.compare.is_duration(row[column] or "") then
			return true
		end
	end
	return false
end

--- `text` read as a number, as filters read it (`greed.compare.number`):
--- its first word, with a size suffix (`512Mi`, `1.5G`, `250m`), a `%`, or
--- a duration in seconds. "3 (3d16h ago)" is 3. Nil when it isn't one.
M.number = greed.compare.number

-- `name` without case, spaces and marks, to compare column names.
local function normal(name: string): string
	return (string.gsub(string.lower(name), "[^%w]", ""))
end

--- The column of `tbl` that `name` names, without minding case, spaces or
--- marks: "container_id" is "CONTAINER ID". A dotted name, like
--- `status.phase`, is a field inside a column of JSON objects, as a table
--- of kubectl's items has: its cells are added to the rows under that
--- name, when any row has one.
function M.column(tbl: Table, name: string): string?
	local want = normal(name)
	for _, column in tbl.columns do
		if normal(column) == want then
			return column
		end
	end
	local head, path = string.match(name, "^([^%.]+)%.(.+)$")
	local outer = head and M.column(tbl, head)
	if outer == nil or path == nil then
		return nil
	end
	local found = false
	for _, row in tbl.rows do
		local value = M.json(row[outer] or "")
		local inner = if value ~= nil then M.get(value, path) else nil
		row[name] = if inner ~= nil then as_text(inner) else ""
		found = found or inner ~= nil
	end
	return if found then name else nil
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
	-- A field inside a column of JSON objects, as kubectl's items keep
	-- `phase` in `status`, named the way that reaches it.
	local want = string.lower(string.match(name, "([^%.]+)$") or name)
	local found: { string } = {}
	local function look(value: any, path: string)
		if type(value) ~= "table" or #found >= 3 then
			return
		end
		for key, inner in value do
			if type(key) == "string" then
				local here = `{path}.{key}`
				if string.lower(key) == want and not table.find(found, here) then
					table.insert(found, here)
				end
				look(inner, here)
			end
		end
	end
	for i = 1, math.min(#tbl.rows, 20) do
		for _, column in tbl.columns do
			local cell = tbl.rows[i][column]
			if cell and string.match(cell, "^%s*[{%[]") then
				look(M.json(cell), column)
			end
		end
	end
	if #found > 0 then
		return `no column {name}; it's {table.concat(found, " or ")}`
	end
	return `no column {name}; there's {table.concat(tbl.columns, ", ")}`
end

--- The comparisons `where` and a filter know.
M.OPS = { "!=", "<=", ">=", "!~", "=", "~", "<", ">" }

--- A stage the shell runs on a table after `$3 |`: how it's typed, what
--- it does, and what its arguments are, for completion: "condition"
--- (COL OP VALUE), "columns" (COL,...), "column" (COL and -r), "header"
--- (-H), "format" (csv, tsv, json), "path" (a field of JSON); nil for none.
--- `plugin` is the plugin that added it, for those not the shell's own.
export type Stage = { name: string, usage: string, doc: string, args: string?, plugin: string? }

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
	{
		name = "filter",
		usage = "filter EXPR",
		doc = "The rows a Luau expression holds for, with the row's cells as r and its numbers as n",
	},
	{
		name = "map",
		usage = "map COL = EXPR",
		doc = "A column made (or changed) by a Luau expression on r and n",
	},
	{ name = "count", usage = "count", doc = "How many rows there are" },
	{ name = "first", usage = "first [N]", doc = "The first N rows, one without N" },
	{ name = "last", usage = "last N", doc = "The last N rows" },
	{
		name = "uniq",
		usage = "uniq COL",
		doc = "The first row for each value in a column",
		args = "column",
	},
	{
		name = "sum",
		usage = "sum COL",
		doc = "The numbers in a column added up",
		args = "column",
	},
	{
		name = "group",
		usage = "group COL",
		doc = "Each value in a column and how many rows have it",
		args = "column",
	},
	{
		name = "to",
		usage = "to json|csv|tsv",
		doc = "The table as JSON, CSV or tab separated values",
		args = "format",
	},
	{
		name = "each",
		usage = "each COMMAND",
		doc = "Run a command for every row, {COL} in it the row's cell, quoted",
	},
} :: { Stage }

--- A condition: `COLUMN op VALUE`, read from text like "STATUS=Running" or
--- `AGE < 1h`, with quotes around the value taken off.
export type Condition = { column: string, op: string, value: string }

--- `text` read as a condition on a column of `tbl`, or nil and why not.
function M.condition(tbl: Table, text: string): (Condition?, string?)
	local at, stop, op = greed.compare.find(text)
	if at == nil or stop == nil or op == nil then
		return nil, "where COLUMN = VALUE (or !=, ~, !~, <, >, <=, >=)"
	end
	local name = trim(string.sub(text, 1, at - 1))
	local column = M.column(tbl, name)
	if column == nil then
		return nil, no_column(tbl, name)
	end
	local value = unquote(trim(string.sub(text, stop + 1)))
	return { column = column, op = op, value = value }, nil
end

--- The rows (indexes) of `tbl` that pass `condition`, from `rows` (all by
--- default).
function M.matching(tbl: Table, condition: Condition, rows: { number }?): { number }
	-- "1h" says the column holds durations, even when every age in it is in
	-- minutes.
	local durations = M.durations(tbl, condition.column)
		or greed.compare.is_duration(condition.value)
	local out: { number } = {}
	for _, i in rows or M.all(tbl) do
		local cell = tbl.rows[i][condition.column] or ""
		if greed.compare.test(cell, condition.op, condition.value, durations) then
			table.insert(out, i)
		end
	end
	return out
end

--- Whether `text` has `word` in it, as a filter typed in a block looks:
--- minding case as `shell-filter-search-case` says.
function M.has(text: string, word: string): boolean
	local case = core.search.case("shell-filter")
	if case == "match" or (case == "smart" and string.find(word, "%u")) then
		return string.find(text, word, 1, true) ~= nil
	end
	return string.find(string.lower(text), string.lower(word), 1, true) ~= nil
end

--- The rows (indexes) of `tbl` a filter typed in a block keeps: each word
--- of `text` is a condition on a column (`STATUS=Running`, `NAME~api`,
--- `RESTARTS>0`), or else text some cell of the row has in it, minding
--- case as `shell-filter-search-case` says. A row has to pass them all.
function M.filter(tbl: Table, text: string): { number }
	local rows = M.all(tbl)
	for word in string.gmatch(text, "%S+") do
		local condition = M.condition(tbl, word)
		if condition then
			rows = M.matching(tbl, condition, rows)
		else
			local kept: { number } = {}
			for _, i in rows do
				for _, column in tbl.columns do
					if M.has(tbl.rows[i][column] or "", word) then
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
		local order =
			greed.compare.order(tbl.rows[a][column] or "", tbl.rows[b][column] or "", durations)
		if order == 0 then
			return a < b
		end
		return if desc then order > 0 else order < 0
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
		local at = greed.compare.find(rest)
		if at then
			table.insert(names, trim(string.sub(rest, 1, at - 1)))
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

-- Why `word`, a stage, can't read text.
local function not_a_table(word: string): string
	return `{word} works on a table, and this isn't one; columns, from csv/tsv/json, split or lines make one`
end

-- A table of `columns` and `rows`.
local function new(columns: { string }, rows: { { [string]: string } }): Table
	return { columns = columns, rows = rows }
end

-- Runs an expression for every row, in a sandbox: it reads the editor and
-- nothing else, as what's typed here may come from an agent. A column that
-- isn't there, in `r` or `n`, says which there are; `n` of a cell that
-- isn't a number says to read it as text from `r`.
local PER_ROW = [==[
local json = require("@greed").json
local rows, numbers, columns = json.decode(%q), json.decode(%q), json.decode(%q)
local named = {}
for _, column in columns do
	named[column] = true
end
local function missing(name)
	error(`there's no column {name}; there's {table.concat(columns, ", ")}`, 0)
end
local out = {}
for i, row in rows do
	local r = setmetatable(row, { __index = function(_, name)
		if not named[name] then
			missing(name)
		end
		return nil
	end })
	local n = setmetatable(numbers[i] or {}, { __index = function(_, name)
		if not named[name] then
			missing(name)
		end
		local text = rawget(row, name)
		if text ~= nil and text ~= "" then
			error(`{name} isn't a number here ("{text}"); r.{name} is its text`, 0)
		end
		return nil
	end })
	out[i] = { v = (function() return %s end)() }
end
return json.encode(out)]==]

-- What `expr`, Luau, gives for each row of `tbl`, with the row's cells as
-- `r` and, those that read as numbers (sizes and ages too), as `n`; nil and
-- why when it fails.
local function per_row(tbl: Table, expr: string): ({ any }?, string?)
	if trim(expr) == "" then
		return nil,
			"it takes a Luau expression on the row r, or n for its numbers, like n.RESTARTS > 0"
	end
	local numbers: { { [string]: number } } = {}
	for i, row in tbl.rows do
		local n: { [string]: number } = {}
		for _, column in tbl.columns do
			local number = M.number(row[column] or "", M.durations(tbl, column))
			if number then
				n[column] = number
			end
		end
		numbers[i] = n
	end
	local code = string.format(
		PER_ROW,
		greed.json.encode(tbl.rows),
		greed.json.encode(numbers),
		greed.json.encode(tbl.columns),
		expr
	)
	local ok, result = greed.eval(code, { sandbox = true })
	if not ok then
		local message = string.match(result, "^[^\n]*") or result
		message = string.gsub(message, "^runtime error: ", "")
		return nil, (string.gsub(message, "^%a+:%d+: ", ""))
	end
	local decoded = greed.json.decode(result)
	local out: { any } = {}
	for i = 1, #tbl.rows do
		local item = if type(decoded) == "table" then decoded[i] else nil
		out[i] = if type(item) == "table" then item.v else nil
	end
	return out, nil
end

-- `cell` quoted for CSV when it has to be.
local function csv_cell(cell: string): string
	if string.find(cell, '[,"\n]') then
		return '"' .. string.gsub(cell, '"', '""') .. '"'
	end
	return cell
end

-- `tbl` as JSON (a list of objects), CSV or tab separated values.
local function to_format(tbl: Table, format: string): (string?, string?)
	if format == "json" then
		local list = {}
		for i, row in tbl.rows do
			list[i] = row
		end
		return greed.json.encode(greed.json.array(list)), nil
	elseif format ~= "csv" and format ~= "tsv" then
		return nil, "to json, to csv or to tsv"
	end
	local function line(cells: { string }): string
		local out = {}
		for i, cell in cells do
			out[i] = if format == "tsv" then (string.gsub(cell, "[\t\n]", " ")) else csv_cell(cell)
		end
		return table.concat(out, if format == "tsv" then "\t" else ",")
	end
	local lines = { line(tbl.columns) }
	for _, row in tbl.rows do
		local cells = {}
		for i, column in tbl.columns do
			cells[i] = row[column] or ""
		end
		table.insert(lines, line(cells))
	end
	return table.concat(lines, "\n"), nil
end

--- What a stage runs for: the block and its shell, when it runs in one
--- (not while a line is completed), so a stage can keep something from one
--- run of a watch to the next.
export type StageContext = { block: any?, shell: any? }

-- The stages working on a table's rows, by name: each makes a new table,
-- or, for `to`, text; nil and why when it can't.
local ROWS: { [string]: StageRun } = {
	count = function(tbl: Table): ((Table | string)?, string?)
		return new({ "count" }, { { count = tostring(#tbl.rows) } }), nil
	end,
	first = function(tbl: Table, rest: string): ((Table | string)?, string?)
		local count = if rest == "" then 1 else tonumber(rest)
		if count == nil then
			return nil, "first N, like first 5"
		end
		return new(tbl.columns, table.move(tbl.rows, 1, math.min(count, #tbl.rows), 1, {})), nil
	end,
	last = function(tbl: Table, rest: string): ((Table | string)?, string?)
		local count = tonumber(rest) or 1
		local from = math.max(#tbl.rows - count + 1, 1)
		return new(tbl.columns, table.move(tbl.rows, from, #tbl.rows, 1, {})), nil
	end,
	uniq = function(tbl: Table, rest: string): ((Table | string)?, string?)
		local column = M.column(tbl, rest)
		if column == nil then
			return nil, no_column(tbl, rest)
		end
		local seen: { [string]: boolean } = {}
		local kept = {}
		for _, row in tbl.rows do
			local cell = row[column] or ""
			if not seen[cell] then
				seen[cell] = true
				table.insert(kept, row)
			end
		end
		return new(tbl.columns, kept), nil
	end,
	sum = function(tbl: Table, rest: string): ((Table | string)?, string?)
		local column = M.column(tbl, rest)
		if column == nil then
			return nil, no_column(tbl, rest)
		end
		local durations = M.durations(tbl, column)
		local total = 0
		for _, row in tbl.rows do
			total += M.number(row[column] or "", durations) or 0
		end
		return new({ "sum" }, { { sum = as_text(total) } }), nil
	end,
	group = function(tbl: Table, rest: string): ((Table | string)?, string?)
		local column = M.column(tbl, rest)
		if column == nil then
			return nil, no_column(tbl, rest)
		end
		local counts: { [string]: number } = {}
		local order: { string } = {}
		for _, row in tbl.rows do
			local cell = row[column] or ""
			if counts[cell] == nil then
				counts[cell] = 0
				table.insert(order, cell)
			end
			counts[cell] += 1
		end
		local rows = {}
		for _, cell in order do
			table.insert(rows, { [column] = cell, count = tostring(counts[cell]) })
		end
		return new({ column, "count" }, rows), nil
	end,
	to = function(tbl: Table, rest: string): ((Table | string)?, string?)
		return to_format(tbl, string.lower(rest))
	end,
	filter = function(tbl: Table, rest: string): ((Table | string)?, string?)
		local results, why = per_row(tbl, rest)
		if results == nil then
			return nil, why
		end
		local kept = {}
		for i, row in tbl.rows do
			if results[i] ~= nil and results[i] ~= false then
				table.insert(kept, row)
			end
		end
		return new(tbl.columns, kept), nil
	end,
	map = function(tbl: Table, rest: string): ((Table | string)?, string?)
		local name, expr = string.match(rest, "^%s*([^=]-)%s*=%s*(.+)$")
		if name == nil or expr == nil or name == "" then
			return nil, "map NAME = EXPR, like map hours = n.AGE / 3600"
		end
		local results, why = per_row(tbl, expr)
		if results == nil then
			return nil, why
		end
		local column = M.column(tbl, name) or name
		local columns = table.clone(tbl.columns)
		if not table.find(columns, column) then
			table.insert(columns, column)
		end
		local rows = {}
		for i, row in tbl.rows do
			local copy = table.clone(row)
			copy[column] = as_text(results[i])
			rows[i] = copy
		end
		return new(columns, rows), nil
	end,
}

-- The stages taking text that isn't a table, as a table of its words.
local READS_TEXT: { [string]: boolean } = {}

-- `text` as a table of its lines' words: `0.52 0.48 0.40` is a row of
-- three, in columns named 1, 2 and so on. A first line without numbers
-- over lines with them is the header, as `kubectl top`'s `NAME
-- CPU(cores)` is; words past the header's last are in its last column.
-- Nil without any.
local function words_table(text: string): Table?
	local lines: { { string } } = {}
	local most = 0
	for line in string.gmatch(text, "[^\n]+") do
		local words: { string } = {}
		for word in string.gmatch(line, "%S+") do
			table.insert(words, word)
		end
		if #words > 0 then
			table.insert(lines, words)
			most = math.max(most, #words)
		end
	end
	if most == 0 then
		return nil
	end
	local function has_number(words: { string }): boolean
		for _, word in words do
			if M.number(word) then
				return true
			end
		end
		return false
	end
	local header = #lines > 1 and not has_number(lines[1]) and has_number(lines[2])
	local columns: { string } = {}
	if header then
		columns = table.remove(lines, 1) :: { string }
	else
		for n = 1, most do
			table.insert(columns, tostring(n))
		end
	end
	local rows: { { [string]: string } } = {}
	for _, words in lines do
		local row: { [string]: string } = {}
		for i, word in words do
			local column = columns[math.min(i, #columns)]
			row[column] = if i > #columns then `{row[column]} {word}` else word
		end
		table.insert(rows, row)
	end
	return { columns = columns, rows = rows }
end

-- Whether `word rest` is the row stage rather than the program of that
-- name: `uniq` and `sum` when they name a column, `last` with a number.
local function takes(word: string, input: Table?, rest: string): boolean
	if word == "uniq" or word == "sum" then
		return input ~= nil and M.column(input, rest) ~= nil
	elseif word == "last" then
		return input ~= nil and tonumber(rest) ~= nil
	end
	return true
end

--- Runs the table stages at the start of `line` (what follows `$3 |`) on
--- `tbl`, or on `text` for those reading text as a table, or on `value`
--- when the text was JSON: `where`, `select`, `sort` naming a column,
--- `columns`, `from csv`, `from tsv`, `from json`, `split SEP`, `lines`,
--- `get PATH`, and the row stages (`filter`, `map`, `count`, `first`,
--- `last`, `uniq`, `sum`, `group`, `to`). `each` is left in the rest of
--- the line, for the shell to run. Returns the table they made, the rest
--- of the line after them for a program to read as text, why they can't
--- run (like a column that isn't there) when they can't, and the JSON
--- `get` picked (or the text `to` made) when it isn't a table. All nil
--- when `line` starts with no stage.
function M.pipeline(
	tbl: Table?,
	text: string?,
	line: string,
	value: any?,
	ctx: StageContext?
): (Table?, string?, string?, any?)
	local current = tbl
	-- The JSON the stages read, while they've read nothing else.
	local json = value
	local parts = stages(line)
	local done = 0
	for i, part in parts do
		local word, args = string.match(part, "^%s*(%S+)%s*(.-)%s*$")
		local rest = args or ""
		-- `^NAME` is the program NAME, which ends the stages.
		if word and #word > 1 and string.sub(word, 1, 1) == "^" then
			parts[i] = (string.gsub(part, "%^", "", 1))
			break
		end
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
		elseif word and ROWS[word] and takes(word, input, rest) then
			if input == nil and READS_TEXT[word] then
				input =
					words_table(if done > 0 and json ~= nil then M.value_text(json) else text or "")
			end
			if input == nil then
				return nil, nil, not_a_table(word)
			end
			local made: (Table | string)?, why = ROWS[word](input, rest, ctx or {})
			if made == nil then
				return nil, nil, `{word}: {why}`
			elseif type(made) == "string" then
				-- `to` makes text, which ends the stages' tables.
				current, json = nil, made
			else
				current, json = made, nil
			end
		else
			break
		end
		done += 1
	end
	if done == 0 then
		return nil, nil, nil
	end
	local after = trim(table.concat(parts, "|", done + 1))
	return current, if after == "" then nil else after, nil, if current then nil else json
end

-- The stages a line can go on with after a program, as no program has
-- their names.
local STARTERS: { [string]: boolean } = {
	where = true,
	select = true,
	get = true,
	columns = true,
	from = true,
	lines = true,
	filter = true,
	map = true,
	count = true,
	group = true,
	first = true,
	to = true,
	each = true,
}

-- Stages that are programs' names too: after a program they're the stage
-- given an argument that isn't a flag (`sort size -r`, `last 2`), which
-- the program after a pipe has no use for, and the program otherwise
-- (`sort`, `sort -n`). `^sort` is always the program.
local SHARED: { [string]: boolean } = {
	sort = true,
	last = true,
	uniq = true,
	sum = true,
	split = true,
}

-- Whether `part` of a line, after a program, starts a stage.
local function starts_stage(part: string): boolean
	local word, first = string.match(part, "^%s*(%S+)%s*(%S*)")
	if word == nil or first == nil then
		return false
	end
	return STARTERS[word] == true
		or (SHARED[word] == true and first ~= "" and string.sub(first, 1, 1) ~= "-")
end

--- `line` cut where table stages start after programs, as in `kubectl get
--- pods | where STATUS != Running`: the programs, then the stages and
--- what follows them. Nil when no stage comes after a program.
function M.after_programs(line: string): (string?, string?)
	local parts = stages(line)
	for i = 2, #parts do
		if starts_stage(parts[i]) then
			return trim(table.concat(parts, "|", 1, i - 1)), trim(table.concat(parts, "|", i))
		end
	end
	return nil, nil
end

--- What a plugin's stage does with the table it gets, the rest of its
--- words and what it runs for: makes a table, or text (which ends the
--- tables, as `to` does), or gives nil and why it can't.
export type StageRun = (tbl: Table, rest: string, ctx: StageContext) -> ((Table | string)?, string?)

export type StageSpec = {
	name: string,
	--- How it's typed and what it does, for `help` and completion.
	usage: string,
	doc: string,
	--- What its arguments are, for completion: "column", "columns",
	--- "condition" or "format".
	args: string?,
	--- Whether it can follow a program too, as in `kubectl get pods |
	--- NAME`: only for names no program has.
	starts: boolean?,
	--- Whether it takes text that isn't a table too, as a table of its
	--- lines' words, in columns named 1, 2 and so on.
	text: boolean?,
}

--- Adds the table stage `spec.name`, which `run` does, in place of one a
--- plugin added before; the shell's own can't be replaced. After `$3 |`,
--- and after the shell's stages, it runs ahead of a program called the
--- same. It goes when the plugin that added it does.
function M.stage(spec: StageSpec, run: StageRun)
	local name = spec.name
	assert(string.match(name, "^[%w_%-]+$"), "a stage's name is one word")
	for _, other in M.STAGES do
		if other.name == name and other.plugin == nil then
			error(`{name} is one of the shell's own stages`, 2)
		end
	end
	local entry: Stage = {
		name = name,
		usage = spec.usage,
		doc = spec.doc,
		args = spec.args,
		plugin = greed.plugin.caller(),
	}
	greed.plugin.tie(core.registry.put(M.STAGES, entry, function(other: Stage): boolean
		return other.name == name
	end))
	greed.plugin.tie(core.registry.set(ROWS, name, run))
	if spec.starts then
		greed.plugin.tie(core.registry.set(STARTERS, name, true))
	end
	if spec.text then
		greed.plugin.tie(core.registry.set(READS_TEXT, name, true))
	end
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

--- Whether `command` is one `match` names: a program's name ("kubectl"),
--- or a Luau pattern for the whole command line ("^helm list").
function M.matches(match: string, command: string): boolean
	if match == M.program(command) then
		return true
	elseif not string.find(match, MAGIC) then
		return false
	end
	-- A pattern that isn't one matches nothing.
	local ok, found = pcall(function(): boolean
		return string.find(command, match) ~= nil
	end)
	return ok and found
end

--- `text`, what `command` printed, read as a table: by a parser a plugin
--- added for the command, or else by the shell's careful look for one
--- (`detect`). Nil when it's text.
function M.parse(text: string, command: string, block: any?): Table?
	for i = #parsers, 1, -1 do
		local entry = parsers[i]
		if M.matches(entry.match, command) then
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
