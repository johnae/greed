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

test("a keyed part is laid out again only when its version changes", function(t)
	local buffer = shown(t)
	local built: { [string]: number } = {}
	local function message(key: string, version: number, text: string): core.UiNode
		return ui.keyed(key, version, function()
			built[key] = (built[key] or 0) + 1
			return ui.line({ ui.span(text, "markdown.value") })
		end)
	end
	local view = ui.mount(buffer, function(state)
		local parts: { core.UiNode } = { ui.line({ ui.span(`{#state.said} said`) }) }
		for i, said in state.said do
			table.insert(parts, message(`m{i}`, #said, said))
		end
		return ui.column(parts)
	end, { said = { "hello", "how" } })
	assert(text_of(buffer) == "2 said\nhello\nhow", text_of(buffer))
	view:set({ said = { "hello", "how are" } })
	view:set({ said = { "hello", "how are you" } })
	assert(text_of(buffer) == "2 said\nhello\nhow are you", text_of(buffer))
	assert(built.m1 == 1 and built.m2 == 3, `{built.m1} {built.m2}`)
	-- The first message's style is still on it.
	local styled = false
	for _, mark in buffer:decorations("ui") do
		styled = styled or (mark.from == buffer:line_start(1) and mark.style == "markdown.value")
	end
	assert(styled, "the part not drawn again keeps its marks")
end)

test("widgets in parts not drawn again still press", function(t)
	local buffer = shown(t)
	local pressed: { string } = {}
	local view = ui.mount(buffer, function(state)
		return ui.column({
			ui.keyed("top", 1, function()
				return ui.button("Top", function()
					table.insert(pressed, "top")
				end)
			end),
			ui.line({ ui.span(`n = {state.n}`) }),
			ui.keyed("bottom", state.n, function()
				return ui.button(`Bottom {state.n}`, function()
					table.insert(pressed, `bottom {state.n}`)
				end)
			end),
		})
	end, { n = 1 })
	view:set({ n = 2 })
	view:set({ n = 3 })
	t:keys("enter")
	t:keys("tab enter")
	assert(table.concat(pressed, ",") == "top,bottom 3", table.concat(pressed, ","))
	assert(text_of(buffer) == " Top \nn = 3\n Bottom 3 ", text_of(buffer))
end)

test("parts come, go and change places", function(t)
	local buffer = shown(t)
	local view = ui.mount(buffer, function(state)
		local parts: { core.UiNode } = {}
		for _, name in state.names do
			table.insert(
				parts,
				ui.keyed(name, 1, function()
					return ui.column({ ui.line({ ui.span(name) }), ui.line({ ui.span("-") }) })
				end)
			)
		end
		return ui.column(parts)
	end, { names = { "a", "b", "c" } })
	view:set({ names = { "a", "c" } })
	assert(text_of(buffer) == "a\n-\nc\n-", text_of(buffer))
	view:set({ names = { "c", "a", "d" } })
	assert(text_of(buffer) == "c\n-\na\n-\nd\n-", text_of(buffer))
	view:set({ names = {} })
	assert(text_of(buffer) == "", text_of(buffer))
	view:set({ names = { "b" } })
	assert(text_of(buffer) == "b\n-", text_of(buffer))
	local values = view:values()
	assert(#values == 0)
end)

test("values and spots are found in parts not drawn again", function(t)
	local buffer = shown(t)
	local view = ui.mount(buffer, function(state)
		return ui.column({
			ui.keyed("head", 1, function()
				return ui.line({ { text = "head", value = "h", tag = "x" } })
			end),
			ui.line({ { text = `n {state.n}`, value = state.n } }),
			ui.keyed("tail", 1, function()
				return ui.line({ { text = "tail", value = "t", tag = "x" } })
			end),
		})
	end, { n = 1 })
	view:set({ n = 22 })
	assert(view:value_at(0) == "h" and view:value_at(buffer:line_start(1)) == 22)
	assert(view:value_at(buffer:line_start(2)) == "t")
	local values = view:values()
	assert(#values == 3 and values[3] == "t")
	local spots = view:spots("x")
	assert(#spots == 2 and buffer:slice(spots[2].from, spots[2].to) == "tail")
end)

test("soon draws a burst of changes once", function(t)
	local buffer = shown(t)
	local draws = 0
	local view = ui.mount(buffer, function(state)
		draws += 1
		return ui.line({ ui.span(state.text) })
	end, { text = "" })
	local before = draws
	for i = 1, 50 do
		view:soon({ text = `token {i}` })
	end
	assert(draws == before, "not drawn yet")
	t:wait_for(function()
		return text_of(buffer) == "token 50"
	end)
	assert(draws == before + 1, `drawn {draws - before} times`)
end)

test("a span's own marks go along with it, where it's drawn", function(t)
	local buffer = shown(t)
	local view = ui.mount(buffer, function(state)
		return ui.column({
			ui.line({ ui.span(state.head) }),
			ui.line({
				ui.span("> "),
				{
					text = "said",
					marks = {
						{ from = 0, to = 1, style = "agent.bar", text = "▍", overlay = true },
					},
				},
			}),
		})
	end, { head = "one" }, { ns = "mine" })
	view:set({ head = "longer" })
	local mark = buffer:decorations("mine")[1]
	assert(mark and mark.overlay and mark.text == "▍", "the span's mark is there")
	assert(mark.from == buffer:line_start(1) + 2, `{mark.from}`)
	assert(#buffer:decorations("ui") == 0, "in the view's own namespace")
end)

test("a view with an input keeps what's written after it as it is", function(t)
	local buffer = greed.create_buffer("test-ui", "", {})
	t:buffer("|")
	greed.view():show(buffer)
	local view = ui.mount(buffer, function(state)
		local parts: { core.UiNode } = {}
		for _, said in state.said do
			table.insert(parts, ui.line({ ui.span(said) }))
		end
		table.insert(parts, ui.line({ ui.span("── box ──") }))
		return ui.column(parts)
	end, { said = { "hello" } }, { input = true })
	assert(text_of(buffer) == "hello\n── box ──\n", text_of(buffer))
	assert(view:input_start() == #"hello\n── box ──\n")
	greed.view():set_cursor(buffer:len())
	t:keys("i d r a f t")
	assert(text_of(buffer) == "hello\n── box ──\ndraft", text_of(buffer))
	view:set({ said = { "hello", "there", "more" } })
	assert(text_of(buffer) == "hello\nthere\nmore\n── box ──\ndraft", text_of(buffer))
	assert(greed.view():cursor() == buffer:len(), "the cursor stays in the input")
	view:set({ said = {} })
	assert(text_of(buffer) == "── box ──\ndraft", text_of(buffer))
	assert(view:input() == "draft")
	-- What it draws can't be typed in.
	assert(buffer:readonly_before() == view:input_start())
end)

test("each gives the lines with values, in order", function(t)
	local buffer = shown(t)
	local view = ui.mount(buffer, function()
		return ui.column({
			ui.keyed("a", 1, function()
				return ui.line({ { text = "one", value = "x" } })
			end),
			ui.line({ ui.span("nothing") }),
			ui.line({ { text = "two", value = "y" } }),
		})
	end)
	local seen: { string } = {}
	view:each(function(line: number, value: any)
		table.insert(seen, `{line}={value}`)
	end)
	assert(table.concat(seen, " ") == "0=x 2=y", table.concat(seen, " "))
end)

test("matched picks out the characters a fuzzy search matched", function()
	local spans = ui.matched("héllo world", greed.fuzzy_positions("hlw", "héllo world"))
	local parts: { string } = {}
	for _, span in spans do
		table.insert(parts, `{span.text}:{span.style or ""}`)
	end
	assert(
		table.concat(parts, "|") == "h:ui.menu.match|é:|l:ui.menu.match|lo :|w:ui.menu.match|orld:",
		table.concat(parts, "|")
	)
	local all = ui.matched("abc", {})
	assert(#all == 1 and all[1].text == "abc" and all[1].style == nil)
end)

test(
	"line_of and value_on find lines by value, and draw = false waits for the first redraw",
	function(t)
		local buffer = shown(t)
		local items: { string } = {}
		local view = ui.mount(buffer, function()
			return ui.list(items, function(item: string)
				return { ui.span(item) }
			end)
		end, nil, { draw = false })
		assert(text_of(buffer) == "", "nothing drawn yet")
		items = { "a", "b", "c" }
		view:redraw()
		assert(text_of(buffer) == "a\nb\nc", text_of(buffer))
		assert(greed.view():cursor() == 0, "the first drawing leaves the cursor at the top")
		assert(view:line_of(function(item: string): boolean
			return item == "c"
		end) == 2)
		assert(view:line_of(function(): boolean
			return false
		end) == nil)
		assert(view:value_on(1) == "b" and view:value_on(9) == nil)
	end
)

test(
	"with the input above, what's typed on the first line stays and the view goes under it",
	function(t)
		local buffer = greed.create_buffer("test-ui", "", {})
		t:buffer("|")
		greed.view():show(buffer)
		local view = ui.mount(buffer, function(state)
			local lines: { core.UiNode } = {}
			for _, name in state.names do
				table.insert(lines, ui.line({ { text = name, value = name, style = "keyword" } }))
			end
			return ui.column(lines)
		end, { names = { "one", "two" } }, { input = true, above = true })
		assert(text_of(buffer) == "\none\ntwo", text_of(buffer))
		t:keys("i t w esc")
		assert(view:input() == "tw", view:input())
		view:set({ names = { "two" } })
		assert(text_of(buffer) == "tw\ntwo", text_of(buffer))
		assert(view:value_on(1) == "two" and view:value_on(0) == nil)
		assert(view:line_of(function(name: string): boolean
			return name == "two"
		end) == 1)
		-- Its marks are where it is now, after the typing.
		local mark = buffer:decorations("ui")[1]
		assert(mark and mark.from == 3 and mark.to == 6, mark and `{mark.from}-{mark.to}`)
		t:keys("i o esc")
		view:set({ names = { "two", "three" } })
		assert(text_of(buffer) == "two\ntwo\nthree", text_of(buffer))
		local spots = 0
		for _, m in buffer:decorations("ui") do
			spots += 1
			assert(buffer:slice(m.from, m.to) == "two" or buffer:slice(m.from, m.to) == "three")
		end
		assert(spots == 2, `{spots} marks`)
	end
)

test("a view over an input can have no lines, leaving only the input", function(t)
	local buffer = greed.create_buffer("test-ui", ":", {})
	t:buffer("|")
	greed.view():show(buffer)
	local view = ui.mount(buffer, function(state)
		return ui.list(state.matches, function(name: string)
			return { ui.span(name) }
		end)
	end, { matches = {} }, { input = true })
	assert(text_of(buffer) == ":", text_of(buffer))
	assert(view:input() == ":" and view:input_start() == 0)
	view:set({ matches = { "write", "wq" } })
	assert(text_of(buffer) == "write\nwq\n:", text_of(buffer))
	assert(view:input() == ":")
	view:set({ matches = {} })
	assert(text_of(buffer) == ":", text_of(buffer))
	view:set({ matches = { "quit" } })
	assert(text_of(buffer) == "quit\n:", text_of(buffer))
end)

test("a list marks its current row, and opens a row when pressed", function(t)
	local buffer = shown(t)
	local opened: { string } = {}
	local view = ui.mount(buffer, function(state)
		return ui.list({ "one", "two", "three" }, function(item: string)
			return { ui.span(item) }
		end, {
			current = state.current,
			open = function(item: string)
				table.insert(opened, item)
			end,
		})
	end, { current = 2 })
	local function selected(): { string }
		local out: { string } = {}
		for _, mark in buffer:decorations("ui") do
			if mark.line and mark.style == "ui.menu.selected" then
				table.insert(out, buffer:slice(mark.from, mark.to))
			end
		end
		return out
	end
	assert(table.concat(selected(), ",") == "two", table.concat(selected(), ","))
	view:set({ current = 3 })
	assert(table.concat(selected(), ",") == "three", table.concat(selected(), ","))
	t:keys("enter")
	assert(opened[1] == "one", opened[1])
end)
