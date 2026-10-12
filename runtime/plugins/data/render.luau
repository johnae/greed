-- A table of data drawn as lines under a block, bordered as Markdown's
-- tables are: numbers on the right, a column no wider than `widest`.

local core = require("@core")
local markdown = require("@markdown")

type Table = core.DataTable
type Piece = { text: string, style: string?, action: string? }

local M = {}

--- How wide a column may get before its cells are cut.
M.widest = 40

--- `t` as lines: its top border, header, a rule, its rows and the bottom
--- border, each a list of styled pieces.
function M.lines(t: Table): { { Piece } }
	local text = core.data.text(t)
	local widths: { number } = {}
	for c, name in text.columns do
		local w = core.text.width(name)
		for _, row in text.rows do
			w = math.max(w, core.text.width(row[name]))
		end
		widths[c] = math.min(math.max(w, 1), M.widest)
	end
	local function row_of(cells: { string }, style: string): { Piece }
		local pieces: { Piece } = { { text = "│ ", style = "markdown.table" } }
		for c, cell in cells do
			local shown = core.text.clip(cell, widths[c])
			local room = widths[c] - core.text.width(shown)
			local right = t.columns[c].kind == "number" and style ~= "markdown.table.header"
			local padded = if right
				then string.rep(" ", room) .. shown
				else shown .. string.rep(" ", room)
			table.insert(pieces, { text = padded, style = style })
			table.insert(
				pieces,
				{ text = if c < #cells then " │ " else " │", style = "markdown.table" }
			)
		end
		return pieces
	end
	local out: { { Piece } } = {
		{
			{
				text = markdown.tables.border(widths, "┌", "┬", "┐"),
				style = "markdown.table",
			},
		},
		row_of(text.columns, "markdown.table.header"),
		{
			{
				text = markdown.tables.border(widths, "├", "┼", "┤"),
				style = "markdown.table",
			},
		},
	}
	for _, row in text.rows do
		local cells: { string } = {}
		for _, name in text.columns do
			table.insert(cells, row[name])
		end
		table.insert(out, row_of(cells, "markdown.table.cell"))
	end
	table.insert(
		out,
		{ { text = markdown.tables.border(widths, "└", "┴", "┘"), style = "markdown.table" } }
	)
	return out
end

return M
