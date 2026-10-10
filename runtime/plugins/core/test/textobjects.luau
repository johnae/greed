local test = require("@greed/test")
local greed = require("@greed")

local function check(t: test.TestContext, before: string, keys: string, after: string)
	t:buffer(before)
	t:keys(keys)
	t:expect(after)
end

test("m i w and m a w select the word, with or without the space after it", function(t)
	check(t, "one t|wo three", "m i w", "one ^two| three")
	check(t, "one t|wo three", "m a w", "one ^two |three")
	check(t, "one a.|b c", "m i W", "one ^a.b| c")
	check(t, "f|oo(bar, baz)", "m i w", "^foo|(bar, baz)")
	check(t, "f|oo(bar, baz)", "m i W", "^foo(bar,| baz)")
end)

test("m i and m a with a bracket select inside or around the pair", function(t)
	check(t, "f(a, [b|], c)", "m i (", "f(^a, [b], c|)")
	check(t, "f(a, [b|], c)", "m a )", "f^(a, [b], c)|")
	check(t, "f(a, [b|], c)", "m i [", "f(a, [^b|], c)")
	check(t, "{ x| }", "m i {", "{^ x |}")
end)

test("m i and m a with a quote select inside or around it on the line", function(t)
	check(t, [[say "hel|lo" now]], [[m i "]], [[say "^hello|" now]])
	check(t, [[say 'hel|lo' now]], "m a '", [[say ^'hello'| now]])
end)

test("m s wraps each selection, m d unwraps, m r swaps the pair", function(t)
	check(t, "a ^bc| d", "m s (", "a ^(bc)| d")
	check(t, "a (b|c) d", "m d (", "a b|c d")
	check(t, [[a "b|c" d]], [[m r " ']], "a 'b|c' d")
end)

test("a count picks brackets further out", function(t)
	check(t, "f(a, (b|), c)", "2 m i (", "f(^a, (b), c|)")
	check(t, "f((a)(b|))", "2 m a (", "f^((a)(b))|")
	check(t, "(a|)", "2 m i (", "(a|)")
end)

test("m i m and m a m take the nearest brackets or quotes of any kind", function(t)
	check(t, [[f("a|b", [c])]], "m i m", [[f("^ab|", [c])]])
	check(t, "f([c|])", "m a m", "f(^[c]|)")
end)

test("m i x and m a x take an XML or HTML element", function(t)
	check(t, "<a><b>x|y</b></a>", "m i x", "<a><b>^xy|</b></a>")
	check(t, "<a><b>x|y</b></a>", "m a x", "<a>^<b>xy</b>|</a>")
end)

test("m i n and m i l take the next or last pair; m a l with the brackets", function(t)
	t:buffer("f(|a) g(b) h(c)")
	t:keys("m i n (")
	t:expect("f(a) g(^b|) h(c)")
	t:buffer("f(a) g(b) h|(c)")
	t:keys("m a l (")
	t:expect("f(a) g^(b)| h(c)")
	t:buffer('|x = "a" .. "b"')
	t:keys('m i n "')
	t:expect('x = "^a|" .. "b"')
end)

test("m i i takes the lines indented as far, m a i the line above too", function(t)
	t:buffer("if x:\n  a\n  |b\n\n  c\nd")
	t:keys("m i i")
	t:expect("if x:\n^  a\n  b\n\n  c\n|d")
	t:buffer("if x:\n  a\n  |b\nd")
	t:keys("m a i")
	t:expect("^if x:\n  a\n  b\n|d")
end)

test("m i d takes the number at or after the cursor, m a d with its sign", function(t)
	t:buffer("|x = -12.5 + 3")
	t:keys("m i d")
	t:expect("x = -^12.5| + 3")
	t:buffer("|x = -0x1f")
	t:keys("m a d")
	t:expect("x = ^-0x1f|")
end)

-- `core.textobjects.find` on `before` (| is the cursor): the text it picks.
local function found(
	t: test.TestContext,
	before: string,
	key: string,
	around: boolean,
	vim: boolean?
): string?
	t:buffer(before)
	local buffer = greed.view():buffer()
	local from, to =
		require("@core").textobjects.find(buffer, greed.view():cursor(), key, around, { vim = vim })
	return if from and to then buffer:slice(from, to) else nil
end

test("find picks every style's objects, Vim's way where it differs", function(t)
	assert(
		found(t, "one tw|o", "w", true) == " two",
		"a word at a line's end takes the space before"
	)
	assert(found(t, "one tw|o three", "w", true) == "two ")
	-- Quotes after the cursor on its line count in Vim only.
	assert(found(t, '|x = "a"', '"', false) == nil)
	assert(found(t, '|x = "a"', '"', false, true) == "a")
	-- A paragraph: its lines, or whole lines in Vim; at the end of the
	-- buffer Vim takes the line break before them.
	assert(found(t, "a\n\nb|\nc", "p", false) == "b\nc")
	assert(found(t, "a\n\nb|\nc", "p", false, true) == "\nb\nc")
	assert(found(t, "a|\nb\n\nc", "p", true) == "a\nb\n\n")
	-- On blank lines, Vim's "a paragraph" takes the next one too.
	assert(found(t, "a\n|\nb\n", "p", true) == "\n")
	assert(found(t, "a\n|\nb\n", "p", true, true) == "\nb\n")
	assert(found(t, "One. Tw|o. Three.", "s", true) == "Two. ")
	assert(found(t, "f(a|)", "z", false) == nil, "an unknown key finds nothing")
end)

test("pair gives what surround wraps in, spaced inside for Vim's opening brackets", function()
	local function wraps(char: string, spaced: boolean?): string
		local open, close = require("@core").textobjects.pair(char, spaced)
		return open .. "x" .. close
	end
	assert(wraps("(") == "(x)")
	assert(wraps("(", true) == "( x )")
	assert(wraps(")", true) == "(x)")
	assert(wraps("<", true) == "<x>")
	assert(wraps("*", true) == "*x*")
end)
