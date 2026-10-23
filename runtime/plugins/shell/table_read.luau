-- Reading a command's output as a table: aligned columns under a header,
-- `ls -l`'s lines, CSV, JSON, and what plugins' parsers make of it.

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
	local lines = core.text.split_lines((string.gsub(text, "\r", "")))
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

--- Whether `value` is a JSON object (and not an array).
function M.is_object(value: any): boolean
	return type(value) == "table" and #value == 0 and next(value) ~= nil
end

--- A JSON value as a stage prints it: a string as it is, a number as
--- written, anything else as JSON.
function M.value_text(value: any): string
	return as_text(value)
end

-- Sikt programs compiled, by their source.
local compiled: { [string]: greed.SiktProgram } = {}

-- The sikt program `source`, compiled once; nil and why when it has a
-- mistake.
local function compile(source: string): (greed.SiktProgram?, string?)
	local known = compiled[source]
	if known then
		return known, nil
	end
	local program, why = greed.sikt.compile(source)
	if program then
		compiled[source] = program
	end
	return program, why
end

--- `text` read with the sikt program `source`: a row for each match, a
--- column for each capture (in the program's order) holding the text it
--- matched. Off the editor's thread where the caller can wait. Nil and why
--- when the program has a mistake.
function M.sikt(text: string, source: string): (Table?, string?)
	local program, why = compile(source)
	if program == nil then
		return nil, why
	end
	local rows: { greed.SiktRow }, places: { greed.SiktPlace }
	if coroutine.isyieldable() then
		local all, where = program:rows_many({ text }, { at = true, text = true })
		rows, places = all[1], (where :: { { greed.SiktPlace } })[1]
	else
		local found, where = program:rows(text, { at = true, text = true })
		rows, places = found, where :: { greed.SiktPlace }
	end
	local columns: { string } = {}
	for _, capture in program.captures do
		table.insert(columns, capture.name)
	end
	local at: { number } = {}
	for i, place in places do
		at[i] = place.line
	end
	return { columns = columns, rows = rows :: any, at = at }, nil
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
--- Luau pattern for the whole command line ("^helm list"). `parse` is a
--- function, or a sikt program whose captures are the columns (see
--- `M.sikt`), leaving output it finds nothing in to the shell. The latest
--- added is asked first. It goes when the plugin that added it does.
function M.parser(match: string, parse: Parser | string)
	local read: Parser
	if type(parse) == "string" then
		local _, why = compile(parse)
		if why then
			error(`the parser for {match}: {why}`, 2)
		end
		read = function(text: string): any
			local tbl = M.sikt(text, parse)
			return if tbl and #tbl.rows > 0 then tbl else nil
		end
	else
		read = parse
	end
	greed.plugin.cleanup(core.registry.put(parsers, { match = match, parse = read }))
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
