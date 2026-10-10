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

-- The indexes of `texts` that `filter` keeps: every word of it in them,
-- or with a leading `/` a match of the regex after it, minding case as
-- `shell-filter-search-case` says. Nil for a regex that isn't one (yet,
-- while it's typed).
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
	for word in string.gmatch(filter, "%S+") do
		table.insert(words, word)
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
--- `desc`); of other output, the lines with every word of it in them. A
--- filter starting with `/` is a regex for the lines. With neither, the
--- output shows as it came.
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
	if tbl then
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

--- The column of `block`'s table under `pos`, if it's in the table.
function M.column_at(shell: Shell, block: Block, pos: number): string?
	local tbl = block.table
	if tbl == nil or output_line(shell, block, pos) == nil then
		return nil
	end
	local starts: { number }? = if block.shown and drawn[block] then drawn[block] else tbl.starts
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

return M
