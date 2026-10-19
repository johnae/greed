local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")
local mail = require("@mail")

type Fake = {
	key: string,
	thread: string,
	from: string,
	subject: string,
	date: string,
	tags: { string },
	flags: { string },
	text: string,
}

local MAIL: { Fake } = {
	{
		key = "m:1:a",
		thread = "t:1:a",
		from = "Bob <bob@example.com>",
		subject = "Garden plans",
		date = "2026-10-18T09:00:00+02:00",
		tags = { "Inbox" },
		flags = { "unread" },
		text = "tomatoes by the fence",
	},
	{
		key = "m:1:b",
		thread = "t:1:b",
		from = "Anna Berg <anna@example.com>",
		subject = "Invoice 41",
		date = "2026-10-19T08:00:00+02:00",
		tags = { "Inbox", "Work" },
		flags = {},
		text = "please pay by Friday",
	},
	{
		key = "m:1:c",
		thread = "t:1:c",
		from = "Old <old@example.com>",
		subject = "Archived",
		date = "2025-01-01T00:00:00+01:00",
		tags = { "Archive" },
		flags = {},
		text = "long ago",
	},
}

-- An index of MAIL in memory: the query run by greed.query.run, sorted
-- newest first as the list asks.
local index = {
	search = function(
		_,
		query: any,
		schema: greed.QuerySchema,
		view: any
	): ({ string }?, { string }?, string?)
		local rows: { greed.QueryRow } = {}
		for _, m in MAIL do
			local fields: { [string]: string | { string } } =
				{ from = m.from, subject = m.subject, date = m.date, tag = m.tags }
			table.insert(rows, { text = `{m.subject}\n{m.text}`, fields = fields, flags = m.flags })
		end
		local matched = greed.query.run(query, rows, schema)
		local found: { number } = matched or {}
		local hits: { Fake } = {}
		for _, i in found do
			table.insert(hits, MAIL[i])
		end
		local by = view.sort[1]
		table.sort(hits, function(a: Fake, b: Fake): boolean
			if by and by.descending then
				return a.date > b.date
			end
			return a.date < b.date
		end)
		local keys: { string } = {}
		for _, m in hits do
			table.insert(keys, m.key)
		end
		return keys, {}, nil
	end,
}

local function summary(m: Fake): any
	return {
		key = m.key,
		thread = m.thread,
		from = m.from,
		subject = m.subject,
		date = m.date,
		unread = table.find(m.flags, "unread") ~= nil,
		flagged = false,
	}
end

local function fake()
	mail.backend.use({
		index = function(): (any, string?)
			return index
		end,
		summaries = function(keys: { string }): (any, string?)
			local out = {}
			for _, key in keys do
				for _, m in MAIL do
					if m.key == key then
						table.insert(out, summary(m))
					end
				end
			end
			return out
		end,
		thread = function(key: string): (any, string?)
			for _, m in MAIL do
				if m.key == key or m.thread == key then
					local message = summary(m)
					message.to = "anna@example.com"
					message.cc = ""
					message.text = m.text
					message.attachments = {}
					message.complete = true
					return { key = m.thread, subject = m.subject, messages = { message } }
				end
			end
			return nil
		end,
		sync = function() end,
	})
end

local function subjects(): { string }
	local out: { string } = {}
	for _, row in mail.shown() do
		table.insert(out, row.subject)
	end
	return out
end

test("mail opens on the inbox, newest first, with the search box over it", function(t)
	fake()
	t:buffer("|x")
	t:run("mail")
	assert(
		table.concat(subjects(), ", ") == "Invoice 41, Garden plans",
		table.concat(subjects(), ", ")
	)
	assert(greed.view():buffer():kind() == "search-box", "the search box has the cursor")
	assert(greed.view():buffer():text() == "in:inbox")
end)

test("what's typed narrows the list as it's typed", function(t)
	fake()
	t:buffer("|x")
	t:run("mail")
	t:keys("space i s : u n r e a d")
	assert(table.concat(subjects(), ", ") == "Garden plans", table.concat(subjects(), ", "))
	t:keys("esc")
	assert(greed.view():buffer():kind() == "mail", "back in the list")
	assert(table.concat(subjects(), ", ") == "Garden plans", "the list keeps what was found")
end)

test(
	"back in the list the cursor is on the first message; enter reads its thread, q goes back",
	function(t)
		fake()
		t:buffer("|x")
		t:run("mail")
		t:keys("esc")
		assert(greed.view():buffer():kind() == "mail")
		t:keys("enter")
		local thread = greed.view():buffer()
		assert(thread:kind() == "mail-thread", thread:kind())
		local text = thread:text()
		assert(string.find(text, "Invoice 41", 1, true), text)
		assert(string.find(text, "please pay by Friday", 1, true), text)
		t:keys("q")
		assert(greed.view():buffer():kind() == "mail", "back in the list")
	end
)

test("names and dates read as a list shows them", function()
	assert(mail.who("Anna Berg <anna@example.com>") == "Anna Berg")
	assert(mail.who('"Berg, Anna" <anna@example.com>') == "Berg, Anna")
	assert(mail.who("anna@example.com") == "anna@example.com")
	assert(
		mail.when("2020-03-04T10:00:00+01:00") == "4 Mar 2020",
		mail.when("2020-03-04T10:00:00+01:00")
	)
	assert(mail.when(core.dates.today() .. "T07:30:00+00:00") == "07:30")
end)

test("in the mail session the list and threads take the whole window, q goes back", function(t)
	fake()
	local here = mail.backend.here
	mail.backend.here = function(): boolean
		return true
	end
	t:buffer("|x")
	local window = greed.view()
	t:run("mail")
	t:keys("esc")
	assert(greed.view() == window, "the list is in the window, no float")
	assert(window:buffer():kind() == "mail")
	t:keys("enter")
	assert(window:buffer():kind() == "mail-thread", window:buffer():kind())
	t:keys("q")
	assert(window:buffer():kind() == "mail", "back in the list")
	t:keys("q")
	assert(window:buffer():kind() == "mail", "the page stays")
	mail.backend.here = here
end)
