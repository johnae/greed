local test = require("@greed/test")
local greed = require("@greed")

local COSTS = [[
<!-- id=costs -->
| Item | Amount | Per year |
|------|-------:|---------:|
| Rent | 900    |          |
| Food | 350    |          |
<!-- formula: per_year = amount * 12 -->
<!-- chart: bar per_year -->

after]]

-- `text` open as a Markdown file, the cursor at its end; the buffer.
local function open(t: test.TestContext, text: string): greed.Buffer
	local dir = t:tempdir({ ["doc.md"] = text .. "\n" })
	greed.open(`{dir}/doc.md`)
	local view = greed.view()
	view:buffer():set_line_numbers(false)
	local last = view:buffer():len()
	view:set_selection({ ranges = { { anchor = last, head = last } }, primary = 1 })
	return view:buffer()
end

-- The marks the chart layer drew, as their lines' text.
local function drawn(buffer: greed.Buffer): string
	local out: { string } = {}
	for _, mark in buffer:decorations("chart-tables") do
		local lines: { greed.MarkLine } = mark.lines or {}
		for _, line in lines do
			if type(line) == "string" then
				table.insert(out, line)
			else
				local parts: { string } = {}
				for _, piece in line do
					table.insert(parts, piece.text)
				end
				table.insert(out, table.concat(parts))
			end
		end
	end
	return table.concat(out, "\n")
end

test("a chart line under a table draws it, formulas worked out, as | chart would", function(t)
	local buffer = open(t, COSTS)
	local chart = drawn(buffer)
	assert(string.find(chart, "Rent", 1, true) and string.find(chart, "Food", 1, true), chart)
	assert(string.find(chart, "10.8k", 1, true) or string.find(chart, "10800", 1, true), chart)
	-- On screen, under the table and before what follows.
	local rows = table.concat(t:draw(70, 40), "\n")
	assert(string.find(rows, "Rent", string.find(rows, "└", 1, true), true), rows)
	-- A cell changed: the chart follows.
	local at = (string.find(buffer:text(), "900", 1, true) :: number) - 1
	buffer:edit(function(e)
		e:replace(at, at + 3, "100")
	end)
	t:wait_for(function()
		local now = drawn(buffer)
		return now ~= chart
			and (
				string.find(now, "1.2k", 1, true) ~= nil
				or string.find(now, "1200", 1, true) ~= nil
			)
	end)
end)

test("a chart that can't be drawn says why where it would be", function(t)
	local buffer = open(t, "| a | b |\n|---|---|\n| x | y |\n<!-- chart: bar nosuch -->\n")
	assert(string.find(drawn(buffer), "⚠", 1, true), drawn(buffer))
end)
