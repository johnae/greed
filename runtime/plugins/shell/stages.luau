-- The table stages after `$3 |`: the list of them, the ones working on
-- rows, plugins' own, and running a line of them.

local greed = require("@greed")
local core = require("@core")
local read = require("./table_read")
local query = require("./table_query")
local draw = require("./table_draw")

type Table = read.Table

local M = {}

local trim, unquote = core.text.trim, core.text.unquote

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
		doc = "The rows passing tests: = != ~ !~ < > <= >=, with OR and -",
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
		name = "parse",
		usage = "parse 'PROGRAM'",
		doc = "A row for each match of a sikt program, its captures the columns",
	},
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
			return read.columns(text, header), "there's nothing in it"
		end
	elseif word == "from" and (rest == "csv" or rest == "tsv") then
		local sep = if rest == "csv" then "," else "\t"
		return function(text: string): (Table?, string)
			return read.csv(text, sep), "there's nothing in it"
		end
	elseif word == "from" and rest == "json" then
		return function(text: string): (Table?, string)
			return read.from_json(text), "it isn't JSON, or JSON lines"
		end
	elseif word == "split" and rest ~= "" and string.sub(rest, 1, 1) ~= "-" then
		local sep = unquote(rest)
		if sep == rest and string.find(rest, "%s") then
			return nil
		end
		return function(text: string): (Table?, string)
			return read.split(text, sep), ""
		end
	elseif word == "lines" and rest == "" then
		return function(text: string): (Table?, string)
			return read.lines(text), ""
		end
	elseif word == "parse" and rest ~= "" then
		local source = unquote(rest)
		return function(text: string): (Table?, string)
			local tbl, why = read.sikt(text, source)
			return tbl, why or ""
		end
	end
	return nil
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

-- The table stage `word` with `rest` works on in JSON object `object`: its
-- own fields when they're the columns named, else the array of objects a
-- field holds.
local function object_table(object: any, word: string, rest: string): Table?
	local own, inner = query.object_tables(object)
	if own == nil or inner == nil then
		return own
	end
	for _, name in named_columns(word, rest) do
		if query.column(own, name) == nil then
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
			local number = query.number(row[column] or "", query.durations(tbl, column))
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
		local column = query.column(tbl, rest)
		if column == nil then
			return nil, query.no_column(tbl, rest)
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
		local column = query.column(tbl, rest)
		if column == nil then
			return nil, query.no_column(tbl, rest)
		end
		local durations = query.durations(tbl, column)
		local total = 0
		for _, row in tbl.rows do
			total += query.number(row[column] or "", durations) or 0
		end
		return new({ "sum" }, { { sum = read.value_text(total) } }), nil
	end,
	group = function(tbl: Table, rest: string): ((Table | string)?, string?)
		local column = query.column(tbl, rest)
		if column == nil then
			return nil, query.no_column(tbl, rest)
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
		local column = query.column(tbl, name) or name
		local columns = table.clone(tbl.columns)
		if not table.find(columns, column) then
			table.insert(columns, column)
		end
		local rows = {}
		for i, row in tbl.rows do
			local copy = table.clone(row)
			copy[column] = read.value_text(results[i])
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
			if query.number(word) then
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
		return input ~= nil and query.column(input, rest) ~= nil
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
		if input == nil and read.is_object(json) and word then
			input = object_table(json, word, rest)
		end
		if convert then
			-- The text as it came, or what the stages before made.
			local from = if done > 0 and current
				then draw.text(current)
				elseif done > 0 and json ~= nil then read.value_text(json)
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
			local found, why = query.get(json, rest)
			if why then
				return nil, nil, `get: {why}`
			end
			json = found
			current = read.from_value(found)
		elseif word == "where" or word == "select" then
			if input == nil then
				return nil, nil, not_a_table(word)
			end
			local made: Table?, why: string?
			if word == "where" then
				made, why = query.where(input, rest)
			else
				made, why = query.select(input, rest)
			end
			if made == nil then
				return nil, nil, `{word}: {why}`
			end
			current, json = made, nil
		elseif word == "sort" and input and query.sort_args(input, rest) then
			current, json = query.sort(input, rest), nil
		elseif word and ROWS[word] and takes(word, input, rest) then
			if input == nil and READS_TEXT[word] then
				input = words_table(
					if done > 0 and json ~= nil then read.value_text(json) else text or ""
				)
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
	parse = true,
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
	greed.plugin.cleanup(core.registry.put(M.STAGES, entry, function(other: Stage): boolean
		return other.name == name
	end))
	greed.plugin.cleanup(core.registry.set(ROWS, name, run))
	if spec.starts then
		greed.plugin.cleanup(core.registry.set(STARTERS, name, true))
	end
	if spec.text then
		greed.plugin.cleanup(core.registry.set(READS_TEXT, name, true))
	end
end

return M
