local test = require("@kern/test")

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
