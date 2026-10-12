-- Tables of data, one shape wherever they come from and go: a shell
-- block's output, a Markdown table with its formulas worked out, a query
-- over a database. Charts, formulas and documents read this shape.
--
-- A source says where tables come from: a plugin registers one with a
-- name, and `read` gives the table an `Ask` asks for. Reading may wait (a
-- program, a query), so it runs where code can wait, never in a draw. The
-- values an ask carries are bound as a query's parameters by the source,
-- never pasted into it.
--
--     core.data.source({
--         name = "csv",
--         doc = "A CSV file, path=FILE beside the document",
--         read = function(ask) ... return table end,
--     })

local greed = require("@greed")
local registry = require("./registry")
local formula = require("./formula")

local M = {}

--- What a column holds, when its source says or it can be told: numbers,
--- text, a time (text a time reads from, as ISO 8601), or true and false.
export type Kind = "text" | "number" | "time" | "bool"

export type Column = { name: string, kind: Kind? }

--- Rows under named columns: each row's values by column name, nil when
--- empty. `more` says there are rows past these, for paging.
export type Table = { columns: { Column }, rows: { { [string]: any } }, more: boolean? }

--- What a source is asked for: the settings it's given (a document's
--- block's `db=`, `path=`), its text (a query), the values the text names
--- (a document's fields and the like, to bind as parameters), the folder
--- paths are from, and which rows: from `offset` (0 first), at most `limit`.
export type Ask = {
	args: { [string]: string },
	body: string,
	values: { [string]: any },
	dir: string?,
	limit: number?,
	offset: number?,
}

--- Where tables come from. `read` may wait; it gives the table or why
--- there's none. `watch`, if given, calls `changed` when the table may be
--- different (its file changed) and gives back what stops watching.
--- `runs` says it runs programs or reaches a service, so what asks for it
--- in a file asks you first, as a code block does.
export type Source = {
	name: string,
	doc: string?,
	runs: boolean?,
	read: (ask: Ask) -> (Table?, string?),
	watch: ((ask: Ask, changed: () -> ()) -> () -> ())?,
}

local sources: { Source } = {}

--- Adds `source`, in place of one of the same name. It goes when the
--- plugin that added it does.
function M.source(source: Source)
	greed.plugin.tie(registry.put(sources, source, function(other: Source): boolean
		return other.name == source.name
	end))
end

--- The source named `name`, if there's one.
function M.get(name: string): Source?
	for _, source in sources do
		if source.name == name then
			return source
		end
	end
	return nil
end

--- Every source, by name.
function M.sources(): { Source }
	local out = table.clone(sources)
	table.sort(out, function(a: Source, b: Source): boolean
		return a.name < b.name
	end)
	return out
end

--- `text` as the value it reads as: a number when it's one, else the text,
--- nil when it's empty.
function M.value(text: string?): any
	if text == nil or text == "" then
		return nil
	end
	local n = tonumber(text)
	return if n then n else text
end

--- `value` as text, as a table shows it.
M.show = formula.show

--- A table of text cells, `{ columns, rows }` as the shell reads one, as
--- values: a column whose every cell reads as a number holds numbers.
function M.from_text(t: { columns: { string }, rows: { { [string]: string } } }): Table
	local columns: { Column } = {}
	for _, name in t.columns do
		local numbers, any = true, false
		for _, row in t.rows do
			local cell = row[name]
			if cell ~= nil and cell ~= "" then
				any = true
				numbers = numbers and tonumber(cell) ~= nil
			end
		end
		local kind: Kind = if any and numbers then "number" else "text"
		table.insert(columns, { name = name, kind = kind })
	end
	local rows: { { [string]: any } } = {}
	for _, row in t.rows do
		local out: { [string]: any } = {}
		for _, column in columns do
			local cell = row[column.name]
			out[column.name] = if column.kind == "number" then M.value(cell) else cell
		end
		table.insert(rows, out)
	end
	return { columns = columns, rows = rows }
end

--- `t` as text cells, each value as `show` shows it, "" when empty.
function M.text(t: Table): { columns: { string }, rows: { { [string]: string } } }
	local names = M.names(t)
	local rows: { { [string]: string } } = {}
	for _, row in t.rows do
		local out: { [string]: string } = {}
		for _, name in names do
			out[name] = M.show(row[name])
		end
		table.insert(rows, out)
	end
	return { columns = names, rows = rows }
end

--- The names of `t`'s columns, in order.
function M.names(t: Table): { string }
	local out: { string } = {}
	for _, column in t.columns do
		table.insert(out, column.name)
	end
	return out
end

-- Whether `t` is a table as sources give them, and if not why.
local function check(t: any): string?
	if type(t) ~= "table" or type(t.columns) ~= "table" or type(t.rows) ~= "table" then
		return "a source gives { columns, rows }"
	end
	for i, column in t.columns do
		if type(column) ~= "table" or type(column.name) ~= "string" then
			return `column {i} has no name`
		end
	end
	return nil
end

--- What source `name` reads for `ask`: the table, or why there's none (no
--- such source, it failed or it gave something that isn't a table). Waits
--- as the source does, so only where code can wait.
function M.read(name: string, ask: Ask): (Table?, string?)
	local source = M.get(name)
	if source == nil then
		return nil, `there's no data source called {name}`
	end
	local ok, t, why = pcall(source.read, ask)
	if not ok then
		return nil, tostring(t)
	elseif t == nil then
		return nil, why or `{name} gave nothing`
	end
	local wrong = check(t)
	if wrong then
		return nil, `{name}: {wrong}`
	end
	return t, nil
end

return M
