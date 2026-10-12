local test = require("@greed/test")
local core = require("@core")

local formula = core.formula

-- What `source` works out to with `scope`, or the error as `!message`.
local function value(source: string, scope: { [string]: any }?): any
	local f, err = formula.compile(source)
	if f == nil then
		return `!{err}`
	end
	local v, failed = formula.eval(f, scope or {})
	if failed then
		return `!{failed}`
	end
	return v
end

test("formulas work out as Luau's expressions do, in Luau's order", function()
	assert(value("1 + 2 * 3") == 7)
	assert(value("(1 + 2) * 3") == 9)
	assert(value("-2 ^ 2") == -4, "^ binds over unary minus")
	assert(value("2 ^ 3 ^ 2") == 512, "^ is right-handed")
	assert(value("7 // 2") == 3 and value("7 % 2") == 1)
	assert(value('"a" .. "b" .. 1') == "ab1")
	assert(value("1 < 2 and 3 >= 3") == true)
	assert(value("not true or 1 == 1") == true)
	assert(value("2 ~= 3") == true)
	assert(value("if 1 > 2 then 'a' elseif 2 > 1 then 'b' else 'c'") == "b")
	assert(value("0x10 + .5 + 1e2") == 116.5)
	assert(value('"say \\"hi\\""') == 'say "hi"')
end)

test("names come from the scope: values, rows, lists and their parts", function()
	local scope = {
		amount = 100,
		price = "12.5",
		costs = { { item = "rent", amount = 900 }, { item = "food", amount = 350 } },
		list = { 1, 2, 3 },
	}
	assert(value("amount * 12", scope) == 1200)
	assert(value("price * 2", scope) == 25, "text that reads as a number counts as one")
	assert(value("costs[1].item", scope) == "rent")
	assert(value("costs[2]['amount']", scope) == 350)
	assert(value("#list + list[3]", scope) == 6)
	assert(value("sum(list) + avg(list) + count(list)", scope) == 11)
	assert(value("min(list) + max(3, 9, 4)", scope) == 10)
	assert(value("round(2.345, 2)", scope) == 2.35 and value("fixed(2.5)", scope) == "2.50")
	-- A scope can be a function, asked for each name.
	local asked = {}
	local f = assert(formula.compile("a + b"))
	assert(formula.eval(f, function(name)
		table.insert(asked, name)
		return 1
	end) == 2)
	assert(asked[1] == "a" and asked[2] == "b", "asked by name")
	assert(table.concat(formula.names((assert(formula.compile("x + f(y, x)")))), ",") == "x,y")
end)

test("what goes wrong is said in words for whoever wrote the formula", function()
	assert(value("amount * 2") == "!`amount` is empty")
	assert(value("name * 2", { name = "Ada" }) == "!`name` isn't a number")
	assert(value("nosuch(1)") == "!there's no function called nosuch")
	assert(value("1 +") == "!the formula ends too soon")
	assert(string.find(value("1 2"), "can't go here", 1, true) ~= nil)
	assert(value("'open") == "!text without its closing quote")
	assert(value("if x then 1") == "!expected else (an if needs one in a formula) at 12")
	assert(value("'a' < 1") == "!these can't be compared, at 5")
end)

test("a formula can't do anything but work out a value", function()
	-- No statements, no loops, no calls but to the functions there are.
	assert(string.find(value("x = 1"), "can't be in a formula", 1, true) ~= nil)
	assert(string.find(value("while true do end"), "can't go here", 1, true) ~= nil)
	assert(value("print('hi')") == "!there's no function called print")
	assert(
		value("(function() end)()") ~= nil and string.sub(value("(function() end)()"), 1, 1) == "!"
	)
	assert(
		string.find(value("string.rep('a', 10)"), "only a function's name can be called", 1, true)
			~= nil
	)
	assert(value("string.rep", {}) == "!`string` has no rep")
	-- Text joined to itself can't grow past a limit.
	local scope = { s = string.rep("x", 60000) }
	assert(value("s .. s", scope) == "!the text it makes is too long")
end)

test("what a value shows as", function()
	assert(formula.show(42) == "42" and formula.show(0.1 + 0.2) == "0.3")
	assert(formula.show({ 1, 2.5 }) == "1, 2.5" and formula.show(nil) == "")
	assert(formula.show(true) == "true")
end)

test("plugins add functions formulas may call", function()
	formula.add("double", function(x)
		return x * 2
	end, "Twice a number")
	assert(value("double(21)") == 42)
	assert(formula.functions().double == "Twice a number")
	assert(formula.functions().sum ~= nil, "the built-in ones are listed too")
	formula.add("broken", function()
		error("it broke")
	end, "Fails")
	assert(string.find(value("broken()"), "!broken: ", 1, true) ~= nil)
end)
