local test = require("@greed/test")
local core = require("@core")
local query = core.query

-- The canonical form `text` reads as, or its problems.
local function reads(text: string, opts: { typing: boolean? }?): string
	local parsed = query.parse(text, opts)
	if not parsed.ok then
		local said: { string } = {}
		for _, p in parsed.problems do
			if not p.hint then
				table.insert(said, `{p.at.from}-{p.at.to}: {p.message}`)
			end
		end
		return "error " .. table.concat(said, "; ")
	end
	return query.print(parsed)
end

local function check(cases: { { string } })
	for _, case in cases do
		local got = reads(case[1])
		assert(got == case[2], `{case[1]}: {got}`)
	end
end

test("words, phrases and fields read back in one canonical form", function()
	check({
		{ "invoice", "invoice" },
		{ '"quarterly report"  budget*', '"quarterly report" budget*' },
		{ "from:anna is:unread", "from:anna is:unread" },
		{ 'from:"Joe Bloggs"', 'from:"Joe Bloggs"' },
		{ "size>1M took>=1.5s level>=warn", "size>1M took>=1.5s level>=warn" },
		{ "created:>2026-01-01", "created>2026-01-01" },
		{
			"STATUS=Running msg~timeout name!=api level!~debug",
			"STATUS=Running msg~timeout name!=api level!~debug",
		},
		{ "date:2w.. due:..eow due:-7d..+7d", "date:2w.. due:..eow due:-7d..+7d" },
		{ "subject:/h.llo/ /^error|warn/", "subject:/h.llo/ /^error|warn/" },
		{ "", "" },
	})
end)

test("a space is AND; OR binds tighter; parentheses group", function()
	check({
		{ "a b AND c", "a b c" },
		{ "a b OR c", "a b OR c" },
		{ "(a b) OR c", "(a b) OR c" },
		{ "a (b OR c)", "a b OR c" },
		{ "tag:(garden OR kitchen)", "tag:(garden OR kitchen)" },
		{ "((a))", "a" },
	})
	local parsed = query.parse("a b OR c")
	local q = parsed.query :: core.QueryNode
	assert(q.kind == "and" and #(q.items :: { core.QueryNode }) == 2, "a AND (b OR c)")
	assert((q.items :: { core.QueryNode })[2].kind == "or")
end)

test("- and NOT negate, also first and in front of groups and phrases", function()
	check({
		{ "-from:noreply", "-from:noreply" },
		{ "NOT is:done", "-is:done" },
		{ '-"out of office"', '-"out of office"' },
		{ "-(a b)", "-(a b)" },
		{ "-(a OR b) c", "-(a OR b) c" },
	})
end)

test("hierarchy takes a name or a subquery", function()
	check({
		{ "in:inbox", "in:inbox" },
		{ "in:(tag:garden) is:todo", "in:(tag:garden) is:todo" },
		{ "has:(is:todo -is:done)", "has:(is:todo -is:done)" },
	})
	local q = query.parse("in:(tag:garden)").query :: core.QueryNode
	assert(q.kind == "field" and q.field == "in", q.kind)
	assert((q.items :: { core.QueryNode })[1].field == "tag", "the subquery")
end)

test("spaces around an operator are allowed, as where takes them", function()
	check({
		{ "AGE < 1h", "AGE<1h" },
		{ 'STATUS = "Crash Loop"', 'STATUS="Crash Loop"' },
	})
end)

test("sort, limit, group and show say how results show", function()
	check({
		{
			"is:todo sort:due,-date limit:20 group:note",
			"is:todo sort:due,-date limit:20 group:note",
		},
		{ "show:from,subject from:anna", "from:anna show:from,subject" },
		{ "sort:-date", "sort:-date" },
	})
	local parsed = query.parse("x sort:-date limit:5")
	assert(parsed.view.sort[1].field == "date" and parsed.view.sort[1].descending)
	assert(parsed.view.limit == 5)
end)

test("mistakes say what's wrong and where", function()
	check({
		{ "a (b", "error 3-3: a ( without its )" },
		{ "a b)", "error 4-4: a ) without its (" },
		{ '"open', 'error 1-1: a " without its closing one' },
		{ "from:", "error 1-5: from: needs a value right after it, like from:something" },
		{ "OR a", "error 1-2: OR needs something before it" },
		{ "a OR", "error 3-4: OR needs something after it" },
		{ "a -", "error 3-3: NOT or - needs something after it" },
		{ "date:..", "error 1-7: a range needs an end, like date:2w.. or date:..today" },
		{ "limit:many", "error 1-10: limit: needs a whole number, like limit:20" },
		{
			"a OR sort:due",
			"error 6-13: sort: says how results show, so it can't go inside OR, NOT or ( )",
		},
		{ "((((((a))))))", "error 6-6: ( ) nest at most 5 deep" },
		{ "* a", "error 1-1: a * goes at the end of a word, to find words starting with it" },
	})
end)

test("a lowercase or, and or not between words is searched for, with a hint", function()
	local parsed = query.parse("cats or dogs")
	assert(parsed.ok, "it still runs")
	assert(query.print(parsed) == "cats or dogs", query.print(parsed))
	local hint = parsed.problems[1]
	assert(
		hint and hint.hint and hint.message == 'searching for the word "or"; did you mean OR?',
		hint and hint.message
	)
	assert(hint.at.from == 6 and hint.at.to == 7)
	assert(#query.parse("or else").problems == 0, "first, it's just a word")
end)

test("while typing, the word at the end matches by prefix until it's settled", function()
	local live = query.parse("from:anna invo", { typing = true }).query :: core.QueryNode
	local word = (live.items :: { core.QueryNode })[2]
	assert(word.prefix and word.live, "invo* while it's typed")
	assert(
		reads("from:anna invo", { typing = true }) == "from:anna invo",
		"printed as typed, without the *"
	)
	local settled = query.parse("from:anna invo ", { typing = true }).query :: core.QueryNode
	assert(not (settled.items :: { core.QueryNode })[2].prefix, "a space settles it")
	local starred = query.parse("invo*", { typing = true }).query :: core.QueryNode
	assert(starred.prefix and not starred.live, "a typed * keeps the prefix")
	local value = query.parse("tag:gar", { typing = true }).query :: core.QueryNode
	assert(value.prefix and value.live, "a field's value too")
	assert(not query.parse('"exact phr', { typing = true }).ok, "an open quote is still a mistake")
end)

test("what print writes parses back to the same thing", function()
	local cases = {
		'from:anna "two words" -is:done (a OR b) c',
		"in:(tag:garden OR tag:kitchen) has:(is:todo -is:done) sort:due",
		'subject:"a:b" "a..b" "OR" "-dash" "star*"',
		"x y OR z -(p q) date:2026-10..",
	}
	for _, text in cases do
		local once = query.print(query.parse(text))
		local twice = query.print(query.parse(once))
		assert(once == twice, `{text}: {once} then {twice}`)
	end
end)

-- The cases every engine must agree on (query_cases.json), as items in
-- memory: each with its text, fields, flags, and the item it's in.
test("the shared cases: what every engine running a query must agree on", function()
	local greed = require("@greed")
	local dates = core.dates
	local text = greed.fs.read(`{greed.plugin.dirs().core}/test/query_cases.json`)
	local cases = greed.json.decode(text :: string)
	local by_id: { [string]: any } = {}
	for _, item in cases.items do
		by_id[item.id] = item
	end
	local fields: { [string]: core.QueryField } = {}
	for name, field in cases.fields do
		fields[name] = {
			kind = field.kind,
			ahead = field.ahead,
			get = function(item: any): any
				return item.fields[name]
			end,
		}
	end
	local flags: { [string]: (item: any) -> boolean } = {}
	for _, flag in cases.flags do
		flags[flag] = function(item: any): boolean
			return table.find(item.flags, flag) ~= nil
		end
	end
	local source: core.QuerySource = {
		fields = fields,
		flags = flags,
		text = function(item: any): string
			return item.text
		end,
		parent = function(item: any): any
			return item.parent and by_id[item.parent]
		end,
		children = function(item: any): { any }
			local out = {}
			for _, other in cases.items do
				if other.parent == item.id then
					table.insert(out, other)
				end
			end
			return out
		end,
		name = function(item: any): string?
			return item.name
		end,
	}
	local y, m, d = string.match(cases.today, "^(%d+)-(%d+)-(%d+)$")
	local clock = dates.clock
	dates.clock = function(): number
		return os.time(
			{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 } :: any
		)
	end
	local ok, err = pcall(function()
		for _, case in cases.cases do
			local parsed = query.parse(case.query)
			local problems = query.check(parsed, source)
			for _, p in parsed.problems do
				if not p.hint then
					table.insert(problems, p)
				end
			end
			if case.problem then
				local said: { string } = {}
				for _, p in problems do
					table.insert(said, p.message)
				end
				local all = table.concat(said, "; ")
				assert(
					string.find(all, case.problem, 1, true),
					`{case.query}: wanted "{case.problem}", got "{all}"`
				)
			else
				assert(#problems == 0, `{case.query}: {problems[1] and problems[1].message}`)
				local ids: { string } = {}
				local found, why = query.run(parsed, cases.items, source)
				assert(found, `{case.query}: {why}`)
				for _, item in found do
					table.insert(ids, item.id)
				end
				local got, want = table.concat(ids, " "), table.concat(case.ids, " ")
				assert(got == want, `{case.query}: wanted [{want}], got [{got}]`)
			end
		end
	end)
	dates.clock = clock
	assert(ok, tostring(err))
end)
