local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")
local panes = require("@panes")

local floats = panes.floats

type Area = { x: number, y: number, width: number, height: number }

-- Three floats in the tab, titled a, b and c, the last one in front.
local function three(t: test.TestContext, spec: greed.FloatSpec?): { greed.View }
	t:buffer("|hello")
	local views = {}
	for _, name in { "a", "b", "c" } do
		local float: greed.FloatSpec = if spec then table.clone(spec) else {}
		float.title = name
		table.insert(views, floats.open(greed.create_buffer("scratch", name), float))
	end
	t:draw(80, 24)
	return views
end

-- Where `view` is placed, in cells of the acting client's screen: layouts
-- place floats in shares of it.
local function placed(view: greed.View): Area
	return core.floats.in_cells(view:float_spec() :: greed.FloatSpec) :: Area
end

-- The text of the floats that show, bottom first.
local function shown(): { string }
	local out = {}
	for _, view in floats.list() do
		table.insert(out, view:buffer():text())
	end
	return out
end

local function screen_has(t: test.TestContext, text: string): boolean
	return string.find(table.concat(t:screen(80, 24), "\n"), text, 1, true) ~= nil
end

local function dock(): greed.View?
	for _, view in greed.floats() do
		if view:buffer():kind() == "float-dock" then
			return view
		end
	end
	return nil
end

-- The text of a border label or footer, as a float's spec has it.
local function text_of(line: greed.MarkLine?): string
	if line == nil then
		return ""
	elseif type(line) == "string" then
		return line
	end
	local parts = {}
	for _, piece in line do
		table.insert(parts, piece.text)
	end
	return table.concat(parts)
end

test("one at a time shows only the float in front, and alt-} and alt-{ go round them", function(t)
	three(t)
	t:keys("alt-p O esc")
	assert(floats.current() == "one")
	assert(table.concat(shown()) == "c", table.concat(shown(), ","))
	assert(#floats.all() == 3, "the others are still there")
	t:keys("alt-}")
	assert(table.concat(shown()) == "a" and greed.view():buffer():text() == "a", "round the end")
	t:keys("alt-}")
	assert(table.concat(shown()) == "b")
	t:keys("alt-{ alt-{")
	assert(table.concat(shown()) == "c" and greed.view():buffer():text() == "c")
end)

test("one at a time shows a new float, and the next one when the one in front closes", function(t)
	three(t)
	floats.use("one")
	local d = floats.open(greed.create_buffer("scratch", "d"), { title = "d" })
	t:draw(80, 24)
	assert(table.concat(shown()) == "d", table.concat(shown(), ","))
	t:keys("alt-{ alt-{")
	assert(table.concat(shown()) == "b")
	greed.view():close()
	t:draw(80, 24)
	assert(table.concat(shown()) == "c", "the one after it: " .. table.concat(shown(), ","))
	assert(#floats.all() == 3 and d:valid())
end)

test("focusing a hidden float shows it in place of the one in front", function(t)
	local views = three(t)
	floats.use("one")
	views[1]:focus()
	t:draw(80, 24)
	assert(table.concat(shown()) == "a", table.concat(shown(), ","))
	floats.focus(views[2])
	assert(table.concat(shown()) == "b")
end)

test("one at a time keeps every float in one place, so cycling never moves anything", function(t)
	local views = three(t, { width = 30, height = 10 })
	views[1]:configure({ x = 1, y = 1, width = 20, height = 8 })
	floats.use("one")
	assert(table.concat(shown()) == "c")
	views[3]:configure({ x = 5, y = 2, width = 40, height = 12 })
	t:keys("alt-}")
	local box = placed(views[1])
	assert(table.concat(shown()) == "a")
	assert(box.x == 5 and box.y == 2 and box.width == 40 and box.height == 12, "in its place")
	t:keys("alt-}")
	box = placed(views[2])
	assert(box.x == 5 and box.width == 40, "the next one too")
	-- Back in free, each float is where it was before.
	floats.use("free")
	box = placed(views[1])
	assert(box.x == 1 and box.y == 1 and box.width == 20 and box.height == 8, "its own place")
	-- "deck" is the older name of one.
	floats.use("deck")
	assert(floats.current() == "one")
end)

test("tiled keeps the floats in a grid as they come and go", function(t)
	local views = three(t)
	views[3]:close()
	t:keys("alt-p T esc")
	t:draw(80, 24)
	local a, b = views[1]:area() :: Area, views[2]:area() :: Area
	assert(a.y == b.y and a.x < b.x and a.width == b.width, "side by side")
	floats.open(greed.create_buffer("scratch", "d"), { title = "d" })
	t:draw(80, 24)
	t:draw(80, 24)
	a, b = views[1]:area() :: Area, views[2]:area() :: Area
	local d = floats.all()[3]:area() :: Area
	assert(a.y == b.y and d.y > a.y and d.x == a.x, "two by two now")
	assert(#shown() == 3, "all showing")
end)

test("cascade steps each float down and right, and alt-w goes through the layouts", function(t)
	local views = three(t)
	floats.use("cascade")
	t:draw(80, 24)
	local a, b = views[1]:area() :: Area, views[2]:area() :: Area
	assert(b.x > a.x and b.y > a.y and a.width == b.width, "a step down and right")
	floats.use("free")
	local seen: { string } = {}
	for _ = 1, 4 do
		t:keys("alt-w")
		table.insert(seen, floats.current())
	end
	assert(table.concat(seen, " ") == "one tiled cascade free", table.concat(seen, " "))
	assert(#shown() == 3, "free shows them all again")
end)

test("new tabs take the float-layout option, and layouts of your own join in", function(t)
	t:buffer("|hello")
	greed.option.set("float-layout", "one")
	greed.tab.new()
	assert(floats.current() == "one")
	floats.define("corner", function(a)
		local places = {}
		for i in a.floats do
			places[i] = { box = { x = 0, y = 0, width = 20, height = 5 } }
		end
		return places
	end)
	local view = floats.open(greed.create_buffer("scratch", "x"), { title = "x" })
	floats.use("corner")
	local spec = view:float_spec() :: greed.FloatSpec
	assert(spec.x == 0 and spec.width == 20, "placed by it")
	assert(table.find(floats.names(), "corner"))
end)

test("the float in front says where it is among them, with a dot for each", function(t)
	local views = three(t, { width = 40, height = 10 })
	assert((views[3]:float_spec() :: greed.FloatSpec).label == nil, "nothing in free")
	floats.use("one")
	t:draw(80, 24)
	local spec = views[3]:float_spec() :: greed.FloatSpec
	assert(text_of(spec.label) == "‹ 3/3 ›", text_of(spec.label))
	assert(text_of(spec.footer) == "○ ○ ●  alt-{ alt-}", text_of(spec.footer))
	assert(screen_has(t, "‹ 3/3 ›"), table.concat(t:screen(80, 24), "\n"))
	assert(screen_has(t, "○ ○ ●"))
	t:keys("alt-}")
	assert(text_of((views[1]:float_spec() :: greed.FloatSpec).label) == "‹ 1/3 ›")
	assert(
		text_of((views[3]:float_spec() :: greed.FloatSpec).label) == "",
		"the hidden one has none"
	)

	-- Wide, it names the ones either side.
	views[1]:configure({ width = 76 })
	floats.arrange()
	assert(screen_has(t, "‹ c · 1/3 · b ›"), table.concat(t:screen(80, 24), "\n"))

	-- With one float left, or in tiled, it goes.
	floats.use("tiled")
	assert(text_of((views[1]:float_spec() :: greed.FloatSpec).label) == "")
	floats.use("one")
	views[2]:close()
	views[3]:close()
	t:draw(80, 24)
	assert(text_of((views[1]:float_spec() :: greed.FloatSpec).label) == "")
end)

test("a float that needs you gets a colored dot, until its owner says it doesn't", function(t)
	local views = three(t, { width = 40, height = 10 })
	floats.use("one")
	core.floats.attention(views[1]:buffer(), true)
	assert(core.floats.needs_attention(views[1]:buffer()))
	local footer = (views[3]:float_spec() :: greed.FloatSpec).footer
	local first = (footer :: { { text: string, style: string? } })[1]
	assert(first.text == "●" and first.style == "ui.float.attention", first.text)
	assert(
		string.find((dock() :: greed.View):buffer():text(), "1 a ●", 1, true),
		"in the dock too"
	)
	core.floats.attention(views[1]:buffer(), false)
	footer = (views[3]:float_spec() :: greed.FloatSpec).footer
	assert(text_of(footer) == "○ ○ ●  alt-{ alt-}", text_of(footer))
end)

test("the dock lists the floats while some are hidden, and a click brings one forward", function(t)
	three(t)
	assert(dock() == nil, "no dock in free")
	floats.use("one")
	t:draw(80, 24)
	local bar = dock() :: greed.View
	assert(bar:buffer():text() == " 1 a   2 b   3 c  ", `"{bar:buffer():text()}"`)
	local rows = t:screen(80, 24)
	local row = 0
	for i, line in rows do
		if string.find(line, " 1 a   2 b", 1, true) then
			row = i - 1
		end
	end
	assert(row == (bar:area() :: Area).y, `on the screen at row {row}`)
	local col = (string.find(rows[row + 1], "2 b", 1, true) :: number) - 1
	t:mouse("press", col, row)
	t:mouse("release", col, row)
	assert(table.concat(shown()) == "b" and greed.view():buffer():text() == "b", "b came forward")

	-- Shown or hidden by hand, and gone in a layout that hides nothing.
	floats.toggle_dock()
	assert(dock() == nil)
	floats.toggle_dock()
	assert(dock() ~= nil)
	floats.use("tiled")
	floats.toggle_dock()
	assert(dock() == nil)
end)

test("alt-W picks from the dock by number, or with the arrows and enter", function(t)
	three(t)
	floats.use("one")
	t:keys("alt-W 1")
	assert(table.concat(shown()) == "a")
	t:keys("alt-W right right enter")
	assert(table.concat(shown()) == "c")
	t:keys("alt-W left")
	assert(string.find((dock() :: greed.View):buffer():text(), "2 b", 1, true) ~= nil)
	t:keys("x")
	assert(table.concat(shown()) == "c", "any other key leaves it")
	assert(greed.mode.get() == "helix")
end)

test("alt-f hides them all in one at a time and brings back the one in front", function(t)
	three(t)
	floats.use("one")
	t:keys("alt-{")
	t:keys("alt-f")
	assert(#shown() == 0 and dock() == nil, "all hidden, no dock")
	t:keys("alt-f")
	assert(table.concat(shown()) == "b" and greed.view():buffer():text() == "b")
end)

test("plugins show a buffer in a float of the tab, the same one each time", function(t)
	t:buffer("|hello")
	floats.use("one")
	local session = greed.create_buffer("scratch", "session")
	local other = floats.show(greed.create_buffer("scratch", "other"), { title = "other" })
	local view = floats.show(session, { title = "session" })
	assert(table.concat(shown()) == "session")
	floats.focus(other)
	assert(table.concat(shown()) == "other")
	assert(floats.show(session) == view, "the float it has")
	assert(table.concat(shown()) == "session" and greed.view() == view)
end)

test("a command finishing in a hidden floating terminal wants a look", function(t)
	t:buffer("|hello")
	floats.use("one")
	local terminal = require("@terminal")
	local term = terminal.open({ "sh", "-c", "sleep 0.3; exit 3" }, { float = { title = "job" } })
	floats.open(greed.create_buffer("scratch", "x"), { title = "x" })
	t:draw(80, 24)
	assert(table.concat(shown()) == "x")
	t:wait_for(function()
		return core.floats.needs_attention(term.buffer)
	end)
	t:keys("alt-}")
	t:draw(80, 24)
	assert(not core.floats.needs_attention(term.buffer), "seen")
end)

test("a float layout places floats in proportion on clients of other sizes", function(t)
	local views = three(t)
	local second = t:client()
	t:keys("alt-p T esc")
	t:draw(80, 25)
	second:draw(40, 13)
	-- The first's screen above the status line is 80 by 24, the second's
	-- 40 by 12: every float is where it is on the first's, halved.
	local mine: { Area } = {}
	t:draw(80, 25)
	for i, view in views do
		mine[i] = view:area() :: Area
	end
	second:draw(40, 13)
	local theirs: { Area } = {}
	greed.command({
		name = "test-areas",
		run = function()
			for i, view in views do
				theirs[i] = view:area() :: Area
			end
		end,
	})
	second:run("test-areas")
	for i in views do
		-- The outside of each box, border included, halves exactly.
		local a, b = mine[i], theirs[i]
		assert(
			b.x - 1 == (a.x - 1) // 2 and b.y - 1 == (a.y - 1) // 2,
			`float {i}: {a.x},{a.y} and {b.x},{b.y}`
		)
		assert(
			b.width + 2 == (a.width + 2) // 2 and b.height + 2 == (a.height + 2) // 2,
			`float {i}: {a.width}x{a.height} and {b.width}x{b.height}`
		)
	end
end)

test("of two floats one at a time, the other is named once, on its side", function(t)
	t:buffer("|hello")
	local a = floats.open(greed.create_buffer("scratch", "a"), { title = "a", width = 76 })
	local b = floats.open(greed.create_buffer("scratch", "b"), { title = "b", width = 76 })
	floats.use("one")
	t:draw(80, 24)
	assert(text_of((b:float_spec() :: greed.FloatSpec).label) == "‹ a · 2/2 ›")
	t:keys("alt-}")
	t:draw(80, 24)
	assert(text_of((a:float_spec() :: greed.FloatSpec).label) == "‹ 1/2 · b ›")
end)

test("floating terminals are named by what they run and where", function(t)
	t:buffer("|hello")
	local dir = t:tempdir()
	greed.option.set("terminal-shell", "cat")
	require("@terminal").open({ "cat" }, { float = true, cwd = dir })
	require("@terminal").open({ "sh" }, { float = true, cwd = dir })
	t:keys("ctrl-\\")
	floats.use("one")
	t:draw(100, 30)
	local listed = (dock() :: greed.View):buffer():text()
	local short = core.project.tilde(dir)
	assert(string.find(listed, `1 cat {short}`, 1, true), listed)
	assert(string.find(listed, `2 sh {short}`, 1, true), listed)
	assert(screen_has(t, `─ sh {short} `), table.concat(t:screen(100, 30), "\n"))
	-- The status line names the float in front, not the pane behind it.
	local left = t:status()
	assert(string.find(left or "", `terminal: sh {short}`, 1, true), left)
	assert(not string.find(left or "", "[+]", 1, true), left)
end)

test("a float put back as a pane is drawn where it went", function(t)
	t:buffer("|hello")
	t:keys("ctrl-w v")
	t:draw(80, 24)
	local notes = greed.create_buffer("file", "notes here")
	local float = floats.open(notes)
	float:focus()
	t:draw(80, 24)
	for _, layout in { "manual", "main-stack" } do
		panes.layouts.use(layout)
		t:keys("alt-p e esc")
		local pane = greed.view()
		assert(pane:is_pane() and pane:buffer() == notes, layout)
		local rows = t:draw(80, 24)
		assert(pane:area() ~= nil, `{layout}: drawn`)
		assert(
			string.find(table.concat(rows, "\n"), "notes here", 1, true),
			table.concat(rows, "\n")
		)
		t:keys("alt-p e esc")
		assert(greed.view():float_spec() ~= nil, "floating again")
		t:draw(80, 24)
	end
end)
