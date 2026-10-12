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

--- What a file's formulas can name, as its text says now: `let`s, fields
--- and named tables; answers come from the buffer as it's drawn. `key`
--- changes when any of them does.
export type Found = {
	lets: { [string]: string },
	fields: { Field },
	--- Each named table: its rows, and its columns by name, as formulas see it.
	tables: { [string]: any },
	key: string,
}

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
local function table_value(s: Structure, first: number, last: number): any
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
	return out
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
			result.tables[id] = table_value(s, below.first, below.last)
			for row = below.first, below.last do
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
function M.scope(buffer: greed.Buffer, s: Structure?): core.FormulaScope
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
	for name, rows in known.tables do
		values[name] = rows
	end
	local working: { [string]: boolean } = {}
	local worked: { [string]: { value: any, err: string? } } = {}
	local function lookup(name: string): any
		local value = values[name]
		if value ~= nil then
			return value
		end
		local source = known.lets[name]
		if source == nil then
			return nil
		end
		local done = worked[name]
		if done == nil then
			if working[name] then
				error({ formula = `{name} depends on itself` }, 0)
			end
			working[name] = true
			local f, err = formula.compile(source)
			local v: any = nil
			if f then
				v, err = formula.eval(f, lookup)
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
	local f, err = formula.compile(source)
	if f then
		local value: any
		value, err = formula.eval(f, scope)
		if err == nil then
			return formula.show(value), false
		end
	end
	return `⚠ {err}`, true
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
