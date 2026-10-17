-- Snippets: reading the syntax, and filling in their places with tab.

local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")

local snippet = core.snippet

-- Each place as "index:from-to", in the order read.
local function stops(parsed: any): string
	local out = {}
	for _, stop in parsed.stops do
		table.insert(out, `{stop.index}:{stop.from}-{stop.to}`)
	end
	return table.concat(out, " ")
end

test("a snippet reads as its text and its places", function()
	local parsed = snippet.parse("f(${1:x}, $2)$0")
	assert(parsed.text == "f(x, )", parsed.text)
	assert(stops(parsed) == "1:2-3 2:5-5 0:6-6", stops(parsed))
	local nested = snippet.parse("${1:a ${2:b}} \\$1 \\} ${3|one,two|}")
	assert(nested.text == "a b $1 } one", nested.text)
	assert(stops(nested) == "2:2-3 1:0-3 3:9-12", stops(nested))
	local choices = nested.stops[3].choices
	assert(choices and choices[2] == "two", "the choices")
end)

test("variables take their values, or the text given for when they have none", function()
	local values = { TM_FILENAME = "main.rs" } :: { [string]: string }
	local function var(name: string): string?
		return values[name]
	end
	local parsed = snippet.parse("$TM_FILENAME ${TM_FILENAME} ${NOPE:x$1} $NOPE", var)
	assert(parsed.text == "main.rs main.rs x NOPE", parsed.text)
	assert(stops(parsed) == "1:17-17", stops(parsed))
end)

-- Starts typing in an empty buffer and puts `body` in at the cursor.
local function expand(t: test.TestContext, before: string, body: string)
	t:buffer(before)
	t:keys("i")
	local view = greed.view()
	local at = view:cursor()
	snippet.expand(view, at, at, body)
end

test("tab goes through the places in order and ends at $0", function(t)
	greed.option.set("indent", "  ")
	expand(t, "|", "fn ${1:name}($2) {\n\t$0\n}")
	t:expect("fn ^name|() {\n  \n}")
	t:keys("r u n")
	t:expect("fn run|() {\n  \n}")
	t:keys("tab")
	t:expect("fn run(|) {\n  \n}")
	t:keys("x tab")
	t:expect("fn run(x) {\n  |\n}")
	assert(not snippet.active(greed.view()), "it ended at $0")
	t:keys("tab")
	t:expect("fn run(x) {\n    |\n}")
end)

test("shift-tab goes back to the place before", function(t)
	expand(t, "|", "${1:a} ${2:b}")
	t:keys("tab")
	t:expect("a ^b|")
	t:keys("shift-tab")
	t:expect("^a| b")
end)

test("the same number twice is filled in together", function(t)
	expand(t, "|", "let ${1:x} = 1; ${1:x}")
	t:keys("v a l")
	t:expect("let val| = 1; val|")
end)

test("lines go in at the indent of the line, and backspace takes a place whole", function(t)
	greed.option.set("indent", "  ")
	expand(t, "  |", "if ${1:cond} {\n\t$0\n}")
	t:expect("  if ^cond| {\n    \n  }")
	t:keys("backspace")
	t:expect("  if | {\n    \n  }")
end)

test("leaving the mode typed in ends the snippet", function(t)
	expand(t, "|", "${1:a} ${2:b}")
	t:keys("esc")
	assert(not snippet.active(greed.view()), "esc ended it")
end)

test("a snippet without places leaves the cursor at its end", function(t)
	expand(t, "x|", "yz")
	t:expect("xyz|")
	assert(not snippet.active(greed.view()))
end)

test("a completion that's a snippet goes in with its places", function(t)
	local lsp = require("@lsp")
	lsp.completion.source(function(view)
		if view:buffer():path() ~= nil then
			return nil
		end
		return { { label = "while", text = "while ${1:cond} {$0}", snippet = true } }
	end)
	t:buffer("|")
	t:keys("i w h")
	t:run("completion-ask")
	t:keys("enter")
	t:expect("while ^cond| {}")
	t:keys("x tab")
	t:expect("while x {|}")
end)
