local test = require("@kern/test")
local kern = require("@kern")
local panes = require("@panes")

-- New terminals run cat, which ends on ctrl-d whatever your shell is.
local function cat()
	kern.option.set("terminal-shell", "cat")
end

local function count(): number
	return #kern.tab.current().panes
end

-- Two panes of the same text side by side, the right one focused.
local function two(t: test.TestContext): (kern.View, kern.View)
	t:buffer("|hello")
	local left = kern.view()
	t:keys("ctrl-w v")
	local right = kern.view()
	t:draw(80, 20)
	return left, right
end

test("ctrl-w v splits, and alt-h and alt-l move between panes", function(t)
	local left, right = two(t)
	assert(count() == 2)
	assert(left:id() ~= right:id())
	t:keys("alt-h")
	assert(kern.view():id() == left:id())
	t:keys("alt-l")
	assert(kern.view():id() == right:id())
	-- Nothing to the right, and only one tab: it stays.
	t:keys("alt-l")
	assert(kern.view():id() == right:id())
end)

test("ctrl-w s splits below, and ctrl-w q closes", function(t)
	t:buffer("|hello")
	local top = kern.view()
	t:keys("ctrl-w s")
	t:draw(80, 20)
	t:keys("alt-k")
	assert(kern.view():id() == top:id())
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
	assert(kern.view():buffer():kind() == "terminal")
	assert(kern.mode.get() == "terminal")
	t:draw(80, 20)
	-- The everywhere keys work while typing into a terminal.
	t:keys("alt-h")
	assert(kern.mode.get() == "normal")
	assert(kern.view():buffer():kind() == "file")
	t:keys("alt-l")
	assert(kern.mode.get() == "terminal")
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
	assert(kern.view():buffer():kind() == "file")
	assert(kern.mode.get() == "normal")
end)

test("the pane mode takes single keys until esc", function(t)
	t:buffer("|hello")
	t:keys("alt-p")
	assert(kern.mode.get() == "pane")
	local said = table.concat(t:messages(), "\n")
	assert(string.find(said, "h left", 1, true), said)
	t:keys("v")
	assert(count() == 2)
	assert(kern.mode.get() == "pane", "it stays in the mode")
	t:draw(80, 20)
	t:keys("h esc")
	assert(kern.mode.get() == "normal")
	assert(kern.view():id() == kern.tab.current().panes[1]:id())
	-- A key the mode doesn't have leaves it.
	t:keys("alt-p q")
	assert(kern.mode.get() == "normal")
end)

test("the tab mode opens, switches and closes tabs", function(t)
	t:buffer("|hello")
	t:keys("alt-t n")
	assert(#kern.tab.list() == 2)
	assert(kern.mode.get() == "normal", "opening a tab leaves the mode")
	t:keys("alt-[")
	assert(kern.tab.list()[1].current)
	t:keys("alt-2")
	assert(kern.tab.list()[2].current)
	t:keys("alt-t h")
	assert(kern.tab.list()[1].current)
	t:keys("esc alt-t x")
	assert(#kern.tab.list() == 1)
end)

test("at the left or right edge, moving goes on to the next tab", function(t)
	t:buffer("|hello")
	t:keys("alt-t n")
	t:draw(80, 20)
	t:keys("alt-l")
	assert(kern.tab.list()[1].current, "round the end to the first")
	t:keys("alt-h")
	assert(kern.tab.list()[2].current)
end)

test("alt-= and alt-- give the pane more room or less", function(t)
	local left = two(t)
	local width = function(view: kern.View): number
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
	assert(kern.tab.current().zoomed)
	t:keys("alt-p f esc")
	assert(not kern.tab.current().zoomed)
end)

test("alt-f brings the floating terminal back where it was moved and how big", function(t)
	cat()
	t:buffer("|hello")
	t:keys("alt-f")
	kern.view():configure({ width = 30, height = 8, x = 2, y = 1 })
	t:keys("alt-f alt-f")
	local spec = kern.view():float_spec() :: kern.FloatSpec
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
	assert(kern.mode.get() == "terminal")
	local buffer = kern.view():buffer()
	t:keys("alt-f")
	assert(#t:floats() == 0)
	assert(kern.mode.get() == "normal")
	t:keys("alt-f")
	assert(kern.view():buffer():id() == buffer:id(), "the same terminal")
	t:keys("ctrl-d")
	t:wait_for(function()
		return #t:floats() == 0
	end)
end)

test("keys can be taken away or changed", function(t)
	t:buffer("|hello")
	kern.keymap.unbind({}, { "alt-n" })
	kern.keymap.bind("normal", { ["space |"] = "pane-split-right" })
	t:keys("alt-n")
	assert(count() == 1)
	t:keys("space |")
	assert(count() == 2)
end)

test("clicking a tab in the tab line shows it", function(t)
	t:buffer("|hello")
	t:keys("alt-t n")
	t:draw(40, 10)
	assert(kern.tab.list()[2].current)
	-- " 1 untitled " starts at column 0 of the tab line, the top row.
	t:mouse("press", 2, 0)
	assert(kern.tab.list()[1].current)
end)

test("a tab's layout can be read and set again, arranged another way", function(t)
	t:buffer("|hello")
	local a = kern.view()
	local opened: { number } = {}
	kern.on("pane.opened", function(event: kern.PaneOpened)
		table.insert(opened, event.view:id())
	end)
	local b = a:split("right")
	local c = b:split("right")
	assert(#opened == 2 and opened[2] == c:id(), "splitting says so")

	local layout = kern.tab.layout()
	assert(layout.split == "row" and #layout.children == 3, "three side by side")

	-- a on top, b and c side by side below it, taking three quarters.
	kern.tab.set_layout({
		split = "column",
		sizes = { 1, 3 },
		children = { a, { split = "row", children = { b, c } } },
	})
	local rows = t:draw(41, 21)
	local divider = 0
	for i, row in rows do
		if string.find(row, "─", 1, true) then
			divider = i
			break
		end
	end
	assert(divider == 5, `the line under a is a quarter down: row {divider}`)
	local read = kern.tab.layout()
	assert(read.split == "column" and read.children[2].split == "row")
	assert(math.abs(read.sizes[1] - 0.25) < 0.01, tostring(read.sizes[1]))

	-- Every pane, each once.
	local ok, err = pcall(kern.tab.set_layout, { split = "row", children = { a, b } })
	assert(not ok and string.find(tostring(err), "every pane", 1, true), tostring(err))
	ok = pcall(kern.tab.set_layout, { split = "row", children = { a, a, b, c } })
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
	return show(kern.tab.layout())
end

local function ids(...: kern.View): { number }
	local list = {}
	for _, view in { ... } do
		table.insert(list, view:id())
	end
	return list
end

test("main-stack puts a new pane in main and stacks the rest beside it", function(t)
	t:buffer("|hello")
	local a = kern.view()
	panes.layouts.use("main-stack")
	local b = a:split("right")
	local c = b:split("down")
	local id = ids(a, b, c)
	assert(shape() == `row({id[3]} column({id[2]} {id[1]}))`, shape())
	local layout = kern.tab.layout()
	assert(math.abs(layout.sizes[1] - 0.6) < 0.01, "main takes 60%")

	panes.layouts.swap_main(a)
	assert(shape() == `row({id[1]} column({id[2]} {id[3]}))`, `a into main: {shape()}`)
	panes.layouts.grow_main(0.1)
	assert(math.abs(kern.tab.layout().sizes[1] - 0.7) < 0.01)
	panes.layouts.rotate()
	assert(shape() == `row({id[3]} column({id[1]} {id[2]}))`, `rotated: {shape()}`)

	c:close()
	assert(shape() == `row({id[1]} {id[2]})`, `closing rearranges: {shape()}`)
end)

test("columns and spiral arrange panes in their order", function(t)
	t:buffer("|hello")
	local a = kern.view()
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
	local a = kern.view()
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
	kern.option.set("pane-layout", "rows")
	t:buffer("|hello")
	kern.tab.new()
	local a = kern.view()
	assert(panes.layouts.current() == "rows", panes.layouts.current())
	local b = a:split("right")
	local id = ids(a, b)
	assert(shape() == `column({id[1]} {id[2]})`, shape())
	kern.option.set("pane-layout", "manual")
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
	local a = kern.view()
	local b = a:split("right")
	t:draw(80, 20)
	t:keys("alt-p p")
	assert(kern.mode.get() == "pane-place", kern.mode.get())
	local frame = false
	for _, line in t:floats() do
		frame = frame or string.find(line, "new pane", 1, true) ~= nil
	end
	assert(frame, "the frame is up")
	-- It starts on the right half of b; left goes to b's left half.
	t:keys("h enter")
	local id = ids(a, b)
	local new = kern.view()
	assert(shape() == `row({id[1]} {new:id()} {id[2]})`, `between a and b: {shape()}`)
	assert(kern.mode.get() ~= "pane-place", "done placing")
end)

test("the frame goes along a whole edge of the tab, and esc puts things back", function(t)
	t:buffer("|hello")
	local a = kern.view()
	local b = a:split("right")
	t:draw(80, 20)
	t:keys("alt-p p esc")
	assert(#kern.tab.current().panes == 2, "nothing opened")
	assert(kern.view():id() == b:id(), "back where it was")
	-- Up from b's right half: b's top half, then the top of the whole tab.
	t:keys("alt-p p k k enter")
	local id = ids(a, b)
	local new = kern.view()
	assert(shape() == `column({new:id()} row({id[1]} {id[2]}))`, `across the top: {shape()}`)
end)

test("a tab saved as a layout opens again with the same files and terminals", function(t)
	cat()
	local core = require("@core")
	local dir = t:tempdir({ [".git/HEAD"] = "", ["a.txt"] = "first", ["b.txt"] = "second" })
	core.project.open(dir)
	kern.open(`{dir}/a.txt`)
	local a = kern.view()
	a:split("right", kern.load(`{dir}/b.txt`))
	panes.terminal_pane("down")
	t:keys("ctrl-\\")
	local before = shape()

	t:run("layout-save", { "dev" })
	local saved = kern.fs.read(`{dir}/.kern/layouts/dev.json`)
	assert(saved and string.find(saved, '"b.txt"', 1, true), saved)
	assert(table.find(panes.saved.names(), "dev"), "listed")

	local tabs = #kern.tab.list()
	t:run("layout-open", { "dev" })
	assert(#kern.tab.list() == tabs + 1, "a tab of its own")
	local opened = kern.tab.current().panes
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
	local config = kern.fs.dirs().config
	assert(config and kern.fs.read(`{config}/layouts/solo.json`), "in your config")
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
	assert(kern.mode.get() == "terminal")
	t:keys("alt-f")
	assert(kern.view():buffer():kind() == "picker", "back on the picker")
	assert(kern.mode.get() == "insert", "typing into it: " .. kern.mode.get())
	t:keys("t w enter")
	assert(chosen == 2, "it still picks")

	-- Even left in normal mode, esc closes it.
	picker.pick("Things", { { label = "one", value = 1 } }, function() end)
	kern.mode.set("normal")
	t:keys("esc")
	assert(#t:floats() == 0, "closed")
	t:keys("alt-f ctrl-d")
end)

test("g in pane mode labels the panes, and a label goes to its pane to act on it", function(t)
	t:buffer("|hello")
	t:keys("alt-p v v esc")
	local panes = kern.tab.current().panes
	assert(#panes == 3, `{#panes} panes`)
	t:draw(90, 20)
	t:keys("alt-p g")
	assert(#t:floats() == 3, "a label over each pane")
	assert(string.find(t:floats()[1], "1", 1, true), t:floats()[1])
	t:keys("1")
	assert(#t:floats() == 0, "the labels go")
	assert(kern.view():id() == panes[1]:id(), "the first pane")
	assert(kern.mode.get() == "pane", "still in pane mode, to act on it")
	t:keys("f")
	assert(kern.tab.current().zoomed, "f zoomed the picked pane")
	t:keys("f esc")

	-- Any key that isn't a label leaves things as they were.
	t:keys("alt-p g q")
	assert(#t:floats() == 0 and kern.view():id() == panes[1]:id())
	t:keys("esc")
end)

test("the resize mode grows and shrinks a floating view and moves it", function(t)
	t:buffer("|hello")
	local view =
		kern.float(kern.create_buffer("scratch", "x"), { x = 10, y = 4, width = 30, height = 8 })
	t:draw(80, 24)
	local function area(): { x: number, y: number, width: number, height: number }
		t:draw(80, 24)
		return view:area() :: any
	end
	local before = area()
	t:keys("alt-r")
	assert(kern.mode.get() == "resize")
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
	assert(kern.mode.get() == "normal")
	view:close()
end)

test("the resize mode resizes panes too", function(t)
	t:buffer("|hello")
	t:keys("alt-p v esc")
	t:draw(80, 20)
	local pane = kern.view()
	local _, before = pane:size()
	t:keys("alt-r h esc")
	t:draw(80, 20)
	local _, after = pane:size()
	assert((after :: number) > (before :: number), `{after} > {before}`)
end)

test("a tab's floats show only with that tab and close with it", function(t)
	t:buffer("|hello")
	local float = kern.float(kern.create_buffer("scratch", "mine"), { tab = true })
	local first = kern.tab.current().id
	assert(#kern.floats() == 1)
	kern.tab.new()
	assert(#kern.floats() == 0, "another tab doesn't show it")
	local menu = kern.float(kern.create_buffer("scratch", "menu"), { focus = false })
	kern.tab.switch(first)
	assert(#kern.floats() == 2, "its own and the one over every tab")
	menu:close()
	local second = kern.tab.list()[2].id
	kern.tab.switch(second)
	kern.tab.close(first)
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
		kern.float(kern.create_buffer("scratch", "one\ntwo"), { tab = true })
		t:keys("alt-p z esc")
		assert(#floats.list() == 0, "hidden")
		t:keys("alt-p z esc")
		assert(#floats.list() == 1, "shown again")
		assert(kern.view():buffer():text() == "one\ntwo", "with its buffer")
		t:keys("alt-p F esc")
		assert(#floats.list() == 0 and #kern.tab.current().panes == 2, "the float became a pane")
		t:keys("alt-p F esc")
		assert(#floats.list() == 1 and #kern.tab.current().panes == 1, "and floats again")
		t:keys("esc")
	end
)

test("pane mode T tiles a tab's floats side by side, W opens another floating terminal", function(t)
	t:buffer("|hello")
	local floats = require("@panes").floats
	kern.float(kern.create_buffer("scratch", "a"), { tab = true })
	kern.float(kern.create_buffer("scratch", "b"), { tab = true })
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
	local left = kern.view():buffer()
	local right = kern.create_buffer("file", "right")
	kern.view():split("right", right)
	kern.tab.current().panes[1]:focus()
	t:draw(80, 20)
	t:keys("ctrl-w L")
	local panes = kern.tab.current().panes
	assert(panes[1]:buffer():id() == right:id() and panes[2]:buffer():id() == left:id(), "swapped")
	assert(kern.view():id() == panes[2]:id(), "following it")
	t:keys("ctrl-w n v")
	assert(#kern.tab.current().panes == 3 and kern.view():buffer():text() == "", "a new empty pane")
end)

test("alt-f hides every float in the tab and shows them all again", function(t)
	t:buffer("|hello")
	local floats = require("@panes").floats
	kern.float(kern.create_buffer("scratch", "a"), { tab = true })
	kern.float(kern.create_buffer("scratch", "b"), { tab = true })
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
	assert(#floats.list() == 1 and kern.view():buffer():text() == "hello", "the file, floating")
	t:keys("esc alt-n")
	assert(#floats.list() == 2 and #kern.tab.current().panes == 1, "another float, no new pane")
	t:keys("ctrl-d")
	t:wait_for(function()
		return #floats.list() == 1
	end)
end)
