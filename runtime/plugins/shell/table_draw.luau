-- Drawing a table as aligned lines, cells shown as people read them.

local greed = require("@greed")
local core = require("@core")
local read = require("./table_read")
local query = require("./table_query")

type Table = read.Table

local M = {}

-- The widest a cell shows when the shell draws a table; past it, it's cut
-- with `…`, and the whole of it is in the row's state (`space h i`).
local WIDEST = 48

-- Columns whose whole numbers are sizes in bytes, as nu's `ls` gives them.
local SIZES: { [string]: boolean } = { size = true, bytes = true, filesize = true }

-- A moment, `seconds` since 1970: how long ago in the last week, else
-- its date and time.
local function when(seconds: number): string
	local ago = os.time() - seconds
	if ago >= 0 and ago < 7 * 86400 then
		return core.time.ago(ago)
	end
	return os.date("%Y-%m-%d %H:%M", seconds) :: string
end

-- Nested JSON in a cell, in a few words: "{4 fields}", "[12 items]".
local function nested(text: string): string?
	local first = string.sub(text, 1, 1)
	if first ~= "{" and first ~= "[" then
		return nil
	end
	local ok, value = pcall(greed.json.decode, text)
	if not ok or type(value) ~= "table" then
		return nil
	end
	local count = 0
	for _ in value do
		count += 1
	end
	if first == "[" then
		return `[{count} item{if count == 1 then "" else "s"}]`
	end
	return `\{{count} field{if count == 1 then "" else "s"}\}`
end

--- How a column's cells show when the shell draws a table: `show` turns a
--- cell into what's drawn (sizes, dates and nested JSON as people read
--- them), and `right` lines numbers up on the right. The cells themselves
--- stay as they are, so stages sort and compare the real values.
export type Look = { show: ((text: string) -> string)?, right: boolean }

--- How `column`'s cells in `rows` of `tbl` show.
function M.look(tbl: Table, column: string, rows: { number }?): Look
	local all_numbers, all_times, any = true, true, false
	local whole = true
	for _, index in rows or query.all(tbl) do
		local text = tbl.rows[index][column] or ""
		if text ~= "" then
			any = true
			local number = tonumber(text)
			all_numbers = all_numbers and number ~= nil
			whole = whole and number ~= nil and number == math.floor(number)
			all_times = all_times and core.time.iso(text) ~= nil
		end
	end
	if not any then
		return { right = false }
	elseif all_times then
		return {
			show = function(text)
				local seconds = core.time.iso(text)
				return if seconds then when(seconds) else text
			end,
			right = false,
		}
	elseif all_numbers and whole and SIZES[string.lower(column)] then
		return {
			show = function(text)
				local n = tonumber(text)
				return if n then core.text.bytes(n) else text
			end,
			right = true,
		}
	elseif all_numbers and whole then
		return { right = true }
	elseif all_numbers then
		-- Fractions to two places, as `map kb = n.size / 1024` makes them.
		return {
			show = function(text)
				local n = tonumber(text)
				return if n then (string.gsub(string.format("%.2f", n), "%.?0+$", "")) else text
			end,
			right = true,
		}
	end
	return {
		show = function(text)
			return nested(text) or text
		end,
		right = false,
	}
end

-- `text` cut to `WIDEST` cells, ending in `…` when it was longer.
local function cut(text: string): string
	if core.text.width(text) <= WIDEST then
		return text
	end
	local out, wide = {}, 0
	for _, code in utf8.codes(text) do
		local char = utf8.char(code)
		local w = core.text.width(char)
		if wide + w > WIDEST - 1 then
			break
		end
		table.insert(out, char)
		wide += w
	end
	return table.concat(out) .. "…"
end

--- `tbl` drawn as aligned lines, the header first, with `rows` (indexes
--- into its rows; all of them by default), and where each column starts.
--- Cells show as `look` says, cut when very wide.
function M.draw(tbl: Table, rows: { number }?): ({ string }, { number })
	local order = rows or query.all(tbl)
	local looks: { Look } = {}
	local shown: { { string } } = {}
	local widths: { number } = {}
	for i, column in tbl.columns do
		looks[i] = M.look(tbl, column, order)
		local show = looks[i].show
		shown[i] = {}
		widths[i] = core.text.width(column)
		for j, index in order do
			local text = tbl.rows[index][column] or ""
			shown[i][j] = cut(if show and text ~= "" then show(text) else text)
			widths[i] = math.max(widths[i], core.text.width(shown[i][j]))
		end
	end
	local starts: { number } = {}
	local at = 0
	for i in tbl.columns do
		starts[i] = at
		at += widths[i] + 3
	end
	-- Numbers line up on the right of their column, the rest on the left.
	local function line(cells: { string }): string
		local parts: { string } = {}
		for i, text in cells do
			local room = string.rep(" ", widths[i] - core.text.width(text))
			local gap = if i < #cells then "   " else ""
			table.insert(parts, if looks[i].right then room .. text .. gap else text .. room .. gap)
		end
		return (string.gsub(table.concat(parts), "%s+$", ""))
	end
	local lines = { line(tbl.columns) }
	for j in order do
		local cells: { string } = {}
		for i in tbl.columns do
			cells[i] = shown[i][j]
		end
		table.insert(lines, line(cells))
	end
	return lines, starts
end

--- `tbl` as text, a line per row under the header, as a stage prints it;
--- `tbl` notes where its header and columns are in it.
function M.text(tbl: Table): string
	local lines, starts = M.draw(tbl)
	tbl.starts, tbl.first, tbl.header = starts, 1, true
	return table.concat(lines, "\n") .. "\n"
end

return M
