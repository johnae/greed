-- From a table and what `chart` was given to a chart: which columns are
-- numbers, what they're over or by, and which kind of chart suits them,
-- unless it's said. In a watch, each run adds a point to every series, so
-- the chart is of how they went.

local shell = require("@shell")
local draw = require("./draw")
local scale = require("./scale")

local tables = shell.tables

type Table = shell.Table

local M = {}

--- What `chart` was asked for.
export type Ask = {
	kind: string?,
	columns: { string },
	by: string?,
	over: string?,
	stacked: boolean,
	log: boolean,
	--- How many points of each series a watch keeps.
	last: number,
	width: number?,
	height: number?,
}

--- The points a watch's chart has had, by series, the order they came,
--- and what the chart was asked for, to start again when that changes.
export type History = { key: string, series: { [string]: { { number } } }, order: { string } }

local KINDS: { [string]: string } = {
	line = "line",
	lines = "line",
	area = "area",
	bar = "bar",
	bars = "bar",
	scatter = "scatter",
	dots = "scatter",
}

local LAST = 120

--- The usage, for `help` and errors.
M.USAGE =
	"chart [line|area|bar|scatter] [COLUMN...] [by COLUMN] [over COLUMN] [--stacked] [--log] [--last N] [--width N] [--height N]"

--- Reads what follows `chart`: nil and why when it can't.
function M.ask(text: string): (Ask?, string?)
	local ask: Ask = { columns = {}, stacked = false, log = false, last = LAST }
	local words: { string } = {}
	for word in string.gmatch(text, "%S+") do
		table.insert(words, word)
	end
	local i = 1
	while i <= #words do
		local word = words[i]
		local function value(): number?
			i += 1
			return tonumber(words[i])
		end
		if word == "--stacked" then
			ask.stacked = true
		elseif word == "--log" then
			ask.log = true
		elseif word == "--last" or word == "--width" or word == "--height" then
			local n = value()
			if n == nil or n < 1 then
				return nil, `{word} takes a number: {M.USAGE}`
			end
			if word == "--last" then
				ask.last = math.floor(n)
			elseif word == "--width" then
				ask.width = math.floor(n)
			else
				ask.height = math.floor(n)
			end
		elseif string.sub(word, 1, 2) == "--" then
			return nil, `there's no {word}: {M.USAGE}`
		elseif (word == "by" or word == "over") and words[i + 1] then
			i += 1
			if word == "by" then
				ask.by = words[i]
			else
				ask.over = words[i]
			end
		elseif i == 1 and KINDS[word] then
			ask.kind = KINDS[word]
		else
			table.insert(ask.columns, word)
		end
		i += 1
	end
	return ask, nil
end

--- A watch's history for a chart asked for as `key`, empty.
function M.history(key: string): History
	return { key = key, series = {}, order = {} }
end

-- Whether `column`'s cells are mostly numbers, leaving out durations like
-- AGE, which go up by themselves.
local function numeric(tbl: Table, column: string): boolean
	if tables.durations(tbl, column) then
		return false
	end
	local numbers, filled = 0, 0
	for _, row in tbl.rows do
		local cell = row[column] or ""
		if string.match(cell, "%S") then
			filled += 1
			if tables.number(cell) then
				numbers += 1
			end
		end
	end
	return filled > 0 and numbers * 2 > filled
end

-- Whether `column` holds times: it's called so, or every cell is a date
-- and time.
local function times(tbl: Table, column: string): boolean
	local name = string.lower(column)
	if name == "time" or name == "date" or name == "timestamp" or name == "ts" then
		return true
	end
	for _, row in tbl.rows do
		if tables.iso_time(row[column] or "") == nil then
			return false
		end
	end
	return #tbl.rows > 0
end

-- `cell` as an x value: a date and time in seconds, or a number.
local function x_of(cell: string): (number?, boolean)
	local seconds = tables.iso_time(cell)
	if seconds then
		return seconds, true
	end
	return tables.number(cell), false
end

-- Whether `tbl` is text read as words, its columns 1, 2 and so on.
local function from_words(tbl: Table): boolean
	return #tbl.columns > 0 and tbl.columns[1] == "1"
end

-- A few of `values` with their names, for what the chart says it shows.
local function some(names: { string }, values: { number }, unit: string?): string
	local parts: { string } = {}
	for i = 1, math.min(#names, 3) do
		table.insert(parts, `{names[i]} {scale.format(values[i], nil, unit)}`)
	end
	if #names > 3 then
		table.insert(parts, `+{#names - 3} more`)
	end
	return table.concat(parts, ", ")
end

--- The chart `ask` makes of `tbl`: in a watch, with its `history` (which
--- it adds to, at `now`, in seconds since 1970), of how the numbers went.
--- Nil and why when there's nothing to chart.
function M.chart(tbl: Table, ask: Ask, history: History?, now: number): (draw.Chart?, string?)
	local function column(name: string): (string?, string?)
		local found = tables.column(tbl, name)
		if found == nil then
			return nil, `there's no column {name}; there are {table.concat(tbl.columns, ", ")}`
		end
		return found, nil
	end
	local by, over
	if ask.by then
		local why
		by, why = column(ask.by)
		if by == nil then
			return nil, why
		end
	end
	if ask.over then
		local why
		over, why = column(ask.over)
		if over == nil then
			return nil, why
		end
	end
	local ys: { string } = {}
	for _, name in ask.columns do
		local found, why = column(name)
		if found == nil then
			return nil, why
		end
		table.insert(ys, found)
	end
	-- The time column, a name column, and the numbers, unless they're said.
	local time = over
	if time == nil and by == nil then
		for _, c in tbl.columns do
			if not numeric(tbl, c) and times(tbl, c) then
				time = c
				break
			end
		end
	end
	-- Text read as words has no column of names: a row is named by its
	-- words that aren't numbers, as `git shortlog -sn`'s authors are.
	local worded = from_words(tbl)
	local names = by
	if names == nil and not worded then
		for _, c in tbl.columns do
			if c ~= time and not numeric(tbl, c) then
				names = c
				break
			end
		end
	end
	if #ys == 0 then
		for _, c in tbl.columns do
			if c ~= time and c ~= names and c ~= over and numeric(tbl, c) then
				table.insert(ys, c)
				-- Rows with names, or words from text: their first number,
				-- as other numbers are often of another kind (CPU, then
				-- bytes) and one would hide the other.
				if worded or (names and time == nil) then
					break
				end
			end
		end
	end
	if #ys == 0 then
		return nil, `there are no numbers to chart in {table.concat(tbl.columns, ", ")}`
	end
	while #ys > 8 do
		table.remove(ys)
	end
	-- What the numbers are, by how a column writes them: bytes, CPU, percents.
	local function unit_of(c: string): string?
		local cells: { string } = {}
		for _, row in tbl.rows do
			table.insert(cells, row[c] or "")
		end
		return scale.unit(cells)
	end
	local unit = unit_of(ys[1])
	-- What's asked for, or "" to guess.
	local kind: string = ask.kind or ""
	local function label(i: number): string
		local row = tbl.rows[i]
		if names and row[names] ~= "" then
			return row[names]
		end
		local words: { string } = {}
		if worded then
			for _, c in tbl.columns do
				local cell = row[c]
				if cell and tables.number(cell) == nil then
					table.insert(words, cell)
				end
			end
		end
		return if #words > 0 then table.concat(words, " ") else tostring(i)
	end
	-- Whether rows have names to tell them apart by: a column of them, or
	-- words in each of several rows of text.
	local named = names ~= nil
	if worded and #tbl.rows > 1 then
		named = true
		for i in tbl.rows do
			named = named and label(i) ~= tostring(i)
		end
	end

	-- In a watch, how each number went from run to run.
	local over_runs = history ~= nil and kind ~= "bar" and kind ~= "scatter" and time == nil
	if history and over_runs then
		local latest: { string } = {}
		local values: { number } = {}
		for i, row in tbl.rows do
			for _, c in ys do
				local v = tables.number(row[c] or "")
				if v then
					local name = if #tbl.rows == 1
						then c
						elseif #ys == 1 then label(i)
						else `{label(i)} {c}`
					local points = history.series[name]
					if points == nil then
						points = {}
						history.series[name] = points
						table.insert(history.order, name)
					end
					table.insert(points, { now, v })
					while #points > ask.last do
						table.remove(points, 1)
					end
					table.insert(latest, name)
					table.insert(values, v)
				end
			end
		end
		local series: { draw.Series } = {}
		for _, name in history.order do
			if #series < 8 then
				table.insert(series, { name = name, points = history.series[name] })
			end
		end
		return {
			kind = if kind == "" then "line" else kind,
			series = series,
			x = "time",
			log = ask.log,
			unit = unit,
			about = `{table.concat(ys, ", ")} over time: {some(latest, values, unit)}`,
		},
			nil
	end

	-- Over a time or another column: a line a number.
	local over_column = time ~= nil or (over ~= nil and kind ~= "bar")
	if over_column then
		local x = (time or over) :: string
		local series: { draw.Series } = {}
		local dated = false
		for _, c in ys do
			local points: { { number } } = {}
			for _, row in tbl.rows do
				local at, is_time = x_of(row[x] or "")
				local v = tables.number(row[c] or "")
				if at and v then
					table.insert(points, { at, v })
					dated = dated or is_time
				end
			end
			table.sort(points, function(a: { number }, b: { number }): boolean
				return (a[1] :: number) < (b[1] :: number)
			end)
			table.insert(series, { name = c, points = points })
		end
		return {
			kind = if kind == "" then "line" else kind,
			series = series,
			x = if dated then "time" else "number",
			log = ask.log,
			unit = unit,
			about = `{table.concat(ys, ", ")} over {x}`,
		},
			nil
	end

	-- Two numbers and nothing to name them by: one against the other.
	if kind == "scatter" or (kind == "" and not named and #ys == 2) then
		if #ys < 2 then
			return nil, "scatter needs two number columns, x then y"
		end
		local points: { { number } } = {}
		for _, row in tbl.rows do
			local x, y = tables.number(row[ys[1]] or ""), tables.number(row[ys[2]] or "")
			if x and y then
				table.insert(points, { x, y })
			end
		end
		return {
			kind = "scatter",
			series = { { name = `{ys[2]} by {ys[1]}`, points = points } },
			x = "number",
			log = ask.log,
			unit = if #ys > 1 then unit_of(ys[2]) else unit,
			about = `{ys[2]} against {ys[1]}, {#points} points`,
		},
			nil
	end

	-- Something to name the rows by: a bar each.
	if kind == "bar" or (kind == "" and named) then
		local labels: { string } = {}
		for i in tbl.rows do
			table.insert(labels, label(i))
		end
		local series: { draw.Series } = {}
		for _, c in ys do
			local points: { { number } } = {}
			for i, row in tbl.rows do
				points[i] = { i, tables.number(row[c] or "") or 0 }
			end
			table.insert(series, { name = c, points = points, unit = unit_of(c) })
		end
		local first: { number } = {}
		for i in tbl.rows do
			first[i] = series[1].points[i][2]
		end
		return {
			kind = "bar",
			series = series,
			labels = labels,
			x = "index",
			stacked = ask.stacked,
			unit = unit,
			about = `{table.concat(ys, ", ")}{if names then " by " .. names else ""}: {some(
				labels,
				first,
				unit
			)}`,
		},
			nil
	end

	-- Numbers alone: a line each, row by row.
	local series: { draw.Series } = {}
	for _, c in ys do
		local points: { { number } } = {}
		for i, row in tbl.rows do
			local v = tables.number(row[c] or "")
			if v then
				table.insert(points, { i, v })
			end
		end
		table.insert(series, { name = c, points = points })
	end
	return {
		kind = if kind == "" then "line" else kind,
		series = series,
		x = "index",
		log = ask.log,
		unit = unit,
		about = `{table.concat(ys, ", ")}, {#tbl.rows} rows`,
	},
		nil
end

return M
