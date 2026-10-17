-- Brackets and quotes typed in pairs: on in the helix and vscode styles,
-- off in vim's, as each editor does; the auto-pairs option says otherwise.

local test = require("@greed/test")
local greed = require("@greed")

local function check(t: test.TestContext, before: string, keys: string, after: string)
	t:buffer(before)
	t:keys(keys)
	t:expect(after)
end

test("an opening bracket brings its closer, and the cursor goes between", function(t)
	check(t, "|", "i (", "(|)")
	check(t, "|", "i [", "[|]")
	check(t, "|", "i {", "{|}")
	check(t, "a |b", "i (", "a (|b")
	check(t, "f(|)", "i [", "f([|])")
	check(t, "x| y", "i {", "x{|} y")
end)

test("typing the closer next to it steps over it", function(t)
	check(t, "|", "i ( )", "()|")
	check(t, "|", "i ( a )", "(a)|")
	check(t, "f(|)", "i )", "f()|")
end)

test("quotes pair too, except after a letter or digit", function(t)
	check(t, "|", 'i "', '"|"')
	check(t, "|", 'i " "', '""|')
	check(t, "don|", "i '", "don'|")
	check(t, "x = |", "i ' a '", "x = 'a'|")
end)

test("backspace between an empty pair takes both", function(t)
	check(t, "|", "i ( backspace", "|")
	check(t, "(|)", "i backspace", "|")
	check(t, "(|x)", "i backspace", "|x)")
	check(t, "|", "i ( a backspace backspace", "|")
end)

test("every cursor gets its pair", function(t)
	check(t, "a|\nb|", "i (", "a(|)\nb(|)")
	check(t, "a|\nb|", "i ( )", "a()|\nb()|")
end)

test("a language can have pairs of its own", function(t)
	local core = require("@core")
	core.pairs.set("pairs-test", { ["<"] = ">" })
	t:buffer("|")
	greed.view():buffer():set_language("pairs-test")
	t:keys("i < (")
	t:expect("<(|>")
	core.pairs.set("pairs-test", nil)
end)

test("auto-pairs off stops pairing, and style leaves it to the style again", function(t)
	greed.option.set("auto-pairs", "off")
	check(t, "|", "i (", "(|")
	greed.option.set("auto-pairs", "style")
	check(t, "|", "i (", "(|)")
end)

test("one undo takes a pair back", function(t)
	check(t, "|", "i ( a esc u", "|")
end)
