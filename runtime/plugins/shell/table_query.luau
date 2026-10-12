-- Querying a table: its columns, conditions and filters, sorting, and
-- fields of JSON.

local greed = require("@greed")
local core = require("@core")
local read = require("./table_read")

type Table = read.Table

core.search.kind("shell-filter", "ignore", "filtering a shell block with /")

local M = {}

local as_text, is_object = read.value_text, read.is_object
local trim, unquote = core.text.trim, core.text.unquote

--- The indexes of all of `tbl`'s rows, in order.
function M.all(tbl: Table): { number }
	local rows: { number } = {}
	for i = 1, #tbl.rows do
		rows[i] = i
	end
	return rows
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
		local value = read.json(row[outer] or "")
		local inner = if value ~= nil then M.get(value, path) else nil
		row[name] = if inner ~= nil then as_text(inner) else ""
		found = found or inner ~= nil
	end
	return if found then name else nil
end

--- Why `name` names no column of `tbl`.
function M.no_column(tbl: Table, name: string): string
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
				look(read.json(cell), column)
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
		return nil, M.no_column(tbl, name)
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
			return nil, M.no_column(tbl, name)
		end
		table.insert(columns, column)
	end
	if #columns == 0 then
		return nil, "select COLUMN,..."
	end
	return subset(tbl, M.all(tbl), columns), nil
end

--- `sort`'s words: the column and whether to reverse, or nil when they
--- don't name a column (then it's the sort program).
function M.sort_args(tbl: Table, text: string): (string?, boolean)
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
	local column, desc = M.sort_args(tbl, text)
	if column == nil then
		return nil, "sort COLUMN [-r]"
	end
	return subset(tbl, M.sorted(tbl, M.all(tbl), column, desc)), nil
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
		local found = read.from_value(field)
		if found then
			arrays += 1
			inner = found
		end
	end
	return read.from_value({ object }), if arrays == 1 then inner else nil
end

return M
