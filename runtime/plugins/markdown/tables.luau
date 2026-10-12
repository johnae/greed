-- Tables laid out with aligned columns and borders, as text drawn over
-- the pipes and spaces between cells, so the file stays as written:
--
--     | Name | Size |          ┌──────┬──────┐
--     |------|-----:|    as    │ Name │ Size │
--     | a    | 12   |          ├──────┼──────┤
--                              │ a    │   12 │
--                              └──────┴──────┘

local M = {}

export type Align = "left" | "right" | "center"

--- A cell's text in its row, 1-based and inclusive; `to` is `from - 1`
--- when it's empty.
export type Cell = { from: number, to: number }

--- Text shown in place of a row's bytes `from` to `to` (nothing when `to`
--- is `from - 1`): the padding, borders and spaces between two cells.
export type Gap = { from: number, to: number, text: string }

export type Row = { cells: { Cell }, gaps: { Gap } }

--- The cells of a table row, between its pipes; the pipes at either end
--- are optional. Pipes in code spans or after a backslash don't count.
--- Nil without a pipe.
function M.cells(text: string): { Cell }?
	local pipes: { number } = {}
	local code = false
	local i = 1
	while i <= #text do
		local c = string.sub(text, i, i)
		if c == "\\" then
			i += 1
		elseif c == "`" then
			code = not code
		elseif c == "|" and not code then
			table.insert(pipes, i)
		end
		i += 1
	end
	if #pipes == 0 then
		return nil
	end
	local bounds: { number } = {}
	if not string.match(string.sub(text, 1, pipes[1] - 1), "^%s*$") then
		table.insert(bounds, 0)
	end
	for _, pipe in pipes do
		table.insert(bounds, pipe)
	end
	if not string.match(string.sub(text, pipes[#pipes] + 1), "^%s*$") then
		table.insert(bounds, #text + 1)
	end
	local cells: { Cell } = {}
	for k = 1, #bounds - 1 do
		local from, to = bounds[k] + 1, bounds[k + 1] - 1
		local raw = string.sub(text, from, to)
		local lead = #(string.match(raw, "^%s*") or "")
		if lead == #raw then
			table.insert(cells, { from = to + 1, to = to })
		else
			local trail = #(string.match(raw, "%s*$") or "")
			table.insert(cells, { from = from + lead, to = to - trail })
		end
	end
	return cells
end

--- The columns' alignments if `text` is a delimiter row, like
--- `|:---|---:|`, or nil.
function M.aligns(text: string): { Align }?
	local cells = M.cells(text)
	if cells == nil or #cells == 0 then
		return nil
	end
	local out: { Align } = {}
	for _, cell in cells do
		local spec = string.sub(text, cell.from, cell.to)
		if not string.match(spec, "^:?%-+:?$") then
			return nil
		end
		local left, right = string.sub(spec, 1, 1) == ":", string.sub(spec, -1) == ":"
		local align: Align = if left and right then "center" elseif right then "right" else "left"
		table.insert(out, align)
	end
	return out
end

--- Lays out `rows` (without the delimiter row) in columns aligned as
--- `aligns` says, `width` measuring a cell's text as shown (given its row and
--- column too, for a cell shown as something else). Returns each
--- column's width, and each row's cells (those past the last column left
--- out) with what to show between them.
function M.layout(
	rows: { string },
	aligns: { Align },
	width: (text: string, row: number, column: number) -> number
): ({ number }, { Row })
	local n = #aligns
	local widths: { number } = table.create(n, 1)
	local parsed: { { cells: { Cell }, shown: { number } } } = {}
	for r, text in rows do
		local cells = M.cells(text) or {}
		local shown: { number } = {}
		for c = 1, math.min(#cells, n) do
			shown[c] = width(string.sub(text, cells[c].from, cells[c].to), r, c)
			widths[c] = math.max(widths[c], shown[c])
		end
		parsed[r] = { cells = cells, shown = shown }
	end
	local out: { Row } = {}
	for r, text in rows do
		local cells, shown = parsed[r].cells, parsed[r].shown
		local k = math.min(#cells, n)
		-- What goes between cell c and the next, from 0 (before the first)
		-- to n (after the last). A missing cell's padding is its width, so
		-- joining the texts after the last cell fills the row out.
		local between: { [number]: string } = {}
		local left: { string }, right: { string } = {}, {}
		for c = 1, n do
			local room = widths[c] - (shown[c] or 0)
			local before = if aligns[c] == "right"
				then room
				elseif aligns[c] == "center" then room // 2
				else 0
			left[c], right[c] = string.rep(" ", before), string.rep(" ", room - before)
		end
		between[0] = "│ " .. left[1]
		for c = 1, n - 1 do
			between[c] = right[c] .. " │ " .. left[c + 1]
		end
		between[n] = right[n] .. " │"
		local rest: { string } = {}
		for c = k, n do
			table.insert(rest, between[c])
		end
		local gaps: { Gap } = {}
		if k == 0 then
			table.insert(gaps, { from = 1, to = #text, text = table.concat(rest) })
		else
			table.insert(gaps, { from = 1, to = cells[1].from - 1, text = between[0] })
			for c = 1, k - 1 do
				table.insert(
					gaps,
					{ from = cells[c].to + 1, to = cells[c + 1].from - 1, text = between[c] }
				)
			end
			table.insert(gaps, { from = cells[k].to + 1, to = #text, text = table.concat(rest) })
		end
		out[r] = { cells = table.move(cells, 1, k, 1, {}), gaps = gaps }
	end
	return widths, out
end

--- A border across columns `widths` wide: `left`, `middle` between
--- columns and `right`, e.g. "├", "┼", "┤".
function M.border(widths: { number }, left: string, middle: string, right: string): string
	local parts = {}
	for _, w in widths do
		table.insert(parts, string.rep("─", w + 2))
	end
	return left .. table.concat(parts, middle) .. right
end

return M
