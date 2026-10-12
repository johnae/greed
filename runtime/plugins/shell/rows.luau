-- What a block shows of its output: `/` keeps the lines a filter matches,
-- or of a table the rows, and a key sorts a table by the column under the
-- cursor. The buffer shows what's kept, in order, while the block's record
-- and table keep everything as it came.

local greed = require("@greed")
local core = require("@core")
local state = require("./state")
local log = require("./log")
local tables = require("./tables")

type Shell = state.Shell
type Block = state.Block
type Line = log.Line

local M = {}

-- What each block showed before a filter or a sort changed it.
local original: { [Block]: { Line } } = setmetatable({}, { __mode = "k" }) :: any

-- Where each column starts in the lines drawn for a block whose table
-- isn't from its own lines, like JSON.
local drawn: { [Block]: { number } } = setmetatable({}, { __mode = "k" }) :: any

-- The line of `lines` (from 1) that `block`'s table's first row is on,
-- when the table came from those lines and they hold all of it.
local function first_row(block: Block, lines: { Line }): number?
	local tbl = block.table
	local first = tbl and tbl.first
	if tbl == nil or first == nil then
		return nil
	end
	local row_start = first + (if tbl.header then 1 else 0)
	return if #lines >= row_start - 1 + #tbl.rows then row_start else nil
end

-- The lines showing `rows` of `block`'s table: its own lines for them,
-- with whatever came before and after the table, or drawn anew.
local function lines_for(block: Block, rows: { number }): { Line }
	local tbl = assert(block.table)
	local before = original[block] or {}
	local row_start = first_row(block, before)
	if row_start then
		-- The header, and whatever came before it.
		local out: { Line } = table.move(before, 1, row_start - 1, 1, {})
		for _, index in rows do
			table.insert(out, before[row_start + index - 1])
		end
		for i = row_start + #tbl.rows, #before do
			table.insert(out, before[i])
		end
		return out
	end
	local texts, starts = tables.draw(tbl, rows)
	drawn[block] = starts
	local out: { Line } = {}
	for _, text in texts do
		table.insert(out, { text = text })
	end
	return out
end

-- The text of each row of `block`'s table as it shows, from `before`, its
-- lines as they came.
local function row_texts(block: Block, before: { Line }): { string }
	local tbl = assert(block.table)
	local texts: { string } = {}
	local row_start = first_row(block, before)
	if row_start then
		for i = 1, #tbl.rows do
			texts[i] = before[row_start + i - 1].text
		end
		return texts
	end
	local drawn_lines = tables.draw(tbl)
	return table.move(drawn_lines, 2, #drawn_lines, 1, texts)
end

-- Whether `word` is a `.a.b` section of indented text.
local function is_section(word: string): boolean
	return string.find(word, "^%.[^.]") ~= nil
end

-- Whether `filter` has a `.a.b` section word in it.
local function sectioned(filter: string): boolean
	for word in string.gmatch(filter, "%S+") do
		if is_section(word) then
			return true
		end
	end
	return false
end

-- The indexes of `texts` that `filter` keeps: every word of it in them,
-- or with a leading `/` a match of the regex after it, minding case as
-- `shell-filter-search-case` says. With a `key=value` or `.a.b` word, as a
-- view's filter reads them: fields of JSON lines, sections of YAML. Nil for
-- a regex that isn't one (yet, while it's typed).
local function keep(texts: { string }, filter: string): { number }?
	local kept: { number } = {}
	if string.sub(filter, 1, 1) == "/" then
		-- The regex engine works on buffers: one holds the lines for it.
		local buffer = greed.create_buffer("shell-filter", table.concat(texts, "\n"))
		local matches =
			buffer:find_all("(?m)" .. core.search.pattern(string.sub(filter, 2), "shell-filter"))
		local found: { [number]: boolean } = {}
		if matches then
			for _, match in matches do
				found[buffer:line_of(match.from) + 1] = true
			end
		end
		buffer:close()
		if matches == nil then
			return nil
		end
		for i in texts do
			if found[i] then
				table.insert(kept, i)
			end
		end
		return kept
	end
	local words: { string } = {}
	local structured = false
	for word in string.gmatch(filter, "%S+") do
		table.insert(words, word)
		-- `key=value`, `level>=warn`, `took>500`, `level!=debug`.
		structured = structured or is_section(word) or string.find(word, "^[^=!<>]+[=!<>]") ~= nil
	end
	if structured then
		-- Fields of JSON lines and sections of YAML, as a view's filter reads them.
		local buffer = greed.create_buffer("shell-filter", table.concat(texts, "\n"))
		for _, line in buffer:kept_lines(filter) do
			if texts[line + 1] then
				table.insert(kept, line + 1)
			end
		end
		buffer:close()
		return kept
	end
	for i, text in texts do
		local all = true
		for _, word in words do
			if not tables.has(text, word) then
				all = false
				break
			end
		end
		if all then
			table.insert(kept, i)
		end
	end
	return kept
end

--- Shows what `filter` keeps of `block`'s output: of a table, the rows it
--- keeps (see `tables.filter`), sorted by `sort` (from the greatest with
--- `desc`); of other output, the lines with every word of it in them, a
--- `key=value` word a field of JSON lines and a `.a.b` word a section of
--- YAML (of any output). A filter starting with `/` is a regex for the
--- lines. With neither, the output shows as it came.
function M.set(shell: Shell, block: Block, filter: string, sort: string?, desc: boolean?)
	if block.status == "running" and block.watching == nil then
		return
	end
	if filter == "" and sort == nil then
		local before = original[block]
		if before then
			block.shown = nil
			original[block] = nil
			drawn[block] = nil
			log.replace_output(shell, block, before)
		end
		return
	end
	local before = original[block] or log.output_lines(shell, block)
	original[block] = before
	local tbl = block.table
	local lines: { Line } = {}
	-- The rows (or lines) kept, of how many.
	local kept: { number } = {}
	local total = #before
	-- A section is of the text, even where it reads as a table too, like one
	-- JSON object.
	if tbl and not sectioned(filter) then
		local found = if string.sub(filter, 1, 1) == "/"
			then keep(row_texts(block, before), filter)
			else tables.filter(tbl, filter)
		if found == nil then
			return
		end
		kept = if sort then tables.sorted(tbl, found, sort, desc) else found
		total = #tbl.rows
		lines = lines_for(block, kept)
	else
		local texts: { string } = {}
		for i, line in before do
			texts[i] = line.text
		end
		local found = keep(texts, filter)
		if found == nil then
			return
		end
		kept = found
		for _, i in kept do
			table.insert(lines, before[i])
		end
	end
	local view: state.Shown = {
		filter = filter,
		sort = if tbl then sort else nil,
		desc = tbl ~= nil and desc == true,
		rows = kept,
		total = total,
	}
	block.shown = view
	log.replace_output(shell, block, lines)
end

--- The line of `block`'s output (from 1) that `pos` is on, or nil.
local function output_line(shell: Shell, block: Block, pos: number): number?
	local from, to = log.output_range(shell, block)
	if from == nil or to == nil or pos < from or pos > to then
		return nil
	end
	local buffer = shell.buffer
	return buffer:line_of(pos) - buffer:line_of(from) + 1
end

-- Where each column of `block`'s table starts in the lines showing it.
local function column_starts(block: Block, tbl: tables.Table): { number }?
	return if block.shown and drawn[block] then drawn[block] else tbl.starts
end

--- The column of `block`'s table under `pos`, if it's in the table.
function M.column_at(shell: Shell, block: Block, pos: number): string?
	local tbl = block.table
	if tbl == nil or output_line(shell, block, pos) == nil then
		return nil
	end
	local starts = column_starts(block, tbl)
	if starts == nil then
		return nil
	end
	local x = shell.buffer:display_column(pos)
	local found = tbl.columns[1]
	for i, start in starts do
		if x >= start then
			found = tbl.columns[i]
		end
	end
	return found
end

--- The row of `block`'s table (an index into its rows) on the line at
--- `pos`, if there's one there: what a plugin acting on rows, like one for
--- kubernetes, reads.
function M.row_at(shell: Shell, block: Block, pos: number): number?
	local tbl = block.table
	local line = output_line(shell, block, pos)
	if tbl == nil or line == nil then
		return nil
	end
	local view = block.shown
	local redrawn = view and drawn[block]
	if tbl.at and not redrawn then
		return table.find(tbl.at, line)
	end
	local first = if redrawn then 1 else tbl.first
	if first == nil then
		return nil
	end
	local index = line - first + 1 - (if tbl.header ~= false then 1 else 0)
	if view then
		return view.rows[index]
	end
	return if index >= 1 and index <= #tbl.rows then index else nil
end

--- The line of `shell`'s buffer showing row `index` of `block`'s table, or
--- nil when it isn't shown (a filter hides it, or the output is cut).
function M.row_line(shell: Shell, block: Block, index: number): number?
	local tbl = block.table
	local from, to = log.output_range(shell, block)
	if tbl == nil or from == nil or to == nil then
		return nil
	end
	local view = block.shown
	local buffer = shell.buffer
	local redrawn = view and drawn[block]
	local line: number
	if tbl.at and not redrawn then
		local found = tbl.at[index]
		if found == nil then
			return nil
		end
		line = buffer:line_of(from) + found - 1
	else
		local first = if redrawn then 1 else tbl.first
		local shown = if view then table.find(view.rows, index) else index
		if first == nil or shown == nil then
			return nil
		end
		local header = if tbl.header ~= false then 1 else 0
		line = buffer:line_of(from) + first + header + shown - 2
	end
	return if line <= buffer:line_of(to) then line else nil
end

--- Shows `lines` as what `block`, a live one (`watch`), printed now, with
--- the filter and sort it shows kept on them.
function M.renew(shell: Shell, block: Block, lines: { Line })
	local view = block.shown
	if view == nil then
		log.replace_output(shell, block, lines)
		return
	end
	original[block] = lines
	drawn[block] = nil
	M.set(shell, block, view.filter, view.sort, view.desc)
end

--- Sorts `block`'s table by `column`: from the least, and from the
--- greatest when it's sorted by that already; a third time, as it came.
function M.sort(shell: Shell, block: Block, column: string)
	local view = block.shown
	local filter = if view then view.filter else ""
	if view and view.sort == column then
		if view.desc then
			M.set(shell, block, filter, nil, false)
		else
			M.set(shell, block, filter, column, true)
		end
	else
		M.set(shell, block, filter, column, false)
	end
end

--- Shows `block`'s output as it came again.
function M.reset(shell: Shell, block: Block)
	M.set(shell, block, "", nil, false)
end

-- Words in a status column that say a thing is well, wrong, or on its way.
local function words(list: { string }): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for _, word in list do
		out[word] = true
	end
	return out
end
local GOOD = words({
	"running",
	"completed",
	"succeeded",
	"ready",
	"active",
	"bound",
	"healthy",
	"true",
	"ok",
	"up",
})
local BAD = words({
	"error",
	"failed",
	"crashloopbackoff",
	"imagepullbackoff",
	"errimagepull",
	"createcontainerconfigerror",
	"oomkilled",
	"evicted",
	"false",
	"unhealthy",
	"dead",
	"exited",
	"notready",
	"lost",
})
local WARN = words({
	"pending",
	"containercreating",
	"podinitializing",
	"terminating",
	"unknown",
	"restarting",
	"paused",
	"created",
	"warning",
})

-- Columns that say how a thing is doing.
local STATUS = words({ "status", "state", "phase", "health", "ready", "conditions", "type" })

-- The style of a cell of `column` holding `text`, if it says something:
-- how a thing is doing, in a status column ("Running", "0/1"), or nothing
-- much ("<none>", nested JSON as a table draws it).
local function cell_style(column: string, text: string): string?
	if
		text == "<none>"
		or text == "<nil>"
		or text == "-"
		or string.match(text, "^%[%d+ items?%]$")
		or string.match(text, "^{%d+ fields?}$")
	then
		return "shell.table.dim"
	end
	if not STATUS[string.lower(column)] then
		return nil
	end
	local have, want = string.match(text, "^(%d+)/(%d+)$")
	if have and want then
		return if have == want then "shell.table.good" else "shell.table.warn"
	end
	local lower = string.lower(text)
	local word = if string.match(lower, "^init:")
		then "pending"
		else string.match(lower, "^%w+") or ""
	return if GOOD[word]
		then "shell.table.good"
		elseif BAD[word] then "shell.table.bad"
		elseif WARN[word] then "shell.table.warn"
		else nil
end

-- The blocks colored, to clear when they no longer have a table.
local painted: { [Block]: boolean } = setmetatable({}, { __mode = "k" }) :: any

--- Colors `block`'s table where it shows: its header, and the cells that
--- say something (a status, an empty mark). A table nu drew, colored by nu,
--- is left as it is.
function M.paint(shell: Shell, block: Block)
	local ns = `shell.cells.{block.uid}`
	local tbl = block.table
	local starts = tbl and column_starts(block, tbl)
	local buffer = shell.buffer
	if tbl == nil or starts == nil or (tbl.at and not drawn[block]) or not buffer:valid() then
		if painted[block] and buffer:valid() then
			buffer:decorate(ns, {})
		end
		painted[block] = nil
		return
	end
	painted[block] = true
	local marks: { greed.Mark } = {}
	-- Marks the cells on `line`, each trimmed, that say something.
	local function paint_line(line: number)
		local start, stop = buffer:line_start(line), buffer:line_end(line)
		for i, column in tbl.columns do
			local from = buffer:at_display_column(line, starts[i])
			local to = if starts[i + 1] then buffer:at_display_column(line, starts[i + 1]) else stop
			from, to = math.clamp(from, start, stop), math.clamp(to, start, stop)
			local text = buffer:slice(from, to)
			local lead = #(string.match(text, "^%s*") or "")
			local trimmed = string.match(text, "^%s*(.-)%s*$") or ""
			local name = cell_style(column, trimmed)
			if name then
				local at = from + lead
				table.insert(marks, { from = at, to = at + #trimmed, style = name })
			end
		end
	end
	local order: { number } = if block.shown then block.shown.rows else tables.all(tbl)
	local first = order[1] and M.row_line(shell, block, order[1])
	if first and tbl.header ~= false and first > 0 then
		local header = first - 1
		table.insert(marks, {
			from = buffer:line_start(header),
			to = buffer:line_end(header),
			style = "shell.table.header",
		})
	end
	for _, index in order do
		local line = M.row_line(shell, block, index)
		if line then
			paint_line(line)
		end
	end
	buffer:decorate(ns, marks)
end

-- A block shown again, or showing more, is colored again.
log.on_update(function(block: Block)
	for _, shell in state.list() do
		if table.find(shell.blocks, block) then
			M.paint(shell, block)
			return
		end
	end
end)

return M
