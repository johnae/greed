local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")
local effects = core.effects

test("a wave is brightest in its middle and fades either side", function()
	local lit = effects.wave(9, 0.5)
	assert(lit[5] == 1, "the middle character is fully lit: " .. lit[5])
	assert(lit[4] < 1 and lit[4] > lit[3] and lit[3] > lit[2], "fading to the left")
	assert(lit[6] == lit[4] and lit[7] == lit[3], "and the same to the right")
	assert(lit[1] == 0 and lit[9] == 0, "the ends are dark")
	local start, finish = effects.wave(9, 0), effects.wave(9, 1)
	for i = 1, 9 do
		assert(start[i] == 0 and finish[i] == 0, "it comes in and goes out")
	end
end)

test("colors mix, and lightness tells light from dark", function()
	assert(effects.mix({ 0, 0, 0 }, { 255, 255, 255 }, 0.5) == "#808080")
	assert((effects.rgb("#ff8000") :: { number })[2] == 128)
	assert(effects.rgb("red") == nil, "only #rrggbb")
	assert(
		math.abs(effects.lightness({ 255, 255, 255 }) - 1) < 1e-9
			and effects.lightness({ 0, 0, 0 }) == 0
	)
end)

test("a burst starts in the middle and spreads out both ways", function()
	local start = effects.burst(9, 0)
	assert(start[5] == 1 and start[4] < 1, "lit in the middle first")
	local later = effects.burst(9, 0.4)
	assert(later[5] < later[3] and later[3] == later[7], "the crests have moved out, together")
	local finish = effects.burst(9, 1)
	for i = 1, 9 do
		assert(finish[i] == 0, "gone at the end")
	end
end)

-- A file with `lines` lines open in the focused view, and its buffer.
local function file(t: any, lines: number?): greed.Buffer
	local text = {}
	for i = 1, lines or 3 do
		table.insert(text, `line {i}`)
	end
	local dir = t:tempdir({ ["a.txt"] = table.concat(text, "\n") .. "\n" })
	greed.open(dir .. "/a.txt")
	return greed.view():buffer()
end

-- The changed-text highlights in `buffer`, as their text and style.
local function changes(buffer: greed.Buffer): { { text: string, style: string, line: boolean } }
	local out = {}
	for _, mark in buffer:decorations("ui.changed") do
		table.insert(out, {
			text = buffer:slice(mark.from, mark.to),
			style = mark.style,
			line = mark.line == true,
		})
	end
	return out
end

test("text someone else changed lights up, then fades out", function(t)
	greed.theme.set({ ["ui.changed"] = { bg = "#806000" }, ["ui.text"] = { bg = "#000000" } })
	local buffer = file(t)
	buffer:edit(function(e)
		e:replace(5, 6, "one")
	end)
	local lit = changes(buffer)
	assert(#lit == 1 and lit[1].text == "one", `the new text is lit: {#lit}`)
	local first = lit[1].style
	local full = greed.theme.get(first) :: greed.ThemeEntry
	assert(full.bg == "#806000", `it starts at the theme's color: {full.bg}`)
	t:wait(800)
	lit = changes(buffer)
	assert(#lit == 1 and lit[1].style == first, "held at first")
	t:wait(1000)
	lit = changes(buffer)
	assert(#lit == 1 and lit[1].style ~= first, "then fading")
	local half = (greed.theme.get(lit[1].style) :: greed.ThemeEntry).bg
	assert(half ~= "#806000" and half ~= "#000000", `in between: {half}`)
	t:wait(900)
	assert(#changes(buffer) == 0, "and gone")
end)

test("a terminal shows the same fade, a step at a time", function(t)
	greed.theme.set({ ["ui.changed"] = { bg = "#806000" }, ["ui.text"] = { bg = "#000000" } })
	local buffer = file(t)
	buffer:edit(function(e)
		e:replace(0, 4, "LINE")
	end)
	-- The backgrounds of the first row's cells that aren't the text's.
	local function lit(): { string }
		local frame = t:frame(30, 5, "terminal")
		local out = {}
		for col = 0, 29 do
			local cell = frame.cell(col, 0)
			if cell and cell.bg and cell.bg ~= "#000000" then
				table.insert(out, cell.bg)
			end
		end
		return out
	end
	local now = lit()
	assert(#now == 4 and now[1] == "#806000", `lit: {table.concat(now, " ")}`)
	t:wait(1800)
	now = lit()
	assert(#now == 4 and now[1] ~= "#806000", `fading: {table.concat(now, " ")}`)
	t:wait(900)
	assert(#lit() == 0, "back to the background")
end)

test("lines someone else added light up as whole lines", function(t)
	local buffer = file(t)
	buffer:edit(function(e)
		e:insert(buffer:line_start(1), "new a\nnew b\n")
	end)
	local lit = changes(buffer)
	assert(#lit == 1 and lit[1].line, "one mark over whole lines")
	assert(lit[1].text == "new a\nnew b", lit[1].text)
end)

test("your own typing, and undoing it, light nothing", function(t)
	local buffer = file(t)
	t:keys("i x y esc")
	assert(#changes(buffer) == 0, "typing")
	t:keys("u")
	assert(#changes(buffer) == 0, "undo")
end)

test("undoing someone else's edit lights nothing", function(t)
	local buffer = file(t)
	buffer:edit(function(e)
		e:insert(0, "agent ")
	end)
	t:wait(2000)
	t:keys("u")
	assert(buffer:text() == "line 1\nline 2\nline 3\n", buffer:text())
	assert(#changes(buffer) == 0)
end)

test("a buffer nobody is looking at lights nothing", function(t)
	local dir = t:tempdir({ ["hidden.txt"] = "hello\n" })
	local buffer = greed.load(dir .. "/hidden.txt")
	buffer:edit(function(e)
		e:insert(0, "x")
	end)
	assert(#changes(buffer) == 0)
end)

test("effects-changes off lights nothing", function(t)
	greed.option.set("effects-changes", false)
	local buffer = file(t)
	buffer:edit(function(e)
		e:insert(0, "x")
	end)
	assert(#changes(buffer) == 0)
end)

-- The jump highlights in the focused view's buffer, as 0-based lines.
local function flashed(): { number }
	local buffer = greed.view():buffer()
	local out = {}
	for _, mark in buffer:decorations("ui.jumped") do
		assert(mark.line, "a whole line")
		table.insert(out, buffer:line_of(mark.from))
	end
	return out
end

test("a jump flashes the line it lands on, briefly", function(t)
	file(t, 200)
	t:keys("G")
	local lines = flashed()
	assert(#lines == 1 and lines[1] == 200, `the last line: {lines[1]}`)
	t:wait(500)
	assert(#flashed() == 0, "and goes")
	t:keys("ctrl-o")
	lines = flashed()
	assert(#lines == 1 and lines[1] == 0, "going back flashes too")
end)

test("a search hit flashes, even close by", function(t)
	file(t, 5)
	t:keys("/")
	t:type("line [34]")
	assert(#flashed() == 0, "not while typing the search")
	t:keys("enter")
	local lines = flashed()
	assert(#lines == 1 and lines[1] == 2, `the hit's line: {lines[1]}`)
	t:wait(500)
	t:keys("n")
	lines = flashed()
	assert(#lines == 1 and lines[1] == 3, "the next hit")
end)

test("ordinary motions flash nothing, unless they go more than a screen", function(t)
	file(t, 300)
	t:keys("j j w")
	assert(#flashed() == 0, "short moves")
	t:keys("1 5 0 j")
	assert(#flashed() == 1, "a long way")
end)

test("effects-jumps off flashes nothing", function(t)
	greed.option.set("effects-jumps", false)
	file(t, 200)
	t:keys("G")
	assert(#flashed() == 0)
end)
