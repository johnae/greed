-- Editing Markdown tables as they're drawn, from normal mode: alt-h and
-- alt-l go cell to cell, enter on a cell asks for its text (a formula
-- column's formula), and the leader's `m t` keys add, delete, move and
-- sort rows and columns. Every change writes the table back with its
-- pipes lined up.

local greed = require("@greed")
local core = require("@core")
local structure = require("./structure")
local tables = require("./tables")
local values = require("./values")

local M = {}

--- Where the cursor is in a table: the table, its grid, the row (0 the
--- header, the delimiter row counting as it, then 1 on) and column.
export type Spot = {
	buffer: greed.Buffer,
	first: number,
	last: number,
	grid: tables.Grid,
	row: number,
	column: number,
}

--- The table cell at `pos` in `buffer`, if it's in one.
function M.at(buffer: greed.Buffer, pos: number): Spot?
	local s = structure.of(buffer)
	local line = buffer:line_of(pos)
	local found = s.table_at[line]
	if found == nil or found.last == found.first then
		return nil
	end
	local lines: { string } = {}
	for n = found.first, found.last do
		table.insert(lines, s.lines[n + 1])
	end
	local column = tables.column_at(s.lines[line + 1], pos - s.starts[line + 1] + 1)
	local grid = tables.grid(lines)
	if column == nil or grid == nil then
		return nil
	end
	return {
		buffer = buffer,
		first = found.first,
		last = found.last,
		grid = grid,
		row = math.max(line - found.first - 1, 0),
		column = column,
	}
end

-- The line of row `row` (as in `Spot`) of the table starting on `first`.
local function line_of(first: number, row: number): number
	return if row == 0 then first else first + row + 1
end

-- Where cell `column` of `row` starts in the table starting on `first`.
local function cell_start(buffer: greed.Buffer, first: number, row: number, column: number): number
	local line = line_of(first, row)
	local cells: { tables.Cell } = tables.cells(core.text.lines(buffer, line, line)) or {}
	local cell = cells[math.min(column, #cells)]
	return buffer:line_start(line) + (if cell then cell.from - 1 else 0)
end

local function go(view: greed.View, pos: number)
	view:set_selection({ ranges = { { anchor = pos, head = pos } }, primary = 1 })
end

--- Writes `grid` over the table at `spot`, its pipes lined up, and puts
--- the cursor in cell `column` of `row`.
function M.write(view: greed.View, spot: Spot, grid: tables.Grid, row: number, column: number)
	local buffer = spot.buffer
	local text = table.concat(
		tables.write(grid, function(s)
			return core.text.width(s)
		end),
		"\n"
	)
	local from, to = buffer:line_start(spot.first), buffer:line_end(spot.last)
	if buffer:slice(from, to) ~= text then
		buffer:edit(function(e)
			e:replace(from, to, text)
		end)
	end
	go(view, cell_start(buffer, spot.first, math.clamp(row, 0, #grid.rows), column))
end

-- A typed cell's text as it can go in a row: on one line, its pipes
-- escaped so they stay in it.
local function cell_text(typed: string): string
	local one = string.gsub(typed, "[\r\n]+", " ")
	local trimmed = string.match(one, "^%s*(.-)%s*$") or ""
	return (
		string.gsub(trimmed, "\\?|", function(pipe: string): string
			return if pipe == "|" then "\\|" else pipe
		end)
	)
end

--- An edit to the table under the cursor: `change` gets its grid and the
--- cursor's row and column, changes the grid, and gives back where the
--- cursor goes, or nil to leave the table as it was.
local function editing(
	name: string,
	doc: string,
	change: (grid: tables.Grid, row: number, column: number) -> (number?, number?)
)
	greed.command({
		name = name,
		doc = doc,
		run = function(ctx)
			local spot = M.at(ctx.buffer, ctx.view:cursor())
			if spot == nil then
				greed.echo("not in a table")
				return
			end
			local row, column = change(spot.grid, spot.row, spot.column)
			if row and column then
				M.write(ctx.view, spot, spot.grid, row, column)
			end
		end,
	})
end

-- Each row of `grid`, the header first.
local function rows_of(grid: tables.Grid): { { string } }
	local all = { grid.header }
	for _, row in grid.rows do
		table.insert(all, row)
	end
	return all
end

editing(
	"markdown-table-row-add",
	"Add a row under the cursor's, in a Markdown table",
	function(grid, row, column)
		table.insert(grid.rows, row + 1, {} :: { string })
		return row + 1, column
	end
)

editing(
	"markdown-table-row-add-above",
	"Add a row above the cursor's, in a Markdown table",
	function(grid, row, column)
		local at = math.max(row, 1)
		table.insert(grid.rows, at, {} :: { string })
		return at, column
	end
)

editing(
	"markdown-table-row-delete",
	"Delete the cursor's row of a Markdown table",
	function(grid, row, column)
		if row == 0 then
			greed.echo("the header row stays; delete the table's lines to remove it")
			return nil, nil
		end
		table.remove(grid.rows, row)
		return math.min(row, #grid.rows), column
	end
)

local function move_row(by: number)
	return function(grid: tables.Grid, row: number, column: number): (number?, number?)
		local to = row + by
		if row == 0 or to < 1 or to > #grid.rows then
			return nil, nil
		end
		grid.rows[row], grid.rows[to] = grid.rows[to], grid.rows[row]
		return to, column
	end
end

editing("markdown-table-row-up", "Move the cursor's row of a Markdown table up", move_row(-1))
editing("markdown-table-row-down", "Move the cursor's row of a Markdown table down", move_row(1))

local function add_column(right: boolean)
	return function(grid: tables.Grid, row: number, column: number): (number?, number?)
		local at = if right then column + 1 else column
		local n = #grid.header
		for _, cells in rows_of(grid) do
			for c = #cells + 1, n do
				cells[c] = ""
			end
			table.insert(cells, at, "")
		end
		table.insert(grid.specs, at, "plain" :: tables.Spec)
		return row, at
	end
end

editing(
	"markdown-table-column-add",
	"Add a column right of the cursor's, in a Markdown table",
	add_column(true)
)
editing(
	"markdown-table-column-add-left",
	"Add a column left of the cursor's, in a Markdown table",
	add_column(false)
)

editing(
	"markdown-table-column-delete",
	"Delete the cursor's column of a Markdown table",
	function(grid, row, column)
		if #grid.header == 1 then
			greed.echo("a table keeps one column; delete the table's lines to remove it")
			return nil, nil
		end
		for _, cells in rows_of(grid) do
			table.remove(cells, column)
		end
		table.remove(grid.specs, column)
		return row, math.min(column, #grid.header)
	end
)

local function move_column(by: number)
	return function(grid: tables.Grid, row: number, column: number): (number?, number?)
		local to = column + by
		if to < 1 or to > #grid.header then
			return nil, nil
		end
		for _, cells in rows_of(grid) do
			cells[column], cells[to] = cells[to] or "", cells[column] or ""
		end
		grid.specs[column], grid.specs[to] = grid.specs[to], grid.specs[column]
		return row, to
	end
end

editing(
	"markdown-table-column-left",
	"Move the cursor's column of a Markdown table left",
	move_column(-1)
)
editing(
	"markdown-table-column-right",
	"Move the cursor's column of a Markdown table right",
	move_column(1)
)

-- Whether `a` goes before `b`: numbers by size and ahead of words, words
-- by their letters, either case alike.
local function before(a: string, b: string): boolean
	local x, y = tonumber(a), tonumber(b)
	if x and y then
		return x < y
	elseif x or y then
		return x ~= nil
	end
	return string.lower(a) < string.lower(b)
end

local function sort(descending: boolean)
	return function(grid: tables.Grid, row: number, column: number): (number?, number?)
		-- Rows that are alike keep their order.
		local order: { [{ string }]: number } = {}
		for i, cells in grid.rows do
			order[cells] = i
		end
		table.sort(grid.rows, function(a, b)
			local x, y = a[column] or "", b[column] or ""
			if x == y then
				return order[a] < order[b]
			end
			return if descending then before(y, x) else before(x, y)
		end)
		return row, column
	end
end

editing("markdown-table-sort", "Sort a Markdown table's rows by the cursor's column", sort(false))
editing(
	"markdown-table-sort-descending",
	"Sort a Markdown table's rows by the cursor's column, largest first",
	sort(true)
)

editing("markdown-table-align", "Line up a Markdown table's pipes", function(_, row, column)
	return row, column
end)

-- The formula filling `column` of the table at `spot`, if one does.
local function formula_of(spot: Spot, column: number): values.Column?
	local header = spot.grid.header[column]
	local s = structure.of(spot.buffer)
	for _, filled in values.formulas(s, spot.last) do
		if header and filled.key == values.key(header) then
			return filled
		end
	end
	return nil
end

greed.command({
	name = "markdown-cell-edit",
	doc = "Type the text of the Markdown table cell at the cursor, or the formula filling its column",
	run = function(ctx)
		local spot = M.at(ctx.buffer, ctx.view:cursor())
		if spot == nil then
			greed.echo("not in a table")
			return
		end
		local grid = spot.grid
		local filled = if spot.row > 0 then formula_of(spot, spot.column) else nil
		if filled then
			local typed = core.prompt.ask(`{filled.key} =`, filled.source)
			if typed ~= nil then
				local buffer = spot.buffer
				local line = core.text.lines(buffer, filled.line, filled.line)
				local from = buffer:line_start(filled.line)
				local first, last = string.find(line, filled.source, 1, true)
				if first and last then
					local clean = string.gsub(typed, "[\r\n]+", " ")
					buffer:edit(function(e)
						e:replace(from + first - 1, from + last, (string.gsub(clean, "%-%->", "")))
					end)
				end
			end
			return
		end
		local cells = if spot.row == 0 then grid.header else grid.rows[spot.row]
		local title = if spot.row == 0 then "header" else grid.header[spot.column] or "cell"
		local typed =
			core.prompt.ask(if title == "" then "cell" else title, cells[spot.column] or "")
		if typed == nil then
			return
		end
		for c = #cells + 1, spot.column - 1 do
			cells[c] = ""
		end
		cells[spot.column] = cell_text(typed)
		M.write(ctx.view, spot, grid, spot.row, spot.column)
	end,
})

-- Enter on a table's cell edits it, where nothing else there is a button.
core.buttons.offer(function(buffer, pos)
	local spot = M.at(buffer, pos)
	if spot == nil then
		return nil
	end
	return {
		text = "edit cell",
		action = "markdown-cell-edit",
		from = cell_start(buffer, spot.first, spot.row, spot.column),
	}
end)

-- The cell `by` cells on from the cursor's, row after row, past the
-- delimiter row; nil at the table's ends.
local function step(spot: Spot, by: number): (number?, number?)
	local n, rows = #spot.grid.header, #spot.grid.rows
	local at = spot.row * n + spot.column - 1 + by
	if at < 0 or at > rows * n + n - 1 then
		return nil, nil
	end
	return at // n, at % n + 1
end

local function jump(name: string, doc: string, by: number)
	greed.command({
		name = name,
		doc = doc,
		run = function(ctx)
			local spot = M.at(ctx.buffer, ctx.view:cursor())
			if spot == nil then
				core.keys.otherwise(ctx.keys or "", name)
				return
			end
			local row, column = step(spot, by)
			if row and column then
				go(ctx.view, cell_start(ctx.buffer, spot.first, row, column))
			end
		end,
	})
end

jump(
	"markdown-cell-next",
	"Go to the next cell of a Markdown table; elsewhere, what the key does otherwise",
	1
)
jump(
	"markdown-cell-prev",
	"Go to the cell before in a Markdown table; elsewhere, what the key does otherwise",
	-1
)

--- The keys, by layer. Change them before this plugin loads, or rebind
--- and unbind from your config afterwards.
M.keys = {
	-- Normal mode in every style, and vscode's typing.
	cells = {
		["alt-h"] = "markdown-cell-prev",
		["alt-l"] = "markdown-cell-next",
	},
	leader = {
		["m t o"] = "markdown-table-row-add",
		["m t O"] = "markdown-table-row-add-above",
		["m t d"] = "markdown-table-row-delete",
		["m t j"] = "markdown-table-row-down",
		["m t k"] = "markdown-table-row-up",
		["m t c"] = "markdown-table-column-add",
		["m t C"] = "markdown-table-column-add-left",
		["m t D"] = "markdown-table-column-delete",
		["m t h"] = "markdown-table-column-left",
		["m t l"] = "markdown-table-column-right",
		["m t s"] = "markdown-table-sort",
		["m t S"] = "markdown-table-sort-descending",
		["m t ="] = "markdown-table-align",
		["m t e"] = "markdown-cell-edit",
	},
}

greed.keymap.bind({ role = "command" }, M.keys.cells)
greed.keymap.bind({ style = "vscode", role = "typing" }, M.keys.cells)
greed.keymap.bind({ layer = "leader" }, M.keys.leader)

return M
