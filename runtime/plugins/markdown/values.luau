-- Live values in Markdown: `{{ formula }}` shows what the formula works out
-- to, `<!-- let name = formula -->` names a value for the rest of the
-- file, and `[42](field:bill)` is a field, its value between the brackets,
-- set with enter or a click. Formulas are Luau's expressions, worked out
-- by `core.formula`, never run as code, so they work in any file without
-- asking. Their names come from fields, `let`s, named questions' answers
-- (questions.luau), and tables named by an `<!-- id=name -->` line right
-- above them: `costs[1].item` a cell, `costs.amount` a column by its
-- header's words (lowercase, spaces as `_`).
--
--     Bill: [42.50](field:bill)
--     <!-- let tip = bill * 0.15 -->
--     Tip: {{ fixed(tip) }}, in all {{ fixed(bill + tip) }}
--
-- On GitHub and the like, the comments don't show, a field shows as a
-- link and a value as its formula.

local greed = require("@greed")
local core = require("@core")
local structure = require("./structure")
local tables = require("./tables")
local questions = require("./questions")

type Structure = structure.Structure

local formula = core.formula

local M = {}

--- A field: its name, its value as written, and where the value is in the
--- buffer (0-based, `to` past its end).
export type Field = { name: string, value: string, from: number, to: number }

--- A column a formula fills, from a `<!-- formula: key = formula -->`
--- line under its table.
export type Column = { key: string, source: string }

--- A table as its text says: its rows, and its columns by name, as
--- formulas see it (`raw`), and the columns formulas fill.
export type Sheet = { raw: any, columns: { Column } }

--- What a file's formulas can name, as its text says now: `let`s, fields
--- and named tables; answers come from the buffer as it's drawn. `key`
--- changes when any of them does.
export type Found = {
	lets: { [string]: string },
	fields: { Field },
	tables: { [string]: Sheet },
	key: string,
}

--- A cell a formula filled, as it shows, and whether it went wrong.
export type Worked = { text: string, failed: boolean }

-- A column's name from its header: lowercase, other than letters and
-- digits as `_`.
local function key_of(header: string): string
	return (string.gsub(string.lower(header), "[^%w]+", "_"))
end

-- A cell's text as a value: a number when it reads as one.
local function value_of(text: string): any
	local n = tonumber(text)
	return if n then n else text
end

-- The rows of the table from line `first` to `last` of `s` (0-based), by
-- their header's words, with each column as a list under its name too.
local function table_value(s: Structure, first: number, last: number): (any, { string })
	local function texts(n: number): { string }
		local line = s.lines[n + 1]
		local out: { string } = {}
		local cells: { tables.Cell } = tables.cells(line) or {}
		for _, cell in cells do
			local text = string.sub(line, cell.from, cell.to)
			table.insert(out, (string.match(text, "^%s*(.-)%s*$") or ""))
		end
		return out
	end
	local keys: { string } = {}
	for _, header in texts(first) do
		table.insert(keys, key_of(header))
	end
	local out: any = {}
	for _, key in keys do
		out[key] = {}
	end
	for n = first + 2, last do
		local row: { [string]: any } = {}
		for i, text in texts(n) do
			local key = keys[i]
			if key then
				row[key] = value_of(text)
				table.insert(out[key], row[key])
			end
		end
		table.insert(out, row)
	end
	return out, keys
end

-- The formula lines right under the table ending on line `last` of `s`
-- (0-based).
local function formulas_below(s: Structure, last: number): { Column }
	local out: { Column } = {}
	local n = last + 1
	while s.lines[n + 1] do
		local key, source = string.match(
			s.lines[n + 1],
			"^%s*<!%-%-%s*formula:%s*([%a_][%w_]*)%s*=%s*(.-)%s*%-%->%s*$"
		)
		if key == nil then
			break
		end
		table.insert(out, { key = key :: string, source = source :: string })
		n += 1
	end
	return out
end

-- `source`, a formula, worked out in `scope`: its value, or what went wrong.
local function work(source: string, scope: core.FormulaScope): (any, string?)
	local f, err = formula.compile(source)
	if f == nil then
		return nil, err
	end
	return formula.eval(f, scope)
end

-- `raw` (a table's value) with `columns` worked out into each row, in
-- order: a formula names its row's cells first, then `prev` for the row
-- before, then `scope`. Also gives each worked-out cell by row and key.
local function work_rows(
	raw: any,
	columns: { Column },
	scope: (name: string) -> any
): (any, { { [string]: Worked } })
	local shown: { { [string]: Worked } } = {}
	if #columns == 0 then
		return raw, shown
	end
	local rows: any = {}
	local prev: any = nil
	for i, cells in ipairs(raw) do
		local row = table.clone(cells)
		local function lookup(name: string): any
			local cell = row[name]
			if cell ~= nil then
				return cell
			elseif name == "prev" then
				return prev
			end
			return scope(name)
		end
		shown[i] = {}
		for _, column in columns do
			local value, err = work(column.source, lookup)
			row[column.key] = value
			shown[i][column.key] = if err
				then { text = `⚠ {err}`, failed = true }
				else { text = formula.show(value), failed = false }
		end
		table.insert(rows, row)
		prev = row
	end
	-- Each column as a list by its name too, formulas' among them.
	for key in raw do
		if type(key) == "string" then
			rows[key] = {}
		end
	end
	for _, column in columns do
		rows[column.key] = {}
	end
	for _, row in ipairs(rows) do
		for key, list in rows do
			if type(key) == "string" then
				table.insert(list, row[key])
			end
		end
	end
	return rows, shown
end

-- What each structure's formulas can name, kept while it's the buffer's.
local found: { [Structure]: Found } = setmetatable({}, { __mode = "k" }) :: any

--- What `s`'s formulas can name.
function M.found(s: Structure): Found
	local known = found[s]
	if known then
		return known
	end
	local result: Found = { lets = {}, fields = {}, tables = {}, key = "" }
	local key: { string } = {}
	for i, line in s.lines do
		local n = i - 1
		if s.code_at[n] then
			continue
		end
		for name, source in string.gmatch(line, "<!%-%-%s*let%s+([%a_][%w_]*)%s*=%s*(.-)%s*%-%->") do
			result.lets[name :: string] = source :: string
			table.insert(key, `let {name}={source}`)
		end
		for at, value, name in string.gmatch(line, "()%[([^%]]*)%]%(field:([%a_][%w_]*)%)") do
			local from = s.starts[i] + (at :: number)
			table.insert(result.fields, {
				name = name :: string,
				value = value :: string,
				from = from,
				to = from + #(value :: string),
			})
			table.insert(key, `field {name}={value}`)
		end
		local id = string.match(line, "^%s*<!%-%-%s*id=([%w_]+)%s*%-%->%s*$")
		local below = s.table_at[n + 1]
		if id and below and below.first == n + 1 then
			local columns = formulas_below(s, below.last)
			result.tables[id] =
				{ raw = (table_value(s, below.first, below.last)), columns = columns }
			for row = below.first, below.last + #columns do
				table.insert(key, s.lines[row + 1])
			end
		end
	end
	-- A table something's drawn from below (formulas, a chart), named or
	-- not: an edit to it changes what's drawn there.
	for _, tbl in s.tables do
		if string.match(s.lines[tbl.last + 2] or "", "^%s*<!%-%-") then
			for row = tbl.first, tbl.last do
				table.insert(key, s.lines[row + 1])
			end
		end
	end
	result.key = table.concat(key, "\n")
	found[s] = result
	return result
end

--- The scope `buffer`'s formulas are worked out in: its fields, tables,
--- answers and `let`s, each `let` worked out when it's first named.
function M.scope(buffer: greed.Buffer, s: Structure?): (name: string) -> any
	local known = M.found(s or structure.of(buffer))
	local values: { [string]: any } = {}
	for name, answer in questions.answers(buffer) do
		values[name] = value_of(answer)
	end
	for _, field in known.fields do
		if values[field.name] == nil then
			values[field.name] = value_of(field.value)
		end
	end
	local working: { [string]: boolean } = {}
	local worked: { [string]: { value: any, err: string? } } = {}
	local function lookup(name: string): any
		local value = values[name]
		if value ~= nil then
			return value
		end
		-- A table with its formulas worked out, or a `let`: each once.
		local sheet, source = known.tables[name], known.lets[name]
		if sheet == nil and source == nil then
			return nil
		end
		local done = worked[name]
		if done == nil then
			if working[name] then
				error({ formula = `{name} depends on itself` }, 0)
			end
			working[name] = true
			local v: any, err: string? = nil, nil
			if sheet then
				v = work_rows(sheet.raw, sheet.columns, lookup)
			else
				v, err = work(source :: string, lookup)
			end
			working[name] = nil
			done = { value = v, err = if err then `{name}: {err}` else nil }
			worked[name] = done
		end
		if done.err then
			error({ formula = done.err }, 0)
		end
		return done.value
	end
	return lookup
end

--- What `source`, a formula, shows as in `scope`: its value, or what went
--- wrong after a ⚠, and whether it went wrong.
function M.show(source: string, scope: core.FormulaScope): (string, boolean)
	local value, err = work(source, scope)
	if err == nil then
		return formula.show(value), false
	end
	return `⚠ {err}`, true
end

--- The cells formulas fill in the table `found` of `buffer`, by their row
--- (the header row 1, as the table look counts them) and column; nil for a
--- table without formulas.
function M.worked(
	buffer: greed.Buffer,
	s: Structure,
	found: structure.Table
): { [number]: { [number]: Worked } }?
	local columns = formulas_below(s, found.last)
	if #columns == 0 then
		return nil
	end
	local raw, keys = table_value(s, found.first, found.last)
	local _, shown = work_rows(raw, columns, M.scope(buffer, s))
	local out: { [number]: { [number]: Worked } } = {}
	for i, cells in shown do
		local row: { [number]: Worked } = {}
		for c, key in keys do
			row[c] = cells[key]
		end
		out[i + 1] = row
	end
	return out
end

--- A table's data, its formulas worked out, for a plugin drawing from it
--- (a chart): its columns' keys in order (those of its header, then any a
--- formula fills that the header doesn't have) and each row by key.
export type Data = { keys: { string }, rows: { { [string]: any } } }

--- The data of the table `found` in `buffer`.
function M.data(buffer: greed.Buffer, s: Structure, found: structure.Table): Data
	local columns = formulas_below(s, found.last)
	local raw, keys = table_value(s, found.first, found.last)
	local rows = work_rows(raw, columns, M.scope(buffer, s))
	local all = table.clone(keys)
	for _, column in columns do
		if not table.find(all, column.key) then
			table.insert(all, column.key)
		end
	end
	local list: { { [string]: any } } = {}
	for _, row in ipairs(rows) do
		table.insert(list, row)
	end
	return { keys = all, rows = list }
end

-- Whether byte `at` of `line` is inside a code span.
local function in_code(line: string, at: number): boolean
	local ticks = 0
	for _ in string.gmatch(string.sub(line, 1, at - 1), "`") do
		ticks += 1
	end
	return ticks % 2 == 1
end

--- The marks for lines `first` to `last` of `buffer`: each `{{ }}` showing
--- its value, each field as a box holding its value to set.
function M.marks(buffer: greed.Buffer, s: Structure, first: number, last: number): { greed.Mark }
	local out: { greed.Mark } = {}
	local scope: core.FormulaScope? = nil
	for n = first, math.min(last, #s.lines - 1) do
		local line = s.lines[n + 1]
		if
			s.code_at[n]
			or not (string.find(line, "{{", 1, true) or string.find(line, "field:", 1, true))
		then
			continue
		end
		local start = s.starts[n + 1]
		for from, source, to in string.gmatch(line, "(){{(.-)}}()") do
			if not in_code(line, from :: number) then
				scope = scope or M.scope(buffer, s)
				local shown, failed = M.show(source :: string, scope :: core.FormulaScope)
				table.insert(out, {
					from = start + (from :: number) - 1,
					to = start + (to :: number) - 1,
					style = if failed then "markdown.value.error" else "markdown.value",
					text = shown,
					conceal = true,
					reveal = "auto" :: "auto",
				})
			end
		end
		for from, value, to in string.gmatch(line, "()%[([^%]]*)%]%(field:[%a_][%w_]*%)()") do
			if not in_code(line, from :: number) then
				local text = if value == "" then "    " else value :: string
				table.insert(out, {
					from = start + (from :: number) - 1,
					to = start + (to :: number) - 1,
					style = "markdown.field",
					text = `[ {text} ]`,
					conceal = true,
					reveal = "auto" :: "auto",
					action = "markdown-field-set",
				})
			end
		end
	end
	return out
end

--- The field in `buffer` at `pos`, if there's one.
function M.field_at(buffer: greed.Buffer, pos: number): Field?
	local s = structure.of(buffer)
	local line = buffer:line_of(pos)
	local start = s.starts[line + 1]
	local text = s.lines[line + 1] or ""
	for from, to in string.gmatch(text, "()%[[^%]]*%]%(field:[%a_][%w_]*%)()") do
		if pos >= start + (from :: number) - 1 and pos < start + (to :: number) - 1 then
			for _, field in M.found(s).fields do
				if field.from == start + (from :: number) then
					return field
				end
			end
		end
	end
	return nil
end

--- Sets `field` of `buffer` to `value`, in its text.
function M.set(buffer: greed.Buffer, field: Field, value: string)
	-- A field's value can't hold what would end it.
	local clean = string.gsub(value, "[%]\n]", "")
	buffer:edit(function(e)
		e:replace(field.from, field.to, clean)
	end)
end

greed.command({
	name = "markdown-field-set",
	doc = "Set the value of the field at the cursor, [value](field:name) in Markdown",
	run = function(ctx)
		local field = M.field_at(ctx.buffer, ctx.view:cursor())
		if field == nil then
			greed.echo("there's no field here")
			return
		end
		local typed = core.prompt.ask(field.name, field.value)
		if typed ~= nil then
			M.set(ctx.buffer, field, typed)
		end
	end,
})

return M
