local test = require("@greed/test")
local greed = require("@greed")
local markdown = require("@markdown")

local values = markdown.values

-- `text` open as a Markdown file, the cursor at its end on a line of its
-- own, drawn: the rows, joined.
local function shown(t: test.TestContext, text: string): string
	local dir = t:tempdir({ ["doc.md"] = text .. "\n" })
	greed.open(`{dir}/doc.md`)
	local view = greed.view()
	view:buffer():set_line_numbers(false)
	local last = view:buffer():len()
	view:set_selection({ ranges = { { anchor = last, head = last } }, primary = 1 })
	return table.concat(t:draw(60, 30), "\n")
end

local BILL = [[
Bill: [40](field:bill)
<!-- let tip = bill * 0.25 -->
Tip: {{ tip }}, in all {{ fixed(bill + tip) }}

Pay how? <!-- id=pay -->

- (x) Card
- ( ) Cash

<!-- id=costs -->
| Item | Amount |
|------|--------|
| Rent | 900    |
| Food | 350    |

Costs {{ sum(costs.amount) }}, first {{ costs[1].item }}, paying by {{ pay }}.
Broken {{ nothing + 1 }}, `{{ not drawn }}`.]]

test(
	"values show what their formulas work out to, from fields, lets, answers and tables",
	function(t)
		local rows = shown(t, BILL)
		assert(string.find(rows, "Bill: [ 40 ]", 1, true), rows)
		assert(string.find(rows, "Tip: 10, in all 50.00", 1, true), rows)
		assert(string.find(rows, "Costs 1250, first Rent, paying by Card.", 1, true), rows)
		assert(string.find(rows, "Broken ⚠ `nothing` is empty", 1, true), rows)
		assert(
			string.find(rows, "`{{ not drawn }}`", 1, true)
				or string.find(rows, "{{ not drawn }}", 1, true),
			rows
		)
		assert(not string.find(rows, "let tip", 1, true), "lets don't show")
	end
)

test("setting a field writes it in the file, and every value from it follows", function(t)
	shown(t, BILL)
	local buffer = greed.view():buffer()
	local field = assert(values.field_at(buffer, 8))
	assert(field.name == "bill" and field.value == "40", field.value)
	values.set(buffer, field, "100")
	assert(string.find(buffer:text(), "Bill: [100](field:bill)", 1, true), buffer:text())
	local rows = table.concat(t:draw(60, 30), "\n")
	assert(string.find(rows, "Tip: 25, in all 125.00", 1, true), rows)
	-- A pick changes what names its question too.
	markdown.choices.pick(buffer, 7)
	rows = table.concat(t:draw(60, 30), "\n")
	assert(string.find(rows, "paying by Cash", 1, true), rows)
end)

test("a let that names itself, and an empty field", function(t)
	local rows = shown(
		t,
		"<!-- let a = b + 1 -->\n<!-- let b = a + 1 -->\nA is {{ a }}\nName: [](field:name)"
	)
	assert(string.find(rows, "A is ⚠ a: b: a depends on itself", 1, true), rows)
	assert(string.find(rows, "Name: [      ]", 1, true), rows)
end)

local BUDGET = [[
Income: [3000](field:income)

<!-- id=costs -->
| Item | Amount | Per year | So far |
|------|-------:|---------:|--------|
| Rent | 900    |          |        |
| Food | 350    | 1        |        |
<!-- formula: per_year = amount * 12 -->
<!-- formula: so_far = (if prev then prev.so_far else 0) + amount -->

Left {{ income - sum(costs.amount) }}, {{ sum(costs.per_year) }} a year.]]

test("a table's formula columns are worked out row by row, and its values use them", function(t)
	local rows = shown(t, BUDGET)
	assert(string.find(rows, "│ Rent │    900 │    10800 │ 900    │", 1, true), rows)
	-- What the file says in a formula's column gives way to what it works out.
	assert(string.find(rows, "│ Food │    350 │     4200 │ 1250   │", 1, true), rows)
	assert(string.find(rows, "Left 1750, 15000 a year.", 1, true), rows)
	assert(not string.find(rows, "formula:", 1, true), "formulas don't show")
	-- A field the table's formulas don't use, changed: the values follow.
	local buffer = greed.view():buffer()
	values.set(buffer, assert(values.field_at(buffer, 9)), "2000")
	rows = table.concat(t:draw(60, 30), "\n")
	assert(string.find(rows, "Left 750,", 1, true), rows)
end)

test("a command button's values are its command's, left for it", function(t)
	local rows = shown(t, "Who: [Ada](field:who)\n\n[Greet](run:echo hi {{ who }})")
	assert(not string.find(rows, "hi Ada", 1, true), rows)
	local buffer = greed.view():buffer()
	for _, mark in buffer:decorations("markdown-values") do
		assert(mark.text ~= "Ada", "no value drawn in the command")
	end
end)
