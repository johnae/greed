-- Marks for lists of choices, like the picker's: the selected row and the
-- characters a query matched.

local greed = require("@greed")

local M = {}

-- Adds the marks for one row of a list to `marks`. The row starts at byte
-- `from` in the buffer; `matched` are byte offsets from `greed.fuzzy_positions`
-- into the part of the row starting `offset` bytes in.
function M.mark_row(marks: { greed.Mark }, from: number, row: string, selected: boolean, matched: { number }, offset: number)
	if selected then
		table.insert(marks, { from = from, to = from + #row, style = "ui.menu.selected", line = true })
	end
	for _, pos in matched do
		local after = utf8.offset(row, 2, offset + pos + 1) or #row + 1
		table.insert(marks, { from = from + offset + pos, to = from + after - 1, style = "ui.menu.match" })
	end
end

return M
