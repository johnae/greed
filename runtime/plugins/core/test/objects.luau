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
