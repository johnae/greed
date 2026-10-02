local test = require("@kern/test")
local kern = require("@kern")

kern.syntax.set_query(
	"rust",
	"textobjects",
	[[
(function_item body: (_) @function.inside) @function.around
(struct_item body: (_) @type.inside) @type.around
(parameters (_) @parameter.around)
(line_comment) @comment.around
]]
)

local function check(t: test.TestContext, before: string, keys: string, after: string)
	t:buffer(before)
	kern.view():buffer():set_language("rust")
	t:keys(keys)
	t:expect(after)
end

local TWO = "fn one(a: u8, b: u8) {\n    x|\n}\n\nfn two() {}\n"

test("m i f and m a f select inside or around the function", function(t)
	check(t, TWO, "m i f", "fn one(a: u8, b: u8) {^\n    x\n|}\n\nfn two() {}\n")
	check(t, TWO, "m a f", "^fn one(a: u8, b: u8) {\n    x\n}|\n\nfn two() {}\n")
	-- An empty body has nothing inside, so it takes the whole function.
	check(t, "fn e() {|}", "m i f", "^fn e() {}|")
	-- Outside any function, nothing changes.
	check(t, "|struct S;", "m a f", "|struct S;")
end)

test("m i a and m a a select a parameter, around with its comma", function(t)
	check(t, "fn f(a: u8, |b: u8) {}", "m i a", "fn f(a: u8, ^b: u8|) {}")
	check(t, "fn f(|a: u8, b: u8) {}", "m a a", "fn f(^a: u8, |b: u8) {}")
	-- The last one takes the comma before it.
	check(t, "fn f(a: u8, |b: u8) {}", "m a a", "fn f(a: u8^, b: u8|) {}")
end)

test("m a t and m a c select types and comments", function(t)
	check(t, "struct S { |a: u8 }", "m a t", "^struct S { a: u8 }|")
	check(t, "struct S { |a: u8 }", "m i t", "struct S {^ a: u8 |}")
	check(t, "// a |comment\nfn f() {}", "m a c", "^// a comment|\nfn f() {}")
end)

test("] f and [ f select the next and previous function", function(t)
	check(t, TWO, "] f", "fn one(a: u8, b: u8) {\n    x\n}\n\n^fn two() {}|\n")
	check(
		t,
		"fn one() {}\nfn two() {}\n|fn three() {}\n",
		"[ f",
		"fn one() {}\n^fn two() {}|\nfn three() {}\n"
	)
	-- Inside a function, the previous one to start is that function.
	check(t, "fn one() {}\nfn two() {|}\n", "[ f", "fn one() {}\n^fn two() {}|\n")
	-- Past the last one, nothing changes.
	check(t, "fn one() {}\n|\n", "] f", "fn one() {}\n|\n")
end)

test("alt-o grows the selection node by node and alt-i shrinks it back", function(t)
	check(t, "fn f() { g(a|b, c) }", "alt-o", "fn f() { g(^ab|, c) }")
	t:keys("alt-o")
	t:expect("fn f() { g^(ab, c)| }")
	t:keys("alt-o")
	t:expect("fn f() { ^g(ab, c)| }")
	t:keys("alt-i alt-i")
	t:expect("fn f() { g(^ab|, c) }")
	-- With nothing to go back to, it shrinks to the first node inside.
	check(t, "fn f() { ^g(ab, c)| }", "alt-i", "fn f() { ^g|(ab, c) }")
end)

test("buffers without a grammar or a query are left alone", function(t)
	t:buffer("fn one() {|}")
	t:keys("m a f alt-o")
	t:expect("fn one() {|}")
	-- A query without functions in it finds none.
	kern.syntax.set_query("rust", "textobjects", "(line_comment) @comment.around")
	check(t, "fn one() {|}", "m a f", "fn one() {|}")
end)
