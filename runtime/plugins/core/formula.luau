-- Formulas: Luau's expressions, without the rest of Luau. A formula is
-- worked out by this file alone, never run as code: it has no statements,
-- no loops and calls only the functions here or ones plugins add, so it
-- always finishes, quickly, and can't do anything but work out a value.
-- That's what lets a document's formulas work anywhere, without asking.
--
--     amount * 12
--     sum(costs.amount) - income
--     if paid then 0 else round(total * 1.25, 2)
--     name .. " (" .. city .. ")"
--
-- Names come from the scope a formula is worked out in: a table's columns,
-- a document's fields and `let`s. A list (a table's column) goes to `sum`,
-- `avg` and the like; `#list` counts it and `list[1]` is its first.

local greed = require("@greed")

local M = {}

--- A formula, read: worked out with `M.eval`, as often as needed.
export type Formula = { source: string, node: Node }

-- What a formula is made of.
type Node = {
	k: string,
	v: any,
	op: string?,
	a: Node?,
	b: Node?,
	args: { Node }?,
	branches: { { Node } }?,
	at: number,
}

--- A function formulas may call: it gets the values worked out, and gives
--- one back. It has to be quick; it runs as the formula is worked out.
export type Fn = (...any) -> any

--- Where a formula's names come from: a table of values, or a function
--- giving a name's value (nil for one it doesn't know).
export type Scope = { [string]: any } | (name: string) -> any

-- The longest text a formula may make, so text joined to itself through
-- `let`s can't fill the memory.
local MAX_TEXT = 100000

-- Tokens: numbers, text, names, and the operators Luau's expressions have.
type Token = { k: string, v: any, at: number }

local OPERATORS: { string } = {
	"...",
	"..",
	"==",
	"~=",
	"<=",
	">=",
	"//",
	"+",
	"-",
	"*",
	"/",
	"%",
	"^",
	"#",
	"<",
	">",
	"(",
	")",
	"[",
	"]",
	",",
	".",
}

local WORDS: { [string]: boolean } = {
	["and"] = true,
	["or"] = true,
	["not"] = true,
	["if"] = true,
	["then"] = true,
	["elseif"] = true,
	["else"] = true,
	["true"] = true,
	["false"] = true,
	["nil"] = true,
}

local ESCAPES: { [string]: string } =
	{ n = "\n", t = "\t", ["\\"] = "\\", ['"'] = '"', ["'"] = "'" }

-- The tokens of `source`, or nil and why not.
local function tokens(source: string): ({ Token }?, string?)
	local out: { Token } = {}
	local i = 1
	while i <= #source do
		local c = string.sub(source, i, i)
		if string.match(c, "%s") then
			i += 1
		elseif string.match(source, "^%d", i) or string.match(source, "^%.%d", i) then
			local text = string.match(source, "^0[xX]%x+", i)
				or string.match(source, "^%d*%.?%d+[eE][%+%-]?%d+", i)
				or string.match(source, "^%d+%.?%d*", i)
				or string.match(source, "^%.%d+", i) :: string
			local value = tonumber((string.gsub(text, "_", "")))
			if value == nil then
				return nil, `{text} isn't a number`
			end
			table.insert(out, { k = "num", v = value, at = i })
			i += #text
		elseif string.match(c, "[%a_]") then
			local word = string.match(source, "^[%a_][%w_]*", i) :: string
			table.insert(out, { k = if WORDS[word] then word else "name", v = word, at = i })
			i += #word
		elseif c == '"' or c == "'" then
			local parts: { string } = {}
			local j = i + 1
			while true do
				local ch = string.sub(source, j, j)
				if ch == "" or ch == "\n" then
					return nil, "text without its closing quote"
				elseif ch == c then
					break
				elseif ch == "\\" then
					local escaped = ESCAPES[string.sub(source, j + 1, j + 1)]
					if escaped == nil then
						return nil,
							`\\{string.sub(source, j + 1, j + 1)} isn't something text can have`
					end
					table.insert(parts, escaped)
					j += 2
				else
					table.insert(parts, ch)
					j += 1
				end
			end
			table.insert(out, { k = "str", v = table.concat(parts), at = i })
			i = j + 1
		else
			local found: string? = nil
			for _, op in OPERATORS do
				if string.sub(source, i, i + #op - 1) == op then
					found = op
					break
				end
			end
			if found == nil or found == "..." then
				return nil, `{c} can't be in a formula`
			end
			table.insert(out, { k = found, v = found, at = i })
			i += #found
		end
	end
	table.insert(out, { k = "end", v = nil, at = #source + 1 })
	return out, nil
end

-- How tightly each operator binds, Luau's order: the left and right sides
-- (right-handed ones bind less to their right).
local BINARY: { [string]: { number } } = {
	["or"] = { 1, 1 },
	["and"] = { 2, 2 },
	["<"] = { 3, 3 },
	[">"] = { 3, 3 },
	["<="] = { 3, 3 },
	[">="] = { 3, 3 },
	["~="] = { 3, 3 },
	["=="] = { 3, 3 },
	[".."] = { 5, 4 },
	["+"] = { 6, 6 },
	["-"] = { 6, 6 },
	["*"] = { 7, 7 },
	["/"] = { 7, 7 },
	["//"] = { 7, 7 },
	["%"] = { 7, 7 },
	["^"] = { 10, 9 },
}
-- Unary operators bind under `^` and over the rest: `-2^2` is -4.
local UNARY = 8

-- Stops reading or working out the formula with `message`.
local function fail(message: string): never
	error({ formula = message }, 0)
end

-- Reads tokens into nodes; errors with `{ formula = message }`.
local function parser(list: { Token })
	local pos = 1
	local function peek(): Token
		return list[pos]
	end
	local function take(kind: string, what: string?): Token
		local token = list[pos]
		if token.k ~= kind then
			fail(`expected {what or kind} at {token.at}`)
		end
		pos += 1
		return token
	end
	local expression: (limit: number) -> Node
	local function primary(): Node
		local token = peek()
		pos += 1
		local k = token.k
		if k == "num" or k == "str" or k == "name" then
			return { k = k, v = token.v, at = token.at }
		elseif k == "true" or k == "false" then
			return { k = "bool", v = k == "true", at = token.at }
		elseif k == "nil" then
			return { k = "nil", v = nil, at = token.at }
		elseif k == "(" then
			local inner = expression(0)
			take(")", "a closing )")
			return inner
		elseif k == "if" then
			local branches: { { Node } } = {}
			local condition = expression(0)
			take("then")
			table.insert(branches, { condition, expression(0) })
			while peek().k == "elseif" do
				pos += 1
				local c = expression(0)
				take("then")
				table.insert(branches, { c, expression(0) })
			end
			take("else", "else (an if needs one in a formula)")
			return { k = "if", v = nil, branches = branches, a = expression(0), at = token.at }
		elseif k == "-" or k == "not" or k == "#" then
			return { k = "un", v = nil, op = k, a = expression(UNARY), at = token.at }
		end
		return fail(if k == "end" then "the formula ends too soon" else `{token.v} can't go here`)
	end
	-- What follows a value: `.name`, `[key]` and `(arguments)`.
	local function suffixed(): Node
		local node = primary()
		while true do
			local k = peek().k
			if k == "." then
				pos += 1
				local name = take("name", "a name after .")
				node = {
					k = "index",
					v = nil,
					a = node,
					b = { k = "str", v = name.v, at = name.at },
					at = name.at,
				}
			elseif k == "[" then
				local at = peek().at
				pos += 1
				local key = expression(0)
				take("]", "a closing ]")
				node = { k = "index", v = nil, a = node, b = key, at = at }
			elseif k == "(" then
				if node.k ~= "name" then
					fail(`only a function's name can be called, at {peek().at}`)
				end
				pos += 1
				local args: { Node } = {}
				if peek().k ~= ")" then
					table.insert(args, expression(0))
					while peek().k == "," do
						pos += 1
						table.insert(args, expression(0))
					end
				end
				take(")", "a closing )")
				node = { k = "call", v = node.v, args = args, at = node.at }
			else
				return node
			end
		end
	end
	function expression(limit: number): Node
		local left = suffixed()
		while true do
			local op = peek().k
			local power = BINARY[op]
			if power == nil or power[1] <= limit then
				return left
			end
			local at = peek().at
			pos += 1
			left = { k = "bin", v = nil, op = op, a = left, b = expression(power[2]), at = at }
		end
	end
	return function(): Node
		local node = expression(0)
		if peek().k ~= "end" then
			fail(`{peek().v} can't go here`)
		end
		return node
	end
end

-- Formulas read, by their text.
local read: { [string]: Formula } = {}

--- Reads `source`, a formula, or gives nil and why it can't be read. Each
--- text is read once.
function M.compile(source: string): (Formula?, string?)
	local known = read[source]
	if known then
		return known, nil
	end
	local list, err = tokens(source)
	if list == nil then
		return nil, err
	end
	local ok, node: any = pcall(parser(list))
	if not ok then
		return nil, if type(node) == "table" then node.formula else tostring(node)
	end
	local formula: Formula = { source = source, node = node }
	read[source] = formula
	return formula, nil
end

-- The functions formulas may call, by name, with what they're for.
local functions: { [string]: { fn: Fn, doc: string } } = {}

--- Lets formulas call `fn` as `name`. It goes when the plugin that added
--- it does.
function M.add(name: string, fn: Fn, doc: string)
	local entry = { fn = fn, doc = doc }
	functions[name] = entry
	greed.plugin.cleanup(function()
		if functions[name] == entry then
			functions[name] = nil
		end
	end)
end

--- The functions formulas may call, with what each is for, by name.
function M.functions(): { [string]: string }
	local out: { [string]: string } = {}
	for name, entry in functions do
		out[name] = entry.doc
	end
	return out
end

-- How `node` reads, to say which value something went wrong with.
local function named(node: Node): string
	return if node.k == "name" then `\`{node.v}\`` else "a value"
end

-- `value` as a number for arithmetic, text that reads as one too.
local function number(value: any, node: Node): number
	if type(value) == "number" then
		return value
	end
	local n = if type(value) == "string" then tonumber(value) else nil
	if n then
		return n
	end
	if value == nil then
		return fail(`{named(node)} is empty`)
	end
	return fail(`{named(node)} isn't a number`)
end

-- `value` as text for `..`.
local function text(value: any, node: Node): string
	if type(value) == "string" then
		return value
	elseif type(value) == "number" then
		return M.show(value)
	elseif value == nil then
		return fail(`{named(node)} is empty`)
	end
	return fail(`{named(node)} can't be joined as text`)
end

local ARITHMETIC: { [string]: (number, number) -> number } = {
	["+"] = function(a, b)
		return a + b
	end,
	["-"] = function(a, b)
		return a - b
	end,
	["*"] = function(a, b)
		return a * b
	end,
	["/"] = function(a, b)
		return a / b
	end,
	["//"] = function(a, b)
		return a // b
	end,
	["%"] = function(a, b)
		return a % b
	end,
	["^"] = function(a, b)
		return a ^ b
	end,
}

-- Compares `a` and `b` for `<` and the like: numbers, or text with text.
local function before(a: any, b: any, node: Node): (any, any)
	local x, y = tonumber(a), tonumber(b)
	if x and y then
		return x, y
	end
	if type(a) == "string" and type(b) == "string" then
		return a, b
	end
	return fail(`these can't be compared, at {node.at}`)
end

-- Works `node` out, looking names up with `lookup`.
local function work(node: Node, lookup: (string) -> any): any
	local k = node.k
	if k == "num" or k == "str" or k == "bool" then
		return node.v
	elseif k == "nil" then
		return nil
	elseif k == "name" then
		return lookup(node.v)
	elseif k == "index" then
		local value = work(node.a :: Node, lookup)
		local key = work(node.b :: Node, lookup)
		if type(value) ~= "table" then
			return fail(`{named(node.a :: Node)} has no {key}`)
		end
		return value[key]
	elseif k == "call" then
		local entry = functions[node.v]
		if entry == nil then
			return fail(`there's no function called {node.v}`)
		end
		local args = {}
		for i, arg in node.args :: { Node } do
			args[i] = work(arg, lookup)
		end
		local ok, value = pcall(entry.fn, table.unpack(args, 1, #(node.args :: { Node })))
		if not ok then
			return fail(`{node.v}: {if type(value) == "table" then value.formula else value}`)
		end
		return value
	elseif k == "un" then
		local value = work(node.a :: Node, lookup)
		if node.op == "not" then
			return not value
		elseif node.op == "#" then
			if type(value) == "string" or type(value) == "table" then
				return #value
			end
			return fail(`{named(node.a :: Node)} has no length`)
		end
		return -number(value, node.a :: Node)
	elseif k == "if" then
		for _, branch in node.branches :: { { Node } } do
			if work(branch[1], lookup) then
				return work(branch[2], lookup)
			end
		end
		return work(node.a :: Node, lookup)
	end
	-- Two sides and an operator between them.
	local op = node.op :: string
	local a, b = node.a :: Node, node.b :: Node
	if op == "and" then
		return work(a, lookup) and work(b, lookup)
	elseif op == "or" then
		return work(a, lookup) or work(b, lookup)
	end
	local x, y = work(a, lookup), work(b, lookup)
	if op == "==" then
		return x == y
	elseif op == "~=" then
		return x ~= y
	elseif op == ".." then
		local joined = text(x, a) .. text(y, b)
		if #joined > MAX_TEXT then
			return fail("the text it makes is too long")
		end
		return joined
	elseif ARITHMETIC[op] then
		return ARITHMETIC[op](number(x, a), number(y, b))
	end
	local l, r = before(x, y, node)
	if op == "<" then
		return l < r
	elseif op == ">" then
		return l > r
	elseif op == "<=" then
		return l <= r
	end
	return l >= r
end

--- Works `formula` out with names from `scope`: its value, or nil and
--- what went wrong, in words for whoever wrote it.
function M.eval(formula: Formula, scope: Scope): (any, string?)
	local lookup: (string) -> any = if type(scope) == "function"
		then scope
		else function(name: string): any
			return (scope :: { [string]: any })[name]
		end
	local ok, value = pcall(work, formula.node, lookup)
	if ok then
		return value, nil
	end
	return nil, if type(value) == "table" and value.formula then value.formula else tostring(value)
end

--- The names `formula` looks up, each once: for working out what it
--- depends on.
function M.names(formula: Formula): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	local function walk(node: Node?)
		if node == nil then
			return
		end
		if node.k == "name" and not seen[node.v] then
			seen[node.v] = true
			table.insert(out, node.v)
		end
		walk(node.a)
		walk(node.b)
		for _, arg in node.args or {} :: { Node } do
			walk(arg)
		end
		for _, branch in node.branches or {} :: { { Node } } do
			walk(branch[1])
			walk(branch[2])
		end
	end
	walk(formula.node)
	return out
end

--- `value` as it shows: a whole number as one, others to ten significant
--- digits (0.1 + 0.2 shows 0.3), lists joined with commas, nothing as "".
function M.show(value: any): string
	if type(value) == "number" then
		if value == math.floor(value) and math.abs(value) < 1e15 then
			return string.format("%d", value)
		end
		return string.format("%.10g", value)
	elseif type(value) == "table" then
		local parts: { string } = {}
		for _, item in ipairs(value) do
			table.insert(parts, M.show(item))
		end
		return table.concat(parts, ", ")
	elseif value == nil then
		return ""
	end
	return tostring(value)
end

-- The numbers in `list`, text that reads as one too; the rest left out.
local function numbers(list: any): { number }
	local out: { number } = {}
	if type(list) ~= "table" then
		return if tonumber(list) then { tonumber(list) :: number } else out
	end
	for _, item in ipairs(list) do
		local n = tonumber(item)
		if n then
			table.insert(out, n)
		end
	end
	return out
end

local function total(found: { number }): number
	local sum = 0
	for _, n in found do
		sum += n
	end
	return sum
end

-- The numbers in one list argument, or in all the arguments.
local function spread(...: any): { number }
	return numbers(if select("#", ...) == 1 then ... else { ... })
end

-- The built-in functions, as any plugin adds its own.
local BUILT_IN: { { name: string, fn: Fn, doc: string } } = {
	{
		name = "sum",
		doc = "The numbers in a list added up: sum(costs.amount)",
		fn = function(list)
			return total(numbers(list))
		end,
	},
	{
		name = "avg",
		doc = "The average of the numbers in a list, 0 for none",
		fn = function(list)
			local found = numbers(list)
			return if #found > 0 then total(found) / #found else 0
		end,
	},
	{
		name = "count",
		doc = "How many things a list has",
		fn = function(list)
			return if type(list) == "table" then #list else 0
		end,
	},
	{
		name = "min",
		doc = "The least of numbers, or of the numbers in a list",
		fn = function(...)
			local found = spread(...)
			return if #found > 0 then math.min(table.unpack(found)) else nil
		end,
	},
	{
		name = "max",
		doc = "The greatest of numbers, or of the numbers in a list",
		fn = function(...)
			local found = spread(...)
			return if #found > 0 then math.max(table.unpack(found)) else nil
		end,
	},
	{
		name = "round",
		doc = "A number rounded, to whole numbers or to `digits` decimals: round(x, 2)",
		fn = function(x, digits)
			local scale = 10 ^ math.clamp(tonumber(digits) or 0, 0, 12)
			return math.round((tonumber(x) or 0) * scale) / scale
		end,
	},
	{
		name = "floor",
		doc = "A number rounded down",
		fn = function(x)
			return math.floor(tonumber(x) or 0)
		end,
	},
	{
		name = "ceil",
		doc = "A number rounded up",
		fn = function(x)
			return math.ceil(tonumber(x) or 0)
		end,
	},
	{
		name = "abs",
		doc = "A number without its sign",
		fn = function(x)
			return math.abs(tonumber(x) or 0)
		end,
	},
	{
		name = "fixed",
		doc = "A number as text with `digits` decimals (2 unless said): fixed(total) shows 42.50",
		fn = function(x, digits)
			return string.format(`%.{math.clamp(tonumber(digits) or 2, 0, 12)}f`, tonumber(x) or 0)
		end,
	},
	{
		name = "upper",
		doc = "Text in capitals",
		fn = function(s)
			return string.upper(tostring(s or ""))
		end,
	},
	{
		name = "lower",
		doc = "Text in small letters",
		fn = function(s)
			return string.lower(tostring(s or ""))
		end,
	},
	{
		name = "empty",
		doc = "Whether a value is nothing or empty text",
		fn = function(x)
			return x == nil or x == ""
		end,
	},
}

for _, built in BUILT_IN do
	functions[built.name] = { fn = built.fn, doc = built.doc }
end

return M
