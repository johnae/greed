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

-- The mail as it is now, a fresh copy of MAIL for each test (`fake`).
local now: { Fake } = {}

-- What was asked of the fake, as "action key".
local acted: { string } = {}

-- What was sent through the fake.
local sent: { any } = {}

-- An index of the mail now, in memory: the query run by
-- greed.query.run, sorted newest first as the list asks.
local index = {
	search = function(
		_,
		query: any,
		schema: greed.QuerySchema,
		view: any
	): ({ string }?, { string }?, string?)
		local rows: { greed.QueryRow } = {}
		for _, m in now do
			local fields: { [string]: string | { string } } =
				{ from = m.from, subject = m.subject, date = m.date, tag = m.tags }
			table.insert(rows, { text = `{m.subject}\n{m.text}`, fields = fields, flags = m.flags })
		end
		local matched = greed.query.run(query, rows, schema)
		local found: { number } = matched or {}
		local hits: { Fake } = {}
		for _, i in found do
			table.insert(hits, now[i])
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
		flagged = table.find(m.flags, "flagged") ~= nil,
	}
end

-- Sets (`on`) or clears `flag` on `m`.
local function flag(m: Fake, name: string, on: boolean)
	local i = table.find(m.flags, name)
	if on and i == nil then
		table.insert(m.flags, name)
	elseif not on and i then
		table.remove(m.flags, i)
	end
end

-- What the fake does for each action greed-mail takes.
local ACTIONS: { [string]: (m: Fake) -> () } = {
	read = function(m)
		flag(m, "unread", false)
	end,
	unread = function(m)
		flag(m, "unread", true)
	end,
	flag = function(m)
		flag(m, "flagged", true)
	end,
	unflag = function(m)
		flag(m, "flagged", false)
	end,
	archive = function(m)
		m.tags = { "Archive" }
	end,
	trash = function(m)
		m.tags = { "Trash" }
	end,
}

local function fake()
	now = {}
	for _, m in MAIL do
		local copy = table.clone(m)
		copy.flags = table.clone(m.flags)
		copy.tags = table.clone(m.tags)
		table.insert(now, copy)
	end
	acted = {}
	sent = {}
	local changed: () -> () = function() end
	changed = mail.backend.use({
		index = function(): (any, string?)
			return index
		end,
		summaries = function(keys: { string }): (any, string?)
			local out = {}
			for _, key in keys do
				for _, m in now do
					if m.key == key then
						table.insert(out, summary(m))
					end
				end
			end
			return out
		end,
		thread = function(key: string): (any, string?)
			for _, m in now do
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
		draft = function(key: string, all: boolean): (any, string?)
			for _, m in now do
				if m.key == key then
					return {
						to = m.from,
						cc = if all then "carl@example.com" else "",
						bcc = "",
						subject = `Re: {m.subject}`,
						text = `\n\n{m.from} wrote:\n> {m.text}\n`,
						replying = key,
					}
				end
			end
			return nil, "that mail is gone"
		end,
		send = function(draft: any): (boolean, string?)
			table.insert(sent, draft)
			return true, nil
		end,
		act = function(keys: { string }, action: string): (number?, string?)
			for _, key in keys do
				table.insert(acted, `{action} {key}`)
				for _, m in now do
					if m.key == key or m.thread == key then
						ACTIONS[action](m)
					end
				end
			end
			changed()
			return #keys, nil
		end,
	})
end

-- As in the mail session, for `body`.
local function in_the_mail_session(body: () -> ())
	local here = mail.backend.here
	mail.backend.here = function(): boolean
		return true
	end
	local ok, err: any = pcall(body)
	mail.backend.here = here
	assert(ok, tostring(err))
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
	in_the_mail_session(function()
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
	end)
end)

test("reading a thread in the mail session marks it read", function(t)
	fake()
	in_the_mail_session(function()
		t:buffer("|x")
		t:run("mail")
		t:keys("esc j enter")
		assert(table.concat(acted, ", ") == "read t:1:a", table.concat(acted, ", "))
		t:keys("q")
		assert(mail.shown()[2].unread == false, "the list says so")
	end)
end)

test("a quick look reads without marking read", function(t)
	fake()
	t:buffer("|x")
	t:run("mail")
	t:keys("esc j enter")
	assert(#acted == 0, table.concat(acted, ", "))
end)

test("u, s, e and d change the message under the cursor", function(t)
	fake()
	in_the_mail_session(function()
		t:buffer("|x")
		t:run("mail")
		t:keys("esc u")
		assert(mail.shown()[1].unread, "Invoice 41 unread now")
		t:keys("u s")
		assert(not mail.shown()[1].unread and mail.shown()[1].flagged)
		t:keys("e")
		assert(table.concat(subjects(), ", ") == "Garden plans", "archived: out of the inbox")
		t:keys("d")
		assert(#mail.shown() == 0, "trashed")
		assert(
			table.concat(acted, ", ")
				== "unread m:1:b, read m:1:b, flag m:1:b, archive m:1:b, trash m:1:a",
			table.concat(acted, ", ")
		)
	end)
end)

test("archiving the thread being read goes back to the list", function(t)
	fake()
	in_the_mail_session(function()
		t:buffer("|x")
		local window = greed.view()
		t:run("mail")
		t:keys("esc enter e")
		assert(window:buffer():kind() == "mail", "back in the list")
		assert(table.concat(subjects(), ", ") == "Garden plans")
	end)
end)

test("r writes a reply quoting the message, and :mail-send sends it", function(t)
	fake()
	in_the_mail_session(function()
		t:buffer("|x")
		local window = greed.view()
		t:run("mail")
		t:keys("esc r")
		local buffer = window:buffer()
		assert(buffer:kind() == "mail-compose", buffer:kind())
		local text = buffer:text()
		local head = "To: Anna Berg <anna@example.com>\nCc: \nSubject: Re: Invoice 41\n\n"
		assert(string.sub(text, 1, #head) == head, text)
		assert(string.find(text, "> please pay by Friday", 1, true), text)
		local at = window:cursor()
		assert(at == buffer:line_start(4), "the cursor where the text goes")
		buffer:edit(function(e)
			e:replace(at, at, "Paid.")
		end)
		t:run("mail-send")
		assert(#sent == 1)
		assert(sent[1].replying == "m:1:b" and sent[1].subject == "Re: Invoice 41")
		assert(string.sub(sent[1].text, 1, 7) == "Paid.\n\n", sent[1].text)
		assert(window:buffer():kind() == "mail", "back in the list")
	end)
end)

test("a reads a reply to all; c writes new mail from To", function(t)
	fake()
	in_the_mail_session(function()
		t:buffer("|x")
		local window = greed.view()
		t:run("mail")
		t:keys("esc a")
		assert(string.find(window:buffer():text(), "Cc: carl@example.com\n", 1, true) ~= nil)
		t:run("mail-close")
		assert(window:buffer():kind() == "mail", "dropped, back in the list")
		t:keys("c")
		assert(window:buffer():text() == "To: \nCc: \nSubject: \n\n")
		assert(window:cursor() == 4, "on To")
	end)
end)

test("mail is written in the mail session only", function(t)
	fake()
	t:buffer("|x")
	t:run("mail")
	t:keys("esc c")
	assert(greed.view():buffer():kind() == "mail", greed.view():buffer():kind())
end)

test("a draft reads from its header lines and text", function()
	local draft = mail.parse_draft(
		"to: anna@x, bob@x\nBCC: me@x\nSubject:  Hi \nX-Other: y\n\nHello\n\nthere\n"
	)
	assert(draft.to == "anna@x, bob@x" and draft.bcc == "me@x" and draft.cc == "")
	assert(draft.subject == "Hi")
	assert(draft.text == "Hello\n\nthere\n", draft.text)
	assert(mail.parse_draft("To: anna@x").to == "anna@x", "no text yet")
end)
