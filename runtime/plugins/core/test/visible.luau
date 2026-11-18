local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")

-- A painter on this test's buffer marking each line's first character,
-- and the runs of lines it was asked to draw.
local function painter(t: any, lines: boolean?): ({ { number } }, greed.Buffer)
	t:buffer("|one\ntwo\nthree\nfour")
	local buffer = greed.view():buffer()
	local asked: { { number } } = {}
	core.visible.add({
		ns = "test-visible",
		lines = lines,
		wants = function(b: greed.Buffer): boolean
			return b == buffer
		end,
		draw = function(b: greed.Buffer, first: number, last: number): { greed.Mark }
			table.insert(asked, { first, last })
			local marks: { greed.Mark } = {}
			for n = first, last do
				local start = b:line_start(n)
				table.insert(marks, { from = start, to = start + 1, style = "ui.test" })
			end
			return marks
		end,
	})
	t:draw(20, 6)
	table.clear(asked)
	return asked, buffer
end

-- Where the marks start, in order.
local function starts(buffer: greed.Buffer): string
	local at = {}
	for _, mark in buffer:decorations("test-visible") do
		table.insert(at, mark.from)
	end
	table.sort(at)
	return table.concat(at, ",")
end

local function edit(t: any, buffer: greed.Buffer, at: number, text: string)
	buffer:edit(function(e)
		e:insert(at, text)
	end)
	t:draw(20, 6)
end

test("a painter whose lines stand alone redraws only the line an edit changed", function(t)
	local asked, buffer = painter(t, true)
	edit(t, buffer, 5, "x")
	assert(#asked == 1 and asked[1][1] == 1 and asked[1][2] == 1, `asked {#asked} runs`)
	assert(starts(buffer) == "0,4,9,15", starts(buffer))
end)

test("an edit that adds lines redraws every line in sight", function(t)
	local asked, buffer = painter(t, true)
	edit(t, buffer, 4, "new\n")
	assert(#asked == 1 and asked[1][1] == 0 and asked[1][2] == 4, `asked {#asked} runs`)
	assert(starts(buffer) == "0,4,8,12,18", starts(buffer))
end)

test("a painter whose lines depend on others redraws every line in sight", function(t)
	local asked, buffer = painter(t, nil)
	edit(t, buffer, 5, "x")
	assert(#asked == 1 and asked[1][1] == 0 and asked[1][2] == 3, `asked {#asked} runs`)
	assert(starts(buffer) == "0,4,9,15", starts(buffer))
end)
