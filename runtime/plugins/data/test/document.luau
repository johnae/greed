local test = require("@greed/test")
local greed = require("@greed")
local data = require("@data")

-- `files` in a folder, `doc.md` among them, open and drawn: the rows.
local function opened(t: test.TestContext, files: { [string]: string }): (string, greed.View)
	local dir = t:tempdir(files)
	greed.open(`{dir}/doc.md`)
	local view = greed.view()
	view:buffer():set_line_numbers(false)
	-- Off the blocks, where they show as tables.
	local last = view:buffer():len()
	view:set_selection({ ranges = { { anchor = last, head = last } }, primary = 1 })
	return dir, view
end

-- The screen, once `find` is on it.
local function shows(t: test.TestContext, find: string): string
	local rows = ""
	t:wait_for(function()
		rows = table.concat(t:draw(70, 24), "\n")
		return string.find(rows, find, 1, true) ~= nil
	end)
	return rows
end

test("a csv block shows its lines as a table, numbers on the right", function(t)
	opened(t, { ["doc.md"] = "Sales:\n\n```csv\nregion,units\nnorth,12\nsouth,7\n```\n\nafter\n" })
	local rows = shows(t, "│ north  │    12 │")
	assert(string.find(rows, "▦ csv · 2 rows", 1, true), rows)
	assert(string.find(rows, "│ region │ units │", 1, true), rows)
	assert(not string.find(rows, "north,12", 1, true), "the lines fold under the header: " .. rows)
	assert(string.find(rows, "after", 1, true), rows)
end)

test("a csv file beside the document is read, and again when it changes", function(t)
	local dir = opened(t, {
		["doc.md"] = "```csv path=sales.csv\n```\n",
		["sales.csv"] = "region,units\nnorth,12\n",
	})
	local rows = shows(t, "│ north  │    12 │")
	assert(string.find(rows, "▦ csv · sales.csv · 1 row", 1, true), rows)
	greed.fs.write(`{dir}/sales.csv`, "region,units\nnorth,12\nwest,30\n")
	shows(t, "│ west   │    30 │")
end)

test("what fails says why where the table would be", function(t)
	opened(t, { ["doc.md"] = "```csv path=missing.csv\n```\n" })
	shows(t, "⚠ can't read missing.csv")
end)

test("rows=N shows N rows at a time, space m n and space m p turning the page", function(t)
	local _, view = opened(t, {
		["doc.md"] = "```csv rows=2\nn\n1\n2\n3\n4\n5\n```\n",
	})
	local rows = shows(t, "rows 1–2, more")
	view:set_selection({ ranges = { { anchor = 0, head = 0 } }, primary = 1 })
	t:keys("space m n")
	rows = shows(t, "rows 3–4, more")
	assert(
		string.find(rows, "│ 3 │", 1, true) and not string.find(rows, "│ 1 │", 1, true),
		rows
	)
	t:keys("space m n space m n")
	rows = shows(t, "rows 5–5")
	assert(string.find(table.concat(t:messages(), "\n"), "last of them", 1, true) ~= nil)
	t:keys("space m p")
	shows(t, "rows 3–4, more")
end)

-- A database at `dir/shop.db` with three customers, made by sqlite3.
local function shop(dir: string)
	assert(greed.process.run({ "sqlite3", `{dir}/shop.db` }, {
		stdin = "create table customers(name text, city text, total int);\n"
			.. "insert into customers values ('ann', 'oslo', 10), ('bob', 'rome', 20), ('it''s', 'oslo', 5);\n",
	}))
end

test("a sqlite query waits until you let it, then binds the page's values", function(t)
	if greed.which("sqlite3") == nil then
		return
	end
	local dir = t:tempdir()
	shop(dir)
	greed.fs.write(
		`{dir}/doc.md`,
		"City: [oslo](field:city)\n\n```sqlite db=shop.db\nSELECT name, total FROM customers WHERE city = @city ORDER BY total\n```\n"
	)
	greed.open(`{dir}/doc.md`)
	local view = greed.view()
	view:buffer():set_line_numbers(false)
	shows(t, "▦ sqlite · shop.db · ▶ enter runs it")
	-- enter on its line: asked about the file, a lets it run from now on.
	local open = view:buffer():line_start(2)
	view:set_selection({ ranges = { { anchor = open, head = open } }, primary = 1 })
	t:keys("enter a")
	local last = view:buffer():len()
	view:set_selection({ ranges = { { anchor = last, head = last } }, primary = 1 })
	local rows = shows(t, "│ ann  │    10 │")
	assert(string.find(rows, "│ it's │     5 │", 1, true), rows)
	assert(not string.find(rows, "bob", 1, true), "only oslo: " .. rows)
	-- Another value, read again.
	local buffer = view:buffer()
	require("@markdown").values.set(
		buffer,
		assert(require("@markdown").values.field_at(buffer, 7)),
		"rome"
	)
	shows(t, "│ bob  │    20 │")
end)

test("sqlite gets each value as one SQL literal, whatever it holds", function()
	local input = assert((data.sources.sqlite_input("SELECT @a, @b, @c, @a", {
		a = 'it\'s "x" \\ \n',
		b = 12,
	})))
	local lines = string.split(input, "\n")
	assert(lines[1] == ".parameter init")
	assert(lines[2] == [[.parameter set @a "'it''s \"x\" \\ \n'"]], lines[2])
	assert(lines[3] == '.parameter set @b "12"', lines[3])
	assert(lines[4] == '.parameter set @c "NULL"', lines[4])
	assert(lines[5] == "SELECT @a, @b, @c, @a", lines[5])
	local _, why = data.sources.sqlite_input("SELECT @list", { list = { 1, 2 } })
	assert(why and string.find(why, "@list", 1, true), why)
end)

test("psql gets the values as its variables, quoted by psql", function(t)
	local dir = t:tempdir({
		-- Stands in for psql: says what it was given, and prints CSV.
		["bin/psql"] = '#!/bin/sh\nprintf "%s\\n" "$@" > "$(dirname "$0")/args"\ncat > "$(dirname "$0")/query"\nprintf "name,total\\nann,10\\n"\n',
		["doc.md"] = "Who: [ann](field:who)\n\n```psql db=shop\nSELECT name, total FROM customers WHERE name = @who\n```\n",
	})
	assert(greed.process.run({ "chmod", "+x", `{dir}/bin/psql` }))
	local query, args = data.sources.psql_args("SELECT @who, @@x, @who", { who = "it's" })
	assert(query == "SELECT :'who', @@x, :'who'", query)
	assert(args and table.concat(args, " ") == "-v who=it's", args and table.concat(args, " "))
	-- Through the document, with the stand-in as psql, let run.
	greed.option.set("data-psql", `{dir}/bin/psql`)
	greed.open(`{dir}/doc.md`)
	local view = greed.view()
	local open = view:buffer():line_start(2)
	view:set_selection({ ranges = { { anchor = open, head = open } }, primary = 1 })
	t:keys("enter a")
	local last = view:buffer():len()
	view:set_selection({ ranges = { { anchor = last, head = last } }, primary = 1 })
	shows(t, "│ ann  │    10 │")
	local given = assert(greed.fs.read(`{dir}/bin/args`))
	assert(string.find(given, "-d\nshop\n", 1, true), given)
	assert(string.find(given, "-v\nwho=ann\n", 1, true), given)
	local sent = assert(greed.fs.read(`{dir}/bin/query`))
	assert(string.find(sent, "WHERE name = :'who'", 1, true), sent)
end)

test("a data block with id= is a value for the document's formulas", function(t)
	opened(t, {
		["doc.md"] = "```csv id=sales\nregion,units\nnorth,12\nsouth,7\n```\n\nIn all {{ sum(sales.units) }} units, the most in {{ sales[1].region }}.\n",
	})
	shows(t, "In all 19 units, the most in north.")
	local values = require("@markdown").values.all(greed.view():buffer())
	assert(values.sales and #values.sales == 2 and values.sales[2].units == 7, "for blocks too")
end)

test("space m o opens the table in a float as text, a page at a time", function(t)
	local _, view =
		opened(t, { ["doc.md"] = "```csv rows=2\nname,age\nann,31\nbob,45\ncid,22\n```\n" })
	shows(t, "▦ csv · rows 1–2, more")
	view:set_selection({ ranges = { { anchor = 0, head = 0 } }, primary = 1 })
	t:keys("space m o")
	local float = greed.view()
	local buffer = float:buffer()
	assert(buffer:kind() == "data-table", buffer:kind())
	t:wait_for(function()
		return string.find(buffer:slice(0, buffer:len()), "│ bob  │  45 │", 1, true) ~= nil
	end)
	local text = buffer:slice(0, buffer:len())
	assert(string.find(text, "rows 1–2", 1, true), text)
	assert(string.find(text, " Later ▶ ", 1, true), text)
	-- Enter on a row shows the whole record.
	local row = assert((string.find(text, "│ ann", 1, true))) + #"│ " - 1
	float:set_selection({ ranges = { { anchor = row, head = row } }, primary = 1 })
	t:keys("enter")
	local record = greed.view():buffer()
	assert(
		string.find(record:slice(0, record:len()), "age: 31", 1, true),
		record:slice(0, record:len())
	)
	t:keys("q")
	assert(greed.view() == float, "back on the table")
	-- The next page, by its button.
	local later = assert((string.find(buffer:slice(0, buffer:len()), " Later", 1, true))) - 1
	float:set_selection({ ranges = { { anchor = later, head = later } }, primary = 1 })
	t:keys("enter")
	t:wait_for(function()
		return string.find(buffer:slice(0, buffer:len()), "│ cid  │  22 │", 1, true) ~= nil
	end)
	t:keys("q")
	assert(not float:valid(), "q closes it")
end)
