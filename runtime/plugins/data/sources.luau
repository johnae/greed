-- The data sources this plugin gives (see `core.data`): `csv`, a CSV file
-- or the block's own lines; `sqlite`, a query over a SQLite database by
-- the sqlite3 program; `psql`, a query over PostgreSQL by psql. A query's
-- `@name`s are the document's values, bound as parameters by the program,
-- never pasted into the query. Both open the database read-only unless
-- the block says `write=true`.

local greed = require("@greed")
local core = require("@core")
local shell = require("@shell")

type Table = core.DataTable
type Ask = core.DataAsk

local M = {}

-- How long a query may take before it's stopped, in milliseconds.
local TIMEOUT = 10000

greed.option.define({
	name = "data-sqlite3",
	needs = "proc",
	default = "sqlite3",
	doc = "The sqlite3 program the sqlite data source runs",
})

greed.option.define({
	name = "data-psql",
	needs = "proc",
	default = "psql",
	doc = "The psql program the psql data source runs",
})

-- `name` (a block's `path=` or `db=`) as a path: from the document's
-- folder unless it's absolute or from your home.
local function path_of(ask: Ask, name: string): string
	if string.sub(name, 1, 1) == "/" then
		return name
	end
	local home = greed.fs.dirs().home
	if home and string.sub(name, 1, 2) == "~/" then
		return home .. string.sub(name, 2)
	end
	return if ask.dir then `{ask.dir}/{name}` else name
end

-- What listens for each watched file to change.
local listening: { [string]: { () -> () } } = {}

greed.on("file.changed", function(event: greed.FileChanged)
	core.registry.tell(listening[event.path] or {})
end)

-- Calls `changed` when the file at `path` changes; gives what stops it.
local function on_change(path: string, changed: () -> ()): () -> ()
	greed.fs.watch(path)
	local list = listening[path] or {}
	listening[path] = list
	return core.registry.put(list, changed)
end

-- `t`'s rows from `ask.offset`, at most `ask.limit`, and whether there
-- are more; all of them without a limit.
local function page(t: Table, ask: Ask): Table
	local limit = ask.limit
	if limit == nil then
		return t
	end
	local from = (ask.offset or 0) + 1
	local rows = table.move(t.rows, from, math.min(from + limit - 1, #t.rows), 1, {})
	return { columns = t.columns, rows = rows, more = #t.rows >= from + limit }
end

-- `text` (CSV with a header) as a table, or why not.
local function from_csv(text: string): (Table?, string?)
	if string.match(text, "^%s*$") then
		return { columns = {}, rows = {} }, nil
	end
	local read = shell.tables.csv(text)
	if read == nil then
		return nil, "that isn't CSV"
	end
	return core.data.from_text(read), nil
end

-- `query` with each `@name` in it given to `each`, which says what goes
-- in its place. One right after another `@` is an operator (Postgres's
-- `@@`), not a value.
local function each_param(query: string, each: (name: string) -> string): string
	local out: { string } = {}
	local at = 1
	while true do
		local from, to, name = string.find(query, "@([%a_][%w_]*)", at)
		if from == nil or to == nil then
			break
		end
		table.insert(out, string.sub(query, at, from - 1))
		local operator = from > 1 and string.sub(query, from - 1, from - 1) == "@"
		table.insert(out, if operator then string.sub(query, from, to) else each(name :: string))
		at = to + 1
	end
	table.insert(out, string.sub(query, at))
	return table.concat(out)
end

--- The `@name`s in `query`, each once, in order: the values it binds.
function M.params(query: string): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	each_param(query, function(name: string): string
		if not seen[name] then
			seen[name] = true
			table.insert(out, name)
		end
		return ""
	end)
	return out
end

-- `query` read `limit` rows (and one more, to tell there are more) from
-- `offset`, when it's a SELECT and the ask has a limit; else as it is.
local function paged(query: string, ask: Ask): string
	local q = string.gsub(query, "[%s;]+$", "")
	local lower = string.lower(q)
	local limit = ask.limit
	if
		limit == nil
		or not (string.match(lower, "^%s*select%f[%W]") or string.match(lower, "^%s*with%f[%W]"))
	then
		return q .. ";"
	end
	return `SELECT * FROM (\n{q}\n) LIMIT {limit + 1} OFFSET {ask.offset or 0};`
end

-- What a program printed as CSV, cut to the ask's page.
local function read_csv_output(text: string, ask: Ask): (Table?, string?)
	local t, why = from_csv(text)
	if t == nil then
		return nil, why
	end
	-- The query read one row past the page, so it's known there are more.
	local limit = ask.limit
	if limit and #t.rows > limit then
		t.rows = table.move(t.rows, 1, limit, 1, {})
		t.more = true
	end
	return t, nil
end

-- What went wrong running a program: its first line of errors, else how
-- it ended.
local function failed(name: string, ran: any): string
	local first = string.match(ran.stderr or "", "^%s*([^\n]+)")
	return first or `{name} ended with {ran.code}`
end

-- `value` as a SQL literal, for sqlite3's `.parameter set`.
local function sql_literal(value: any): (string?, string?)
	if value == nil then
		return "NULL", nil
	elseif type(value) == "number" then
		return core.data.show(value), nil
	elseif type(value) == "boolean" then
		return if value then "1" else "0", nil
	elseif type(value) == "string" then
		return "'" .. string.gsub(value, "'", "''") .. "'", nil
	end
	return nil, `a {type(value)} can't be a query's value`
end

--- `query` and its values as sqlite3 reads them on its input: each value
--- set as a parameter, then the query. A value is a SQL literal inside a
--- quoted argument, so nothing in it reads as SQL.
function M.sqlite_input(query: string, values: { [string]: any }): (string?, string?)
	local lines = { ".parameter init" }
	for _, name in M.params(query) do
		local literal, why = sql_literal(values[name])
		if literal == nil then
			return nil, `@{name}: {why}`
		end
		local quoted = string.gsub(literal, '[\\"]', "\\%0")
		quoted = string.gsub(quoted, "\n", "\\n")
		table.insert(lines, `.parameter set @{name} "{quoted}"`)
	end
	table.insert(lines, query)
	return table.concat(lines, "\n") .. "\n", nil
end

--- `query` for psql: each `@name` as psql's quoted variable `:'name'`,
--- and the `-v name=value` arguments setting them.
function M.psql_args(query: string, values: { [string]: any }): (string, { string }?, string?)
	local args: { string } = {}
	for _, name in M.params(query) do
		local value = values[name]
		if type(value) == "table" or type(value) == "function" then
			return query, nil, `@{name}: a {type(value)} can't be a query's value`
		end
		table.insert(args, "-v")
		table.insert(args, `{name}={if value == nil then "" else core.data.show(value)}`)
	end
	local rewritten = each_param(query, function(name: string): string
		return `:'{name}'`
	end)
	return rewritten, args, nil
end

core.data.source({
	name = "csv",
	doc = "A CSV file with a header, path=FILE beside the document, or the block's own lines",
	read = function(ask: Ask): (Table?, string?)
		local name = ask.args.path
		local text = ask.body
		if name then
			local read = greed.fs.read(path_of(ask, name))
			if read == nil then
				return nil, `can't read {name}`
			end
			text = read
		end
		local t, why = from_csv(text)
		return if t then page(t, ask) else nil, why
	end,
	watch = function(ask: Ask, changed: () -> ()): () -> ()
		local name = ask.args.path
		return if name then on_change(path_of(ask, name), changed) else function() end
	end,
})

core.data.source({
	name = "sqlite",
	doc = "A query over the SQLite database db=FILE, by sqlite3; @name is the document's value",
	runs = true,
	read = function(ask: Ask): (Table?, string?)
		local db = ask.args.db
		if db == nil then
			return nil, "sqlite needs db=FILE"
		end
		local input, why = M.sqlite_input(paged(ask.body, ask), ask.values)
		if input == nil then
			return nil, why
		end
		local command = { greed.option.get("data-sqlite3") :: string, "-safe", "-csv", "-header" }
		if ask.args.write ~= "true" then
			table.insert(command, "-readonly")
		end
		table.insert(command, path_of(ask, db))
		local ran, err =
			greed.process.run(command, { stdin = input, timeout = TIMEOUT, cwd = ask.dir })
		if ran == nil then
			return nil, `sqlite3 didn't start: {err}`
		elseif ran.timed_out then
			return nil, "the query took longer than 10 seconds"
		elseif ran.code ~= 0 or ran.stderr ~= "" then
			return nil, failed("sqlite3", ran)
		end
		return read_csv_output(ran.stdout, ask)
	end,
	watch = function(ask: Ask, changed: () -> ()): () -> ()
		local db = ask.args.db
		return if db then on_change(path_of(ask, db), changed) else function() end
	end,
})

core.data.source({
	name = "psql",
	doc = "A query over PostgreSQL by psql, db=CONNECTION (else psql's own settings); @name is the document's value",
	runs = true,
	read = function(ask: Ask): (Table?, string?)
		local query, args, why = M.psql_args(paged(ask.body, ask), ask.values)
		if args == nil then
			return nil, why
		end
		local command = {
			greed.option.get("data-psql") :: string,
			"-X",
			"-q",
			"--csv",
			"-v",
			"ON_ERROR_STOP=1",
		}
		if ask.args.db then
			table.insert(command, "-d")
			table.insert(command, ask.args.db)
		end
		table.move(args, 1, #args, #command + 1, command)
		table.insert(command, "-f")
		table.insert(command, "-")
		local env: { [string]: string | false } = {}
		if ask.args.write ~= "true" then
			env.PGOPTIONS = "-c default_transaction_read_only=on"
		end
		local ran, err = greed.process.run(
			command,
			{ stdin = query, env = env, timeout = TIMEOUT, cwd = ask.dir }
		)
		if ran == nil then
			return nil, `psql didn't start: {err}`
		elseif ran.timed_out then
			return nil, "the query took longer than 10 seconds"
		elseif ran.code ~= 0 then
			return nil, failed("psql", ran)
		end
		return read_csv_output(ran.stdout, ask)
	end,
})

return M
