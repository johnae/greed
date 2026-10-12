local test = require("@greed/test")
local greed = require("@greed")
local markdown = require("@markdown")

local SIZES = "| Name | Size |\n|:--|--:|\n| a | 12 |\n| long name | 3 |\n"

-- `text` open as a Markdown file, drawn, the cursor at its start.
local function opened(t: test.TestContext, text: string): greed.View
	local dir = t:tempdir({ ["doc.md"] = text })
	greed.open(`{dir}/doc.md`)
	local view = greed.view()
	view:buffer():set_line_numbers(false)
	t:draw(40, 10)
	return view
end

-- The text under the cursor up to the next space or pipe.
local function under(view: greed.View): string
	local buffer = view:buffer()
	local at = view:cursor()
	local line = buffer:line_of(at)
	local rest = buffer:slice(at, buffer:line_end(line))
	return string.match(rest, "^[^|%s]*") or ""
end

local function text_of(view: greed.View): string
	local buffer = view:buffer()
	return buffer:slice(0, buffer:len())
end

local function at(view: greed.View, pos: number)
	view:set_selection({ ranges = { { anchor = pos, head = pos } }, primary = 1 })
end

test("a table's text writes back with its pipes lined up and its colons kept", function()
	local tables = markdown.tables
	local grid = assert(tables.grid({ "| Name | Size | Note |", "|:--|--:|---|", "| a | 12 |" }))
	assert(grid.specs[1] == "left" and grid.specs[2] == "right" and grid.specs[3] == "plain")
	local lines = tables.write(grid, function(s)
		return #s
	end)
	assert(lines[1] == "| Name | Size | Note |", lines[1])
	assert(lines[2] == "| :--- | ---: | ---- |", lines[2])
	assert(lines[3] == "| a    |   12 |      |", lines[3])
	assert(tables.column_at("| a | b |", 1) == 1 and tables.column_at("| a | b |", 5) == 1)
	assert(tables.column_at("| a | b |", 6) == 2 and tables.column_at("| a | b |", 9) == 2)
	assert(tables.column_at("text", 1) == nil)
end)

test("h and l step over a drawn table's pipes and padding, j and k keep the column", function(t)
	for _, style in { "helix", "vim" } do
		greed.option.set("editing-style", style)
		local view = opened(t, SIZES)
		at(view, 2)
		t:keys("l l l l")
		assert(under(view) == "Size", `{style}: l goes past the pipe: {under(view)}`)
		t:keys("h")
		assert(under(view) == "e", `{style}: h comes back onto the drawn text`)
		-- "Size" ends in the column "12" does, right-aligned.
		t:keys("l l l l j j")
		assert(under(view) == "2", `{style}: j keeps to the drawn column: {under(view)}`)
		t:keys("j")
		assert(under(view) == "3", `{style}: {under(view)}`)
	end
end)

test("alt-l and alt-h go cell to cell, row after row, and move panes outside a table", function(t)
	local view = opened(t, "before\n\n" .. SIZES)
	t:keys("j j alt-l")
	assert(under(view) == "Size", under(view))
	t:keys("alt-l")
	assert(under(view) == "a", "past the delimiter row onto the next row: " .. under(view))
	t:keys("alt-l alt-l alt-l")
	assert(under(view) == "3", under(view))
	t:keys("alt-l")
	assert(under(view) == "3", "the last cell stays")
	t:keys("alt-h alt-h")
	assert(under(view) == "12", under(view))
	-- Outside the table the key does what it always does.
	t:keys("g g ctrl-w v")
	t:draw(80, 10)
	local right = greed.view()
	t:keys("alt-h")
	assert(greed.view() ~= right, "alt-h moved to the pane on the left")
end)

test("enter on a cell asks for its text and lines the table up again", function(t)
	local view = opened(t, SIZES)
	local buffer = view:buffer()
	at(view, buffer:line_start(2) + 2)
	t:keys("enter")
	t:keys("backspace b c enter")
	assert(
		text_of(view)
			== "| Name      | Size |\n| :-------- | ---: |\n| bc        |   12 |\n| long name |    3 |\n",
		text_of(view)
	)
	assert(under(view) == "bc", "the cursor stays in the cell")
	-- A pipe typed in stays in the cell.
	t:keys("enter backspace backspace x space | space y enter")
	assert(string.find(text_of(view), "| x \\| y    |", 1, true), text_of(view))
end)

test("enter on a cell a formula fills edits the formula", function(t)
	local view = opened(
		t,
		"| Item | Price | Tax |\n|---|---|---|\n| tea | 10 | |\n<!-- formula: tax = price * 0.25 -->\n"
	)
	local buffer = view:buffer()
	at(view, buffer:line_start(2) + 2)
	t:keys("alt-l alt-l enter")
	for _ = 1, 4 do
		t:keys("backspace")
	end
	t:keys("0 . 5 enter")
	assert(
		string.find(text_of(view), "<!-- formula: tax = price * 0.5 -->", 1, true),
		text_of(view)
	)
end)

test("rows and columns are added, deleted, moved and sorted from the leader", function(t)
	local view = opened(t, "| Name | Size |\n|---|--:|\n| b | 2 |\n| a | 10 |\n")
	local buffer = view:buffer()
	at(view, buffer:line_start(2) + 2)
	t:keys("space m t o")
	assert(
		text_of(view)
			== "| Name | Size |\n| ---- | ---: |\n| b    |    2 |\n|      |      |\n| a    |   10 |\n",
		text_of(view)
	)
	assert(buffer:line_of(view:cursor()) == 3, "on the new row")
	t:keys("space m t d")
	t:keys("space m t s")
	assert(string.find(text_of(view), "| a    |   10 |\n| b    |    2 |", 1, true), text_of(view))
	t:keys("alt-l space m t s")
	assert(
		string.find(text_of(view), "| b    |    2 |\n| a    |   10 |", 1, true),
		"by size: 2 before 10"
	)
	t:keys("space m t S")
	assert(string.find(text_of(view), "| a    |   10 |\n| b    |    2 |", 1, true), text_of(view))
	t:keys("space m t c")
	assert(
		string.find(text_of(view), "| Name | Size |     |\n| ---- | ---: | --- |", 1, true),
		text_of(view)
	)
	t:keys("space m t D space m t h")
	assert(string.find(text_of(view), "| Size | Name |\n| ---: | ---- |", 1, true), text_of(view))
	-- On b's row, the second: up, then up again stays first.
	t:keys("space m t k")
	assert(buffer:line_of(view:cursor()) == 2, "moved up with its row")
	assert(string.find(text_of(view), "|    2 | b    |\n|   10 | a    |", 1, true), text_of(view))
	t:keys("space m t k")
	assert(buffer:line_of(view:cursor()) == 2, "the first row stays first")
	t:keys("space m t j")
	assert(buffer:line_of(view:cursor()) == 3, "moved down with its row")
	-- Each change is one to undo.
	t:keys("u")
	assert(string.find(text_of(view), "|    2 | b    |\n|   10 | a    |", 1, true), text_of(view))
end)

test("the header row and a table's last column stay", function(t)
	local view = opened(t, "| Name |\n|---|\n| a |\n")
	t:keys("space m t d")
	assert(text_of(view) == "| Name |\n|---|\n| a |\n", "the header stays")
	t:keys("space m t D")
	assert(text_of(view) == "| Name |\n|---|\n| a |\n", "the last column stays")
	assert(markdown.table_edit.at(view:buffer(), 0) ~= nil)
	assert(markdown.table_edit.at(view:buffer(), view:buffer():len()) == nil, "past the table")
end)

test("a row typed short of cells is filled out when typing ends, and lined up", function(t)
	local view = opened(t, "| Item | Amount | Per year |\n|---|--:|--:|\n| Rent | 10 | |\n")
	local buffer = view:buffer()
	at(view, buffer:line_end(2))
	t:keys("o")
	t:keys("| space T h i n g space | space 8 space |")
	t:keys("esc")
	assert(
		text_of(view)
			== "| Item  | Amount | Per year |\n| ----- | -----: | -------: |\n| Rent  |     10 |          |\n| Thing |      8 |          |\n",
		text_of(view)
	)
end)

test("alt-l into a cell the row doesn't have yet fills the row out", function(t)
	-- Typed in another editor, never lined up.
	local view = opened(t, "| Item | Amount | Per year |\n|---|---|---|\n| Thing | 8 |\n")
	local buffer = view:buffer()
	at(view, buffer:line_start(2) + 2)
	t:keys("alt-l alt-l")
	assert(string.find(text_of(view), "| Thing | 8      |          |", 1, true), text_of(view))
	assert(assert(markdown.table_edit.at(buffer, view:cursor())).column == 3, "in the new cell")
end)

test("typing that changes nothing, like a search into a table, leaves it as written", function(t)
	local written = "| Item | Amount |\n|---|--:|\n| Rent | 10 |\n| Hosting | 5 |\n"
	local view = opened(t, written)
	t:keys("/ H o s t enter")
	assert(text_of(view) == written, text_of(view))
	assert(not view:buffer():modified(), "nothing to save")
	t:keys("i esc")
	assert(text_of(view) == written, "in and out of typing: " .. text_of(view))
end)
