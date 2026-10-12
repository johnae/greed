local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")

local ui = core.ui

-- A buffer of its own in the main view, for a view to be mounted in.
local function shown(t: test.TestContext): greed.Buffer
	t:buffer("|")
	local buffer = greed.create_buffer("test-ui", "", { readonly = true })
	greed.view():show(buffer)
	buffer:set_line_numbers(false)
	return buffer
end

local function text_of(buffer: greed.Buffer): string
	return buffer:slice(0, buffer:len())
end

test("a view draws its state, and again when it's set", function(t)
	local buffer = shown(t)
	local view = ui.mount(buffer, function(state)
		return ui.column({
			ui.line({ ui.span("Count: "), ui.span(tostring(state.n), "markdown.value") }),
			ui.text("Words wrap at the width of the view they're in, at spaces."),
		})
	end, { n = 1 })
	local text = text_of(buffer)
	assert(string.find(text, "Count: 1\nWords wrap", 1, true), text)
	view:set({ n = 2 })
	assert(string.find(text_of(buffer), "Count: 2", 1, true), text_of(buffer))
	assert(ui.of(buffer) == view)
end)

test("enter presses the widget at the cursor, tab goes to the next", function(t)
	local buffer = shown(t)
	local pressed: { string } = {}
	local view: core.UiView
	view = ui.mount(buffer, function(state)
		return ui.column({
			ui.button("One", function()
				table.insert(pressed, "one")
			end),
			ui.line({ ui.span("between") }),
			ui.button("Two", function()
				table.insert(pressed, "two")
			end),
			ui.toggle("Loud", state.loud, function(on: boolean)
				view:set({ loud = on })
			end),
		})
	end, { loud = false })
	t:keys("enter")
	assert(pressed[1] == "one", pressed[1])
	t:keys("tab enter")
	assert(pressed[2] == "two", pressed[2])
	t:keys("tab enter")
	assert(string.find(text_of(buffer), "☑ Loud", 1, true), text_of(buffer))
	t:keys("tab")
	assert(greed.view():cursor() == 0, "round to the first")
	t:keys("shift-tab")
	local line = buffer:line_of(greed.view():cursor())
	assert(line == 3, `back to the last: {line}`)
end)

test("a field asks for its value", function(t)
	local buffer = shown(t)
	local view: core.UiView
	view = ui.mount(buffer, function(state)
		return ui.field("Name", state.name, function(value: string)
			view:set({ name = value })
		end)
	end, { name = "ada" })
	assert(text_of(buffer) == "Name: [ ada ]", text_of(buffer))
	greed.view():set_selection({ ranges = { { anchor = 7, head = 7 } }, primary = 1 })
	t:keys("enter")
	t:keys("backspace backspace backspace b o b enter")
	assert(text_of(buffer) == "Name: [ bob ]", text_of(buffer))
end)

test("drawing again changes only the lines that changed, so the cursor stays", function(t)
	local buffer = shown(t)
	local view = ui.mount(buffer, function(state)
		local lines: { core.UiNode } = {}
		for i = 1, 5 do
			table.insert(
				lines,
				ui.line({ ui.span(if i == state.changed then "new" else `line {i}`) })
			)
		end
		if state.more then
			table.insert(lines, ui.line({ ui.span("added") }))
		end
		return ui.column(lines)
	end, { changed = 0, more = false })
	local at = buffer:line_start(4) + 2
	greed.view():set_selection({ ranges = { { anchor = at, head = at } }, primary = 1 })
	view:set({ changed = 2 })
	assert(text_of(buffer) == "line 1\nnew\nline 3\nline 4\nline 5", text_of(buffer))
	assert(greed.view():cursor() == buffer:line_start(4) + 2, "still on line 5")
	view:set({ more = true })
	assert(string.find(text_of(buffer), "line 5\nadded", 1, true), text_of(buffer))
	view:set({ more = false, changed = 0 })
	assert(text_of(buffer) == "line 1\nline 2\nline 3\nline 4\nline 5", text_of(buffer))
end)

test("a table lines up its columns and opens a row when pressed", function(t)
	local buffer = shown(t)
	local opened: { string } = {}
	ui.mount(buffer, function()
		return ui.table({
			columns = { "name", { name = "total", title = "Total" } },
			rows = { { name = "ann", total = 10 }, { name = "bob", total = 200 } },
			on_open = function(row)
				table.insert(opened, row.name)
			end,
		})
	end)
	local text = text_of(buffer)
	assert(string.find(text, "│ name │ Total │", 1, true), text)
	assert(string.find(text, "│ ann  │    10 │\n│ bob  │   200 │", 1, true), text)
	local bob = buffer:line_start(4) + #"│ "
	greed.view():set_selection({ ranges = { { anchor = bob, head = bob } }, primary = 1 })
	t:keys("enter")
	assert(opened[1] == "bob", opened[1])
end)

test("a table narrower than its columns gives up room from the widest", function()
	local node = ui.table({
		columns = { "a", "b" },
		rows = { { a = string.rep("x", 30), b = "short" } },
	})
	local text = ui.draw(node, 20)
	for _, line in string.split(text, "\n") do
		assert(core.text.width(line) <= 20, line)
	end
end)

test("a grid lines its cells up, its rows' values found under the cursor", function(t)
	local buffer = shown(t)
	local view = ui.mount(buffer, function(state)
		local rows: { core.UiGridRow } = {}
		for _, item in state.items do
			table.insert(rows, {
				value = item,
				line = if item.marked then "ui.selection" else nil,
				cells = {
					{ ui.span(item.name, "keyword") },
					{
						{
							text = item.status,
							tag = if item.status == "working" then "spin" else nil,
						},
					},
					{ ui.span(item.note or "") },
				},
			})
		end
		return ui.grid(rows)
	end, {
		items = {
			{ key = "a", name = "Claude", status = "working", note = "in greed-b" },
			{ key = "b", name = "Greed 2", status = "idle", marked = true },
		} :: { any },
	})
	local text = text_of(buffer)
	assert(text == "Claude   working  in greed-b\nGreed 2  idle", text)
	local second = buffer:line_start(1) + 3
	assert(view:value_at(second).key == "b" and view:value_at(0).key == "a")
	assert(#view:values() == 2 and view:values()[2].key == "b")
	local spots = view:spots("spin")
	assert(#spots == 1 and buffer:slice(spots[1].from, spots[1].to) == "working")
	local lined = false
	for _, mark in buffer:decorations("ui") do
		lined = lined
			or (
				mark.line == true
				and mark.style == "ui.selection"
				and mark.from == buffer:line_start(1)
			)
	end
	assert(lined, "the marked row's line is styled")
end)

test("with a key, each cursor stays on its item as the lines change places", function(t)
	local buffer = shown(t)
	local view = ui.mount(buffer, function(state)
		return ui.list(state.items, function(item: { key: string })
			return { ui.span(item.key) }
		end)
	end, { items = { { key = "one" }, { key = "two" }, { key = "three" } } }, {
		key = function(item: { key: string }): string
			return item.key
		end,
	})
	local two = buffer:line_start(1) + 1
	greed.view():set_selection({ ranges = { { anchor = two, head = two } }, primary = 1 })
	view:set({ items = { { key = "three" }, { key = "one" }, { key = "two" } } })
	assert(text_of(buffer) == "three\none\ntwo", text_of(buffer))
	assert(greed.view():cursor() == buffer:line_start(2) + 1, "still on two, a letter in")
end)
