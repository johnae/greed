local test = require("@greed/test")
local greed = require("@greed")
local panes = require("@panes")

-- New terminals run cat, which ends on ctrl-d whatever your shell is.
local function cat()
	greed.option.set("terminal-shell", "cat")
end

local function count(): number
	return #greed.tab.current().panes
end

-- Two panes of the same text side by side, the right one focused.
local function two(t: test.TestContext): (greed.View, greed.View)
	t:buffer("|hello")
	local left = greed.view()
	t:keys("ctrl-w v")
	local right = greed.view()
	t:draw(80, 20)
	return left, right
end

test("ctrl-w v splits, and alt-h and alt-l move between panes", function(t)
	local left, right = two(t)
	assert(count() == 2)
	assert(left:id() ~= right:id())
	t:keys("alt-h")
	assert(greed.view():id() == left:id())
	t:keys("alt-l")
	assert(greed.view():id() == right:id())
	-- Nothing to the right, and only one tab: it stays.
	t:keys("alt-l")
	assert(greed.view():id() == right:id())
end)

test("ctrl-w s splits below, and ctrl-w q closes", function(t)
	t:buffer("|hello")
	local top = greed.view()
	t:keys("ctrl-w s")
	t:draw(80, 20)
	t:keys("alt-k")
	assert(greed.view():id() == top:id())
	t:keys("ctrl-w q")
	assert(count() == 1)
	t:keys("ctrl-w q")
	assert(count() == 1, "the last pane stays")
end)

test("alt-n opens a terminal pane that takes keys, and moving away stops that", function(t)
	cat()
	t:buffer("|hello")
	t:draw(80, 20)
	t:keys("alt-n")
	assert(count() == 2)
	assert(greed.view():buffer():kind() == "terminal")
	assert(greed.mode.get() == "terminal")
	t:draw(80, 20)
	-- The everywhere keys work while typing into a terminal.
	t:keys("alt-h")
	assert(greed.mode.get() == "helix")
	assert(greed.view():buffer():kind() == "file")
	t:keys("alt-l")
	assert(greed.mode.get() == "terminal")
	t:keys("ctrl-d")
	t:wait_for(function()
		return count() == 1
	end)
end)

test("a terminal pane closes when its program ends well", function(t)
	t:buffer("|hello")
	t:draw(80, 20)
	panes.terminal_pane("down", { "true" })
	assert(count() == 2)
	t:wait_for(function()
		return count() == 1
	end)
	assert(greed.view():buffer():kind() == "file")
	assert(greed.mode.get() == "helix")
end)

test("closing a terminal's float ends its program, with pane-close or :q", function(t)
	local terminal = require("@terminal")
	t:buffer("|hello")
	t:draw(80, 20)
	for _, close in { "pane-close", "quit" } do
		local term = terminal.open({ "cat" }, { float = true })
		local buffer = term.buffer
		assert(greed.view():float_spec(), "in a float")
		t:keys("ctrl-\\")
		t:run(close)
		assert(not terminal.is_open(term), `{close} ended it`)
		assert(terminal.terminal(buffer) == nil, "no terminal left")
	end
end)

test("the pane mode takes single keys until esc", function(t)
	t:buffer("|hello")
	t:keys("alt-p")
	assert(greed.mode.get() == "pane")
	local said = table.concat(t:messages(), "\n")
	assert(string.find(said, "hjkl move", 1, true), said)
	t:keys("v")
	assert(count() == 2)
	assert(greed.mode.get() == "pane", "it stays in the mode")
	t:draw(80, 20)
	t:keys("h esc")
	assert(greed.mode.get() == "helix")
	assert(greed.view():id() == greed.tab.current().panes[1]:id())
	-- A key the mode doesn't have leaves it.
	t:keys("alt-p q")
	assert(greed.mode.get() == "helix")
end)

test("the tab mode opens, switches and closes tabs", function(t)
	t:buffer("|hello")
	t:keys("alt-t n")
	assert(#greed.tab.list() == 2)
	assert(greed.mode.get() == "helix", "opening a tab leaves the mode")
	t:keys("alt-[")
	assert(greed.tab.list()[1].current)
	t:keys("alt-2")
	assert(greed.tab.list()[2].current)
	t:keys("alt-t h")
	assert(greed.tab.list()[1].current)
	t:keys("esc alt-t x")
	assert(#greed.tab.list() == 1)
end)

test("at the left or right edge, moving goes on to the next tab, and stops at the ends", function(t)
	t:buffer("|hello")
	t:keys("alt-t n")
	t:draw(80, 20)
	t:keys("alt-l")
	assert(greed.tab.list()[2].current, "not round the end to the first")
	t:keys("alt-h")
	assert(greed.tab.list()[1].current, "on to the tab before")
	t:keys("alt-h")
	assert(greed.tab.list()[1].current, "not round the start to the last")
	t:keys("alt-l")
	assert(greed.tab.list()[2].current, "on to the tab after")
	-- alt-< and alt-> go round, for terminals that can't send alt-[ and alt-].
	t:keys("alt->")
	assert(greed.tab.list()[1].current)
	t:keys("alt-<")
	assert(greed.tab.list()[2].current)
end)

test("a panel at the edge stays where it is rather than going on to another tab", function(t)
	t:buffer("|hello")
	t:keys("alt-t n alt-1")
	local panel =
		greed.panel(greed.create_buffer("notes", "a panel"), { side = "right", width = 20 })
	t:draw(80, 20)
	assert(greed.view() == panel)
	t:keys("alt-l")
	assert(greed.tab.list()[1].current and greed.view() == panel, "still in the panel")
	panel:close()
end)

test("moving in a zoomed tab shows every pane again, and stays zoomed at an edge", function(t)
	t:buffer("|hello")
	t:keys("alt-p v f esc")
	t:draw(80, 20)
	assert(greed.tab.current().zoomed)
	local right = greed.view()
	t:keys("alt-l")
	t:draw(80, 20)
	t:wait(0)
	assert(greed.tab.current().zoomed and greed.view() == right, "nothing that way")
	t:keys("alt-h")
	t:draw(80, 20)
	t:wait(0)
	assert(not greed.tab.current().zoomed, "every pane shows")
	assert(greed.view() == greed.tab.current().panes[1], "on the left one")
end)

test(
	"esc on the pane labels leaves the pane mode; the status line shows layout and zoom",
	function(t)
		t:buffer("|hello")
		t:keys("alt-p v")
		t:draw(80, 20)
		t:keys("g esc")
		assert(greed.mode.get() == "helix", greed.mode.get())
		-- A space now is the leader's, not the next layout.
		t:keys("space esc")
		assert(panes.layouts.current() == "manual")
		local left = t:status()
		assert(not string.find(left or "", "zoomed", 1, true), left)
		t:keys("alt-space alt-p f esc")
		left = t:status()
		assert(string.find(left or "", "main-stack · zoomed", 1, true), left)
	end
)

test("the pane mode's hint fits the screen and says how to see every key", function(t)
	t:buffer("|hello")
	for _, width in { 160, 100, 60 } do
		t:draw(width, 20)
		t:keys("alt-p")
		local said = t:messages()
		local hint = said[#said]
		assert(#hint <= math.max(width - 30, 40), `{width}: {hint}`)
		assert(string.find(hint, "f1 all keys  esc done", 1, true), hint)
		t:keys("esc")
	end
end)

test("the tab mode's keys that open something all leave it", function(t)
	t:buffer("|hello")
	t:keys("alt-t n")
	assert(greed.mode.get() == "helix")
	t:keys("alt-t r")
	t:keys("w o r k enter")
	assert(greed.tab.current().name == "work", tostring(greed.tab.current().name))
	assert(greed.mode.get() == "helix", greed.mode.get())
end)

test("alt-W says it waits for a float's number", function(t)
	cat()
	t:buffer("|hello")
	t:keys("alt-f")
	t:keys("ctrl-\\ alt-W")
	local said = t:messages()
	assert(string.find(said[#said], "pick a floating view: 1", 1, true), said[#said])
	t:keys("esc")
end)

test("alt-= and alt-- give the pane more room or less", function(t)
	local left = two(t)
	local width = function(view: greed.View): number
		local _, cols = view:size()
		return cols or 0
	end
	local before = width(left)
	t:keys("alt-h alt-=")
	t:draw(80, 20)
	assert(width(left) > before, `{width(left)} > {before}`)
	t:keys("alt-- alt--")
	t:draw(80, 20)
	assert(width(left) < before, `{width(left)} < {before}`)
end)

test("pane f zooms in on a pane, and again shows them all", function(t)
	two(t)
	t:keys("alt-p f esc")
	assert(greed.tab.current().zoomed)
	t:keys("alt-p f esc")
	assert(not greed.tab.current().zoomed)
end)

test("alt-f brings the floating terminal back where it was moved and how big", function(t)
	cat()
	t:buffer("|hello")
	t:keys("alt-f")
	greed.view():configure({ width = 30, height = 8, x = 2, y = 1 })
	t:keys("alt-f alt-f")
	local spec = greed.view():float_spec() :: greed.FloatSpec
	assert(spec.width == 30 and spec.height == 8 and spec.x == 2 and spec.y == 1, "kept its place")
	t:keys("ctrl-d")
	t:wait_for(function()
		return #t:floats() == 0
	end)
end)

test("alt-f shows a floating terminal and hides it, still running", function(t)
	cat()
	t:buffer("|hello")
	t:keys("alt-f")
	assert(#t:floats() == 1)
	assert(greed.mode.get() == "terminal")
	local buffer = greed.view():buffer()
	t:keys("alt-f")
	assert(#t:floats() == 0)
	assert(greed.mode.get() == "helix")
	t:keys("alt-f")
	assert(greed.view():buffer():id() == buffer:id(), "the same terminal")
	t:keys("ctrl-d")
	t:wait_for(function()
		return #t:floats() == 0
	end)
end)

test("keys can be taken away or changed", function(t)
	t:buffer("|hello")
	greed.keymap.unbind({}, { "alt-n" })
	greed.keymap.bind("helix", { ["space |"] = "pane-split-right" })
	t:keys("alt-n")
	assert(count() == 1)
	t:keys("space |")
	assert(count() == 2)
end)

test("clicking a tab in the tab line shows it", function(t)
	t:buffer("|hello")
	t:keys("alt-t n")
	t:draw(40, 10)
	assert(greed.tab.list()[2].current)
	-- " 1 untitled " starts at column 0 of the tab line, the top row.
	t:mouse("press", 2, 0)
	assert(greed.tab.list()[1].current)
end)

test("a tab's layout can be read and set again, arranged another way", function(t)
	t:buffer("|hello")
	local a = greed.view()
	local opened: { number } = {}
	greed.on("pane.opened", function(event: greed.PaneOpened)
		table.insert(opened, event.view:id())
	end)
	local b = a:split("right")
	local c = b:split("right")
	assert(#opened == 2 and opened[2] == c:id(), "splitting says so")

	local layout = greed.tab.layout()
	assert(layout.split == "row" and #layout.children == 3, "three side by side")

	-- a on top, b and c side by side below it, taking three quarters.
	-- A pane and a split: `any`, as `set_layout` takes.
	local children: { any } = { a, { split = "row", children = { b, c } } }
	greed.tab.set_layout({ split = "column", sizes = { 1, 3 }, children = children })
	local rows = t:draw(41, 21)
	local divider = 0
	for i, row in rows do
		if string.find(row, "─", 1, true) then
			divider = i
			break
		end
	end
	assert(divider == 5, `the line under a is a quarter down: row {divider}`)
	local read = greed.tab.layout()
	assert(read.split == "column" and read.children[2].split == "row")
	assert(math.abs(read.sizes[1] - 0.25) < 0.01, tostring(read.sizes[1]))

	-- Every pane, each once.
	local ok: boolean, err: unknown =
		pcall(greed.tab.set_layout, { split = "row", children = { a, b } })
	assert(not ok and string.find(tostring(err), "every pane", 1, true), tostring(err))
	ok = pcall(greed.tab.set_layout, { split = "row", children = { a, a, b, c } })
	assert(not ok, "a pane twice")
end)

-- The shown tab's layout as nested lists of pane ids, "row(…)" and "column(…)".
local function shape(): string
	local function show(node: any): string
		if type(node) ~= "table" then
			return tostring(node:id())
		end
		local parts = {}
		for _, child in node.children do
			table.insert(parts, show(child))
		end
		return `{node.split}({table.concat(parts, " ")})`
	end
	return show(greed.tab.layout())
end

local function ids(...: greed.View): { number }
	local list = {}
	for _, view in { ... } do
		table.insert(list, view:id())
	end
	return list
end

test("main-stack puts a new pane in main and stacks the rest beside it", function(t)
	t:buffer("|hello")
	local a = greed.view()
	panes.layouts.use("main-stack")
	local b = a:split("right")
	local c = b:split("down")
	local id = ids(a, b, c)
	assert(shape() == `row({id[3]} column({id[2]} {id[1]}))`, shape())
	local layout = greed.tab.layout()
	assert(math.abs(layout.sizes[1] - 0.6) < 0.01, "main takes 60%")

	panes.layouts.swap_main(a)
	assert(shape() == `row({id[1]} column({id[2]} {id[3]}))`, `a into main: {shape()}`)
	panes.layouts.grow_main(0.1)
	assert(math.abs(greed.tab.layout().sizes[1] - 0.7) < 0.01)
	panes.layouts.rotate()
	assert(shape() == `row({id[3]} column({id[1]} {id[2]}))`, `rotated: {shape()}`)

	c:close()
	assert(shape() == `row({id[1]} {id[2]})`, `closing rearranges: {shape()}`)
end)

test("columns and spiral arrange panes in their order", function(t)
	t:buffer("|hello")
	local a = greed.view()
	panes.layouts.use("columns")
	local b = a:split("down")
	local c = b:split("down")
	local id = ids(a, b, c)
	assert(shape() == `row({id[1]} {id[2]} {id[3]})`, `new after the one it came from: {shape()}`)
	panes.layouts.use("spiral")
	assert(shape() == `row({id[1]} column({id[2]} {id[3]}))`, shape())
	panes.layouts.next()
	assert(panes.layouts.current() == "manual", "spiral wraps round to manual")
end)

test("resizing by hand switches to manual and keeps the shape", function(t)
	t:buffer("|hello")
	local a = greed.view()
	panes.layouts.use("columns")
	a:split("right")
	t:draw(80, 20)
	local before = shape()
	t:keys("alt-=")
	assert(panes.layouts.current() == "manual", panes.layouts.current())
	assert(shape() == before, "the same panes, the same way")
	local messages = t:messages()
	assert(string.find(messages[#messages], "manual", 1, true), messages[#messages])
end)

test("your own layouts arrange panes too, and new tabs take the default", function(t)
	panes.layouts.define("rows", function(list)
		return if #list == 1 then list[1] else { split = "column", children = list }
	end)
	greed.option.set("pane-layout", "rows")
	t:buffer("|hello")
	greed.tab.new()
	local a = greed.view()
	assert(panes.layouts.current() == "rows", panes.layouts.current())
	local b = a:split("right")
	local id = ids(a, b)
	assert(shape() == `column({id[1]} {id[2]})`, shape())
	greed.option.set("pane-layout", "manual")
end)

test("alt-space goes to the next layout and the pane mode has the layout keys", function(t)
	t:buffer("|hello")
	local start = panes.layouts.current()
	t:keys("alt-space")
	assert(panes.layouts.current() ~= start, "a different layout")
	t:keys("alt-p y")
	assert(string.find(table.concat(t:floats(), "\n"), "main-stack", 1, true), "the layout picker")
	t:keys("esc")
end)

test("a frame shows where a new pane would go, and moves before it opens", function(t)
	t:buffer("|hello")
	local a = greed.view()
	local b = a:split("right")
	t:draw(80, 20)
	t:keys("alt-p p")
	assert(greed.mode.get() == "pane-place", greed.mode.get())
	local frame = false
	for _, line in t:floats() do
		frame = frame or string.find(line, "new pane", 1, true) ~= nil
	end
	assert(frame, "the frame is up")
	-- It starts on the right half of b; left goes to b's left half.
	t:keys("h enter")
	local id = ids(a, b)
	local new = greed.view()
	assert(shape() == `row({id[1]} {new:id()} {id[2]})`, `between a and b: {shape()}`)
	assert(greed.mode.get() ~= "pane-place", "done placing")
end)

test("the frame goes along a whole edge of the tab, and esc puts things back", function(t)
	t:buffer("|hello")
	local a = greed.view()
	local b = a:split("right")
	t:draw(80, 20)
	t:keys("alt-p p esc")
	assert(#greed.tab.current().panes == 2, "nothing opened")
	assert(greed.view():id() == b:id(), "back where it was")
	-- Up from b's right half: b's top half, then the top of the whole tab.
	t:keys("alt-p p k k enter")
	local id = ids(a, b)
	local new = greed.view()
	assert(shape() == `column({new:id()} row({id[1]} {id[2]}))`, `across the top: {shape()}`)
end)

test("a tab saved as a layout opens again with the same files and terminals", function(t)
	cat()
	local core = require("@core")
	local dir = t:tempdir({ [".git/HEAD"] = "", ["a.txt"] = "first", ["b.txt"] = "second" })
	core.project.open(dir)
	greed.open(`{dir}/a.txt`)
	local a = greed.view()
	a:split("right", greed.load(`{dir}/b.txt`))
	panes.terminal_pane("down")
	t:keys("ctrl-\\")
	local before = shape()

	t:run("layout-save", { "dev" })
	local saved = greed.fs.read(`{dir}/.greed/layouts/dev.json`)
	assert(saved and string.find(saved, '"b.txt"', 1, true), saved)
	assert(table.find(panes.saved.names(), "dev"), "listed")

	local tabs = #greed.tab.list()
	t:run("layout-open", { "dev" })
	assert(#greed.tab.list() == tabs + 1, "a tab of its own")
	local opened = greed.tab.current().panes
	assert(#opened == 3, tostring(#opened))
	local kinds = {}
	for _, pane in opened do
		local buffer = pane:buffer()
		table.insert(
			kinds,
			buffer:path() and string.match(buffer:path() :: string, "[^/]+$") or buffer:kind()
		)
	end
	table.sort(kinds)
	assert(table.concat(kinds, ",") == "a.txt,b.txt,terminal", table.concat(kinds, ","))
	-- The same shape, with these panes.
	local function outline(s: string): string
		return (string.gsub(s, "%d+", "_"))
	end
	assert(outline(shape()) == outline(before), `{shape()} vs {before}`)
	assert(panes.layouts.current() == "manual", "arranged as saved")
end)

test("layouts can be saved for any project, and a missing one says so", function(t)
	t:buffer("|hello")
	t:run("layout-save-mine", { "solo" })
	local config = greed.fs.dirs().config
	assert(config and greed.fs.read(`{config}/layouts/solo.json`), "in your config")
	t:run("layout-open", { "nothing-here" })
	local messages = t:messages()
	assert(string.find(messages[#messages], "no layout called", 1, true), messages[#messages])
end)

test("a picker under a floating terminal takes typing again once the terminal hides", function(t)
	cat()
	t:buffer("|hello")
	local picker = require("@picker")
	local chosen = nil
	picker.pick(
		"Things",
		{ { label = "one", value = 1 }, { label = "two", value = 2 } },
		function(item)
			chosen = item.value
		end
	)
	t:keys("alt-f")
	assert(greed.mode.get() == "terminal")
	t:keys("alt-f")
	assert(greed.view():buffer():kind() == "picker", "back on the picker")
	assert(greed.mode.get() == "helix-insert", "typing into it: " .. greed.mode.get())
	t:keys("t w enter")
	assert(chosen == 2, "it still picks")

	-- Even left in normal mode, esc closes it.
	picker.pick("Things", { { label = "one", value = 1 } }, function() end)
	greed.mode.set("helix")
	t:keys("esc")
	assert(#t:floats() == 0, "closed")
	t:keys("alt-f ctrl-d")
end)

test("g in pane mode labels the panes, and a label goes to its pane to act on it", function(t)
	t:buffer("|hello")
	t:keys("alt-p v v esc")
	local panes = greed.tab.current().panes
	assert(#panes == 3, `{#panes} panes`)
	t:draw(90, 20)
	t:keys("alt-p g")
	assert(#t:floats() == 3, "a label over each pane")
	assert(string.find(t:floats()[1], "1", 1, true), t:floats()[1])
	t:keys("1")
	assert(#t:floats() == 0, "the labels go")
	assert(greed.view():id() == panes[1]:id(), "the first pane")
	assert(greed.mode.get() == "pane", "still in pane mode, to act on it")
	t:keys("f")
	assert(greed.tab.current().zoomed, "f zoomed the picked pane")
	t:keys("f esc")

	-- Any key that isn't a label leaves things as they were.
	t:keys("alt-p g q")
	assert(#t:floats() == 0 and greed.view():id() == panes[1]:id())
	t:keys("esc")
end)

test("the resize mode grows and shrinks a floating view and moves it", function(t)
	t:buffer("|hello")
	local view =
		greed.float(greed.create_buffer("scratch", "x"), { x = 10, y = 4, width = 30, height = 8 })
	t:draw(80, 24)
	local function area(): { x: number, y: number, width: number, height: number }
		t:draw(80, 24)
		return view:area() :: any
	end
	local before = area()
	t:keys("alt-r")
	assert(greed.mode.get() == "resize")
	t:keys("l")
	assert(area().width == before.width + 4, "l grows it right")
	t:keys("L")
	assert(area().width == before.width, "L shrinks it from the right")
	t:keys("j")
	assert(area().height == before.height + 2, "j grows it down")
	t:keys("right")
	local moved = area()
	assert(moved.x == before.x + 4 and moved.width == before.width, "right moves it")
	t:keys("esc")
	assert(greed.mode.get() == "helix")
	view:close()
end)

test("the resize mode resizes panes too", function(t)
	t:buffer("|hello")
	t:keys("alt-p v esc")
	t:draw(80, 20)
	local pane = greed.view()
	local _, before = pane:size()
	t:keys("alt-r h esc")
	t:draw(80, 20)
	local _, after = pane:size()
	assert((after :: number) > (before :: number), `{after} > {before}`)
end)

test("a tab's floats show only with that tab and close with it", function(t)
	t:buffer("|hello")
	local float = greed.float(greed.create_buffer("scratch", "mine"), { tab = true })
	local first = greed.tab.current().id
	assert(#greed.floats() == 1)
	greed.tab.new()
	assert(#greed.floats() == 0, "another tab doesn't show it")
	local menu = greed.float(greed.create_buffer("scratch", "menu"), { focus = false })
	greed.tab.switch(first)
	assert(#greed.floats() == 2, "its own and the one over every tab")
	menu:close()
	local second = greed.tab.list()[2].id
	greed.tab.switch(second)
	greed.tab.close(first)
	local ok = pcall(function()
		float:configure({ width = 10 })
	end)
	assert(not ok, "closed with its tab")
end)

test(
	"pane mode z hides a tab's floats and shows them again; F flips a pane to float and back",
	function(t)
		t:buffer("|hello")
		local floats = require("@panes").floats
		greed.float(greed.create_buffer("scratch", "one\ntwo"), { tab = true })
		t:keys("alt-p z esc")
		assert(#floats.list() == 0, "hidden")
		t:keys("alt-p z esc")
		assert(#floats.list() == 1, "shown again")
		assert(greed.view():buffer():text() == "one\ntwo", "with its buffer")
		t:keys("alt-p F esc")
		assert(#floats.list() == 0 and #greed.tab.current().panes == 2, "the float became a pane")
		t:keys("alt-p F esc")
		assert(#floats.list() == 1 and #greed.tab.current().panes == 1, "and floats again")
		t:keys("esc")
	end
)

test("pane mode T tiles a tab's floats side by side, W opens another floating terminal", function(t)
	t:buffer("|hello")
	local floats = require("@panes").floats
	greed.float(greed.create_buffer("scratch", "a"), { tab = true })
	greed.float(greed.create_buffer("scratch", "b"), { tab = true })
	t:draw(80, 24)
	t:keys("alt-p T esc")
	t:draw(80, 24)
	local a, b = floats.list()[1]:area(), floats.list()[2]:area()
	assert(a and b and a.y == b.y and a.x < b.x, "side by side")
	t:keys("alt-p W esc")
	assert(#floats.list() == 3, "a third float, a terminal")
end)

test("ctrl-w L swaps the pane with the one on its right, ctrl-w n v opens an empty one", function(t)
	t:buffer("|left")
	local left = greed.view():buffer()
	local right = greed.create_buffer("file", "right")
	greed.view():split("right", right)
	greed.tab.current().panes[1]:focus()
	t:draw(80, 20)
	t:keys("ctrl-w L")
	local panes = greed.tab.current().panes
	assert(panes[1]:buffer():id() == right:id() and panes[2]:buffer():id() == left:id(), "swapped")
	assert(greed.view():id() == panes[2]:id(), "following it")
	t:keys("ctrl-w n v")
	assert(
		#greed.tab.current().panes == 3 and greed.view():buffer():text() == "",
		"a new empty pane"
	)
end)

test("alt-f hides every float in the tab and shows them all again", function(t)
	t:buffer("|hello")
	local floats = require("@panes").floats
	greed.float(greed.create_buffer("scratch", "a"), { tab = true })
	greed.float(greed.create_buffer("scratch", "b"), { tab = true })
	t:keys("alt-f")
	assert(#floats.list() == 0, "both hidden")
	t:keys("alt-f")
	assert(#floats.list() == 2, "both shown again")
end)

test("alt-n opens a floating terminal while floats are shown; alt-F floats this file", function(t)
	cat()
	t:buffer("|hello")
	local floats = require("@panes").floats
	t:keys("alt-F")
	assert(#floats.list() == 1 and greed.view():buffer():text() == "hello", "the file, floating")
	t:keys("esc alt-n")
	assert(#floats.list() == 2 and #greed.tab.current().panes == 1, "another float, no new pane")
	t:keys("ctrl-d")
	t:wait_for(function()
		return #floats.list() == 1
	end)
end)

test("ctrl-w q in a panel closes the panel", function(t)
	t:buffer("|hello")
	local main = greed.view()
	greed.panel(greed.create_buffer("notes", "a panel"), { side = "right" }):focus()
	t:keys("ctrl-w q")
	assert(greed.view():id() == main:id(), "back in the file")
	assert(count() == 1, "the pane stays")
end)

type Area = { x: number, y: number, width: number, height: number }

test("alt-h and alt-l move between the panes and the panels beside them", function(t)
	t:buffer("|hello")
	local main = greed.view()
	local tree = greed.panel(
		greed.create_buffer("notes", "a panel"),
		{ side = "left", width = 10, focus = false }
	)
	t:draw(80, 20)
	t:keys("alt-h")
	assert(greed.view():id() == tree:id(), "alt-h went into the panel")
	t:keys("alt-l")
	assert(greed.view():id() == main:id(), "alt-l came back")
	tree:close()
end)

test("the resize mode resizes a panel", function(t)
	t:buffer("|hello")
	local panel =
		greed.panel(greed.create_buffer("notes", "a panel"), { side = "right", width = 20 })
	t:draw(80, 20)
	local function width(): number
		t:draw(80, 20)
		return (panel:area() :: Area).width
	end
	local before = width()
	t:keys("alt-r h")
	assert(width() == before + 4, "h grows it toward the file")
	t:keys("l")
	assert(width() == before + 8, "l, at the screen's edge, grows it from the other side")
	t:keys("L")
	assert(width() == before + 4, "L, at the screen's edge, shrinks it from the other side")
	t:keys("esc")
	panel:close()
end)

test("dragging the line by a panel or between panes resizes them", function(t)
	t:buffer("|hello")
	local panel = greed.panel(
		greed.create_buffer("notes", "a panel"),
		{ side = "left", width = 10, focus = false }
	)
	t:keys("alt-p v esc")
	t:draw(80, 20)
	local line = (panel:area() :: Area).width
	t:mouse("press", line, 5)
	t:mouse("drag", line + 6, 5)
	t:mouse("release", line + 6, 5)
	t:draw(80, 20)
	assert((panel:area() :: Area).width == 16, "the panel grew")
	local left = greed.tab.current().panes[1]
	local a = left:area() :: Area
	t:mouse("press", a.x + a.width, 5)
	t:mouse("drag", a.x + a.width - 5, 5)
	t:mouse("release", a.x + a.width - 5, 5)
	t:draw(80, 20)
	assert((left:area() :: Area).width == a.width - 5, "the pane shrank")
	panel:close()
end)

test("b in pane mode moves the pane to a new tab, t to a tab you pick", function(t)
	t:buffer("hel|lo")
	local file = greed.view():buffer()
	t:keys("alt-p b")
	assert(#greed.tab.list() == 1, "the only pane stays")
	assert(greed.mode.get() == "helix", "and the mode is left")
	local notes = greed.create_buffer("file", "notes")
	panes.focus(greed.view():split("right", notes))
	t:draw(80, 20)
	t:keys("alt-p b")
	assert(#greed.tab.list() == 2 and greed.tab.list()[2].current, "a new tab, shown")
	assert(greed.view():buffer() == notes and greed.view():is_pane())
	assert(#greed.tab.list()[1].panes == 1, "gone from the first tab")
	assert(greed.mode.get() == "helix")
	-- Back to the first tab, with t and the picker.
	t:keys("alt-p t")
	t:keys("1 enter")
	t:wait(0)
	assert(#greed.tab.list() == 1, "the tab it left had nothing else, so it closed")
	local panes_now = greed.tab.current().panes
	assert(#panes_now == 2 and greed.view():buffer() == notes, `{#panes_now} panes`)
	assert(panes_now[1]:buffer() == file)
end)

test("P in pane mode moves the pane into a panel, keeping its cursor", function(t)
	t:buffer("hel|lo")
	local notes = greed.create_buffer("file", "one\ntwo")
	local pane = greed.view():split("right", notes)
	pane:set_cursor(4)
	panes.focus(pane)
	t:draw(80, 20)
	t:keys("alt-p P")
	local panel = greed.view()
	assert(not panel:is_pane() and panel:float_spec() == nil, "a panel")
	assert(panel:buffer() == notes and panel:cursor() == 4)
	assert(#greed.tab.current().panes == 1)
	t:keys("alt-p P")
	local said = t:messages()
	assert(string.find(said[#said], "a panel already", 1, true), said[#said])
	panel:close()
	t:keys("alt-p P")
	said = t:messages()
	assert(string.find(said[#said], "last pane stays", 1, true), said[#said])
end)

test(
	"e in pane mode floats a panel, and the last pane too, leaving the pane another buffer",
	function(t)
		t:buffer("hel|lo")
		local file = greed.view():buffer()
		local notes = greed.create_buffer("file", "one\ntwo")
		local panel = greed.panel(notes)
		panes.focus(panel)
		t:draw(80, 20)
		t:keys("alt-p e esc")
		local floated = greed.view()
		assert(floated:float_spec() ~= nil and floated:buffer() == notes, "the panel floats")
		assert(not panel:valid(), "and the panel is gone")
		-- The tab's only pane: its buffer floats, and the pane shows another.
		local pane = greed.tab.current().panes[1]
		panes.focus(pane)
		t:keys("alt-p e")
		local second = greed.view()
		assert(
			second:float_spec() ~= nil and second:buffer() == file,
			"the last pane's buffer floats"
		)
		local left = greed.tab.current().panes
		assert(#left == 1 and left[1]:buffer() ~= file, "the pane stays, with another buffer")
	end
)

test("a floating terminal moves to a tab and keeps running", function(t)
	cat()
	t:buffer("|hello")
	t:keys("alt-f")
	local term = greed.view():buffer()
	t:keys("alt-p b")
	assert(#greed.tab.list() == 2)
	assert(greed.view():buffer() == term and greed.view():is_pane())
	assert(require("@terminal").terminal(term) ~= nil, "still a terminal")
	assert(greed.mode.get() == "terminal", greed.mode.get())
	t:keys("ctrl-d")
end)

test("in Vim, a count before g t goes to that tab", function(t)
	t:buffer("|x")
	greed.option.set("editing-style", "vim")
	t:run("tab-new")
	t:run("tab-new")
	t:keys("1 g t")
	assert(greed.tab.list()[1].current, "the first tab")
	t:keys("3 g t")
	assert(greed.tab.list()[3].current, "the third tab")
	t:keys("g t")
	assert(greed.tab.list()[1].current, "round to the first")
	greed.option.set("editing-style", "helix")
end)
