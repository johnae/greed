-- Data blocks in Markdown: a fenced block named after a data source (see
-- `core.data`) shows the table it reads, under it, as the document shows:
--
--     ```sqlite db=shop.db rows=10
--     SELECT name, city, total FROM customers WHERE city = @city
--     ```
--
-- The opening fence says what it is and how it went (`▦ sqlite · shop.db
-- · 10 rows`); the query folds under it, shown dimmed while the cursor is
-- on that line, and the table is drawn from the closing fence down. A
-- read waits a moment after a change, so typing a query doesn't run it on
-- every key, and never holds the editor up. `@name` is the document's
-- value (a field, a `let`, an answer), so changing one reads the table
-- again; so does a change to the file a source watches. With `rows=N` a
-- table shows N rows at a time, `space m n` and `space m p` going on and
-- back. A source that runs a program (sqlite, psql) waits, as a code
-- block does, until you let it: `enter` on its line.

local greed = require("@greed")
local core = require("@core")
local markdown = require("@markdown")
local blocks = require("@blocks")
local sources = require("./sources")

type Structure = markdown.Structure
type Code = markdown.Code
type Table = core.DataTable

local M = {}

-- How long a block's text must stay the same before it's read, in ms.
local SETTLE = 300

--- A data block's table as last read: reading, read, failed, or waiting
--- for you to let its source run.
export type Entry = {
	status: "reading" | "read" | "failed" | "waiting",
	table: Table?,
	why: string?,
	stop: (() -> ())?,
}

-- Each buffer's blocks by the line they open on: what was asked of the
-- source (so a different ask reads again) and how it went.
local shown: { [number]: { [number]: { key: string, entry: Entry } } } = {}

-- Each buffer's pages, by block text: the first row shown, from 0.
local pages: { [number]: { [string]: number } } = {}

-- What the block asks of its source, with the document's values its text
-- names. `text` is the block's as `blocks.text` gives it, which its page
-- is kept by.
local function ask_of(buffer: greed.Buffer, code: Code, s: Structure, text: string): core.DataAsk
	local _, args = blocks.parse.info(code.info)
	local body = buffer:slice(code.code_from, code.code_to)
	local lookup = markdown.values.scope(buffer, s)
	local values: { [string]: any } = {}
	for _, name in sources.params(body) do
		values[name] = lookup(name)
	end
	local path = buffer:path()
	local rows = tonumber(args.rows)
	return {
		args = args,
		body = body,
		values = values,
		dir = if path then string.match(path, "^(.*)/[^/]*$") else nil,
		limit = rows,
		offset = if rows then (pages[buffer:id()] or {})[text] or 0 else nil,
	}
end

-- What tells two asks apart: the block's text, its values and its page.
local function key_of(ask: core.DataAsk, text: string): string
	local names: { string } = {}
	for name in ask.values do
		table.insert(names, name)
	end
	table.sort(names)
	local parts = { text, tostring(ask.offset or 0) }
	for _, name in names do
		table.insert(parts, `{name}={core.data.show(ask.values[name])}`)
	end
	return table.concat(parts, "\0")
end

-- Whether the block's source may run in `buffer`: it runs nothing, the
-- buffer has no file, or you let this text run from it.
local function allowed(buffer: greed.Buffer, source: core.DataSource, text: string): boolean
	local path = buffer:path()
	return not source.runs or path == nil or blocks.approved(path, text)
end

-- Forgets the block at `line` of buffer `id`, stopping its watch.
local function forget(id: number, line: number)
	local known = shown[id]
	local was = known and known[line]
	if was and was.entry.stop then
		was.entry.stop()
	end
	if known then
		known[line] = nil
	end
end

-- How the block on `line` of `buffer` reads now, reading it (a moment
-- after its text settles) when what it asks changed.
local function entry_for(
	buffer: greed.Buffer,
	line: number,
	source: core.DataSource,
	ask: core.DataAsk,
	text: string
): Entry
	local id = buffer:id()
	local known = shown[id] or {}
	shown[id] = known
	local key = key_of(ask, text)
	local was = known[line]
	if was and was.key == key then
		return was.entry
	end
	forget(id, line)
	local entry: Entry = { status = "reading" }
	known[line] = { key = key, entry = entry }
	if not allowed(buffer, source, text) then
		entry.status = "waiting"
		return entry
	end
	-- Read again when the source says its table may have changed.
	if source.watch then
		entry.stop = source.watch(ask, function()
			if known[line] and known[line].entry == entry then
				forget(id, line)
				markdown.redraw(buffer)
			end
		end)
	end
	greed.spawn(function()
		greed.sleep(SETTLE)
		if known[line] == nil or known[line].entry ~= entry or not buffer:valid() then
			return
		end
		local t, why = core.data.read(source.name, ask)
		entry.table, entry.why = t, why
		entry.status = if t then "read" else "failed"
		if known[line] and known[line].entry == entry then
			markdown.redraw(buffer)
		end
	end)
	return entry
end

-- What the opening fence says: the source, what it reads, and how that went.
local function header(code: Code, ask: core.DataAsk, entry: Entry): string
	local what = ask.args.path or ask.args.db
	local parts = { `▦ {code.lang}` }
	if what then
		table.insert(parts, what)
	end
	if entry.status == "reading" then
		table.insert(parts, "reading…")
	elseif entry.status == "waiting" then
		table.insert(parts, "▶ enter runs it")
	elseif entry.status == "failed" then
		table.insert(parts, "failed")
	elseif entry.table then
		local t = entry.table
		local from = (ask.offset or 0) + 1
		local n = #t.rows
		if ask.limit and (t.more or from > 1) then
			table.insert(parts, `rows {from}–{from + n - 1}{if t.more then ", more" else ""}`)
		else
			table.insert(parts, if n == 1 then "1 row" else `{n} rows`)
		end
	end
	return table.concat(parts, " · ")
end

--- What the data block `code` of `buffer` asks of its source now.
function M.ask(buffer: greed.Buffer, code: Code): core.DataAsk
	return ask_of(buffer, code, markdown.structure(buffer), blocks.text(buffer, code))
end

--- `t` drawn as a table widget (`core.ui.table`): numbers on the right,
--- each row pressing `on_open` if given.
function M.node(t: Table, on_open: ((row: { [string]: any }, index: number) -> ())?): core.UiNode
	local columns: { any } = {}
	for _, column in t.columns do
		table.insert(columns, { name = column.name, right = column.kind == "number" })
	end
	return core.ui.table({ columns = columns, rows = t.rows, on_open = on_open })
end

-- The marks drawing the block `code` of `buffer`.
local function draw_block(buffer: greed.Buffer, s: Structure, code: Code, out: { greed.Mark })
	local source = core.data.get(code.lang)
	if source == nil or not code.closed then
		return
	end
	local text = blocks.text(buffer, code)
	local ask = ask_of(buffer, code, s, text)
	local entry = entry_for(buffer, code.open, source, ask, text)
	local open_from = s.starts[code.open + 1]
	local open_to = open_from + #s.lines[code.open + 1]
	table.insert(out, {
		from = open_from,
		to = open_to,
		style = "markdown.marker",
		text = header(code, ask, entry),
		conceal = true,
		reveal = "auto" :: "auto",
		action = if entry.status == "waiting" then "data-run" else "data-refresh",
	})
	-- The query, under its line.
	if code.close > code.open + 1 then
		table.insert(out, {
			from = open_from,
			to = buffer:line_end(code.close - 1),
			style = "markdown.marker",
			fold = true,
			peek = true,
		})
	end
	local close_from = s.starts[code.close + 1]
	local close_to = close_from + #s.lines[code.close + 1]
	local t = entry.table
	if entry.status == "failed" then
		table.insert(out, {
			from = close_from,
			to = close_to,
			style = "markdown.value.error",
			text = `⚠ {entry.why or "it failed"}`,
			conceal = true,
			reveal = "auto" :: "auto",
		})
	elseif t and #t.columns > 0 then
		-- The top border over the closing fence, the rest under it.
		local laid = M.node(t).lay(core.ui.width(buffer))
		local top = table.remove(laid, 1) :: core.UiLine
		table.insert(out, {
			from = close_from,
			to = close_to,
			style = "markdown.table",
			text = top[1].text,
			action = "data-open",
			conceal = true,
			reveal = "auto" :: "auto",
		})
		table.insert(
			out,
			{ from = close_from, to = close_to, style = "", lines = core.ui.pieces(laid) }
		)
	else
		table.insert(out, {
			from = close_from,
			to = close_to,
			style = "markdown.marker",
			text = if t then "no rows" else "",
			conceal = true,
			reveal = "auto" :: "auto",
		})
	end
end

markdown.conceal({
	ns = "data-blocks",
	wants = markdown.drawn,
	draw = function(
		buffer: greed.Buffer,
		s: Structure,
		first: number,
		last: number
	): { greed.Mark }
		local out: { greed.Mark } = {}
		for _, code in s.code do
			if code.open >= first and code.open <= last then
				draw_block(buffer, s, code, out)
			end
		end
		return out
	end,
})

--- The data block of `buffer` at `pos`, and how it reads now.
function M.at(buffer: greed.Buffer, pos: number): (Code?, Entry?)
	local line = buffer:line_of(pos)
	for _, code in markdown.structure(buffer).code do
		if line >= code.open and line <= code.close and core.data.get(code.lang) then
			local known = shown[buffer:id()]
			local was = known and known[code.open]
			return code, if was then was.entry else nil
		end
	end
	return nil, nil
end

--- The table the data block `code` of `buffer` read last, if it's read.
function M.table(buffer: greed.Buffer, code: Code): Table?
	local known = shown[buffer:id()]
	local was = known and known[code.open]
	return if was then was.entry.table else nil
end

-- The data block at the cursor, or nil after saying there's none.
local function here(ctx: greed.Context): Code?
	local code = M.at(ctx.buffer, ctx.view:cursor())
	if code == nil then
		greed.echo("there's no data block here")
	end
	return code
end

greed.command({
	name = "data-refresh",
	doc = "Read the data block at the cursor again",
	run = function(ctx)
		local code = here(ctx)
		if code then
			forget(ctx.buffer:id(), code.open)
			markdown.redraw(ctx.buffer)
		end
	end,
})

greed.command({
	name = "data-run",
	doc = "Let the data block at the cursor run its query, as a code block, and read it",
	run = function(ctx)
		local code = here(ctx)
		local path = ctx.buffer:path()
		if code == nil or path == nil then
			return
		end
		if not blocks.allow_file(path, "data queries") then
			return
		end
		blocks.approve(path, { blocks.text(ctx.buffer, code) })
		forget(ctx.buffer:id(), code.open)
		markdown.redraw(ctx.buffer)
	end,
})

-- Turns the page of the data block at the cursor by `by` pages.
local function turn(ctx: greed.Context, by: number)
	local code = here(ctx)
	if code == nil then
		return
	end
	local _, args = blocks.parse.info(code.info)
	local rows = tonumber(args.rows)
	if rows == nil then
		greed.echo("this block shows every row; rows=N shows N at a time")
		return
	end
	local t = M.table(ctx.buffer, code)
	local id = ctx.buffer:id()
	local text = blocks.text(ctx.buffer, code)
	local list = pages[id] or {}
	pages[id] = list
	local at = list[text] or 0
	if by > 0 and not (t and t.more) then
		greed.echo("that's the last of them")
		return
	end
	list[text] = math.max(at + by * rows, 0)
	markdown.redraw(ctx.buffer)
end

greed.command({
	name = "data-page-next",
	doc = "Show the data block's next rows",
	run = function(ctx)
		turn(ctx, 1)
	end,
})

greed.command({
	name = "data-page-prev",
	doc = "Show the data block's rows before these",
	run = function(ctx)
		turn(ctx, -1)
	end,
})

-- The data blocks of `buffer` named with `id=`, by name.
local function named(buffer: greed.Buffer): { [string]: Code }
	local out: { [string]: Code } = {}
	for _, code in markdown.structure(buffer).code do
		if core.data.get(code.lang) then
			local _, args = blocks.parse.info(code.info)
			if args.id then
				out[args.id] = code
			end
		end
	end
	return out
end

-- A data block with `id=name` is a value for the document's formulas,
-- once it's read: its rows, and its columns by name, as a named table's.
markdown.values.provide({
	names = function(buffer: greed.Buffer): { string }
		local out: { string } = {}
		for name in named(buffer) do
			table.insert(out, name)
		end
		return out
	end,
	value = function(buffer: greed.Buffer, name: string): any
		local code = named(buffer)[name]
		local t = if code then M.table(buffer, code) else nil
		return if t then markdown.values.table(t) else nil
	end,
})

greed.on("buffer.closed", function(event)
	local known: { [number]: any } = shown[event.id] or {}
	for line in known do
		forget(event.id, line)
	end
	shown[event.id] = nil
	pages[event.id] = nil
end)

return M
