local test = require("@greed/test")
local core = require("@core")
local greed = require("@greed")

type Mail = { from: string, tag: string, unread: boolean, text: string }

local MAIL: { Mail } = {
	{ from = "anna", tag = "work", unread = true, text = "the invoice" },
	{ from = "anna", tag = "home", unread = false, text = "garden plans" },
	{ from = "bob", tag = "work", unread = true, text = "a receipt" },
}

local SOURCE: core.QuerySource = {
	fields = {
		from = {
			kind = "exact",
			get = function(m: Mail): string?
				return m.from
			end,
		},
		tag = {
			kind = "exact",
			get = function(m: Mail): string?
				return m.tag
			end,
		},
	},
	flags = {
		unread = function(m: Mail): boolean
			return m.unread
		end,
	},
	text = function(m: Mail): string
		return m.text
	end,
	parent = function(): any
		return nil
	end,
	names = function(): { string }
		return { "Inbox", "Göteborg" }
	end,
}

-- Opens a box over MAIL, counting its results; gives what's submitted.
local function open(t: test.TestContext, extra: { [string]: any }?): { text: string? }
	t:buffer("|x")
	local got: { text: string? } = {}
	local options: core.SearchBoxOptions = {
		title = "Search",
		source = SOURCE,
		history = "test",
		values = function(field: string): { string }
			return if field == "from" then { "anna", "bob" } else {}
		end,
		count = function(parsed: core.Query): (number?, string?)
			local found = core.query.run(parsed, MAIL, SOURCE)
			return if found then #found else nil, nil
		end,
		on_submit = function(text: string)
			got.text = text
		end,
	}
	local given: { [string]: any } = extra or {}
	for key, value in given do
		(options :: any)[key] = value
	end
	core.search_box.open(options)
	return got
end

local function marks(): { greed.Mark }
	return greed.view():buffer():decorations("search-box")
end

local function title(): string
	return tostring(assert(greed.view():float_spec()).title)
end

test("a search box shows the query in colours, and a * after the word being typed", function(t)
	open(t)
	t:keys("f r o m : a n")
	local field, star = false, false
	for _, mark in marks() do
		if mark.style == "attribute" and mark.from == 0 and mark.to == 4 then
			field = true
		elseif mark.text == "*" and mark.from == #"from:an" then
			star = true
		end
	end
	assert(field, "from in a field's colour")
	assert(star, "a dimmed * after what's typed")
	assert(string.find(title(), "2 results", 1, true), title())
	t:keys("space")
	for _, mark in marks() do
		assert(mark.text ~= "*", "a space settles the word")
	end
end)

test("what's wrong is underlined and said after the query", function(t)
	open(t)
	t:keys("f r m : x")
	local underlined, said = false, nil
	for _, mark in marks() do
		if mark.style == "diagnostic.error" and mark.from == 0 then
			underlined = true
		elseif mark.eol then
			said = mark.text
		end
	end
	assert(underlined, "the term is underlined")
	assert(said and string.find(said, "did you mean from", 1, true), tostring(said))
	assert(title() == "Search", "no count while it's wrong: " .. title())
end)

test("with no results, the title says which term leaves the most out", function(t)
	open(t)
	t:keys("f r o m : a n n a space t a g : n o n e space")
	assert(string.find(title(), "0 results · 2 without tag:none", 1, true), title())
	t:keys(
		"backspace backspace backspace backspace backspace backspace backspace backspace backspace"
	)
	t:keys("i s : u n r e a d space")
	assert(string.find(title(), "1 result ", 1, true), title())
end)

test("tab completes fields, flags and a field's values", function(t)
	open(t)
	t:keys("f r tab")
	assert(greed.view():buffer():text() == "from:", greed.view():buffer():text())
	t:keys("b tab")
	assert(greed.view():buffer():text() == "from:bob", greed.view():buffer():text())
	t:keys("space - u n r tab")
	assert(greed.view():buffer():text() == "from:bob -is:unread", greed.view():buffer():text())
end)

test("tab after in: completes the names there are, and a name that isn't one says so", function(t)
	open(t)
	t:keys("i n : g o t tab")
	assert(greed.view():buffer():text() == "in:Göteborg", greed.view():buffer():text())
	t:keys("esc")
	open(t)
	t:keys("i n : n o w h e r e space")
	local said: string? = nil
	for _, mark in marks() do
		if mark.eol then
			said = mark.text
		end
	end
	assert(said and string.find(said, "nothing here is named nowhere", 1, true), tostring(said))
end)

test("up brings back queries submitted in boxes of the same history", function(t)
	local got = open(t)
	t:keys("a enter")
	assert(got.text == "a")
	open(t)
	t:keys("b enter")
	open(t)
	t:keys("up")
	assert(greed.view():buffer():text() == "b")
	t:keys("up")
	assert(greed.view():buffer():text() == "a")
	t:keys("down down")
	assert(greed.view():buffer():text() == "", "back to what was typed")
	t:keys("esc")
	open(t, { history = "other" })
	t:keys("up")
	assert(greed.view():buffer():text() == "", "another history has its own")
end)

test("with regex, a leading / makes the rest a regex", function(t)
	open(t, { regex = true, count = nil })
	t:keys("/ [ a")
	local said: string? = nil
	for _, mark in marks() do
		if mark.eol then
			said = mark.text
		end
	end
	assert(said and string.find(said, "regex", 1, true), tostring(said))
	local parsed = core.search_box.read("/^err", { regex = true })
	assert(parsed.ok and parsed.query and parsed.query.kind == "regex", "a regex query")
	assert(not core.search_box.read("/^err", {}).ok, "without, a query's regex needs its closing /")
end)
