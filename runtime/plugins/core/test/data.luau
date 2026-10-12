local test = require("@greed/test")
local core = require("@core")

local data = core.data

local function ask(body: string?): core.DataAsk
	return { args = {}, body = body or "", values = {} }
end

test("a source gives its table as asked, and goes with the plugin that added it", function()
	data.source({
		name = "test-numbers",
		doc = "One row a number up to the body's",
		read = function(a: core.DataAsk): (core.DataTable?, string?)
			local rows: { { [string]: any } } = {}
			for n = 1, tonumber(a.body) or 0 do
				local row: { [string]: any } = { n = n }
				table.insert(rows, row)
			end
			local column: core.DataColumn = { name = "n", kind = "number" }
			return { columns = { column }, rows = rows }, nil
		end,
	})
	local t = assert(data.read("test-numbers", ask("3")))
	assert(#t.rows == 3 and t.rows[3].n == 3, "three rows")
	assert(data.get("test-numbers") ~= nil and data.get("nope") == nil)
	local found = false
	for _, source in data.sources() do
		found = found or source.name == "test-numbers"
	end
	assert(found, "listed")
end)

test("reading says why when there's no table", function()
	local none, why = data.read("no-such-source", ask())
	assert(none == nil and string.find(why or "", "no data source called", 1, true), why)
	data.source({
		name = "test-broken",
		read = function(): (core.DataTable?, string?)
			error("the database is gone")
		end,
	})
	none, why = data.read("test-broken", ask())
	assert(none == nil and string.find(why or "", "the database is gone", 1, true), why)
	data.source({
		name = "test-shapeless",
		read = function(): (core.DataTable?, string?)
			return ({ rows = {} } :: any) :: core.DataTable, nil
		end,
	})
	none, why = data.read("test-shapeless", ask())
	assert(none == nil and string.find(why or "", "columns, rows", 1, true), why)
	data.source({
		name = "test-empty",
		read = function(): (core.DataTable?, string?)
			return nil, "nothing matched"
		end,
	})
	none, why = data.read("test-empty", ask())
	assert(none == nil and why == "nothing matched", why)
end)

test("text cells read as values, numbers where a column is all numbers, and back", function()
	local t = data.from_text({
		columns = { "item", "amount", "note" },
		rows = {
			{ item = "rent", amount = "900", note = "" },
			{ item = "food", amount = "12.5", note = "x" },
		},
	})
	assert(t.columns[1].kind == "text" and t.columns[2].kind == "number", "kinds")
	assert(t.rows[2].amount == 12.5 and t.rows[1].note == "" and t.rows[1].item == "rent")
	local back = data.text(t)
	assert(table.concat(back.columns, ",") == "item,amount,note")
	assert(back.rows[1].amount == "900" and back.rows[2].amount == "12.5", back.rows[2].amount)
	assert(data.value("42") == 42 and data.value("x") == "x" and data.value("") == nil)
end)
