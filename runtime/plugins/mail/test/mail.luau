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
	-- Its HTML, as greed-mail lays it out.
	html: any?,
	invite: any?,
	-- Messages of its thread before it, as greed-mail gives them.
	earlier: { any }?,
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
		html = {
			lines = {
				{ { text = "Tomatoes " }, { text = "by the fence", style = "strong" } },
				{},
				{ { text = "Read more", style = "link", link = 0 } },
			},
			links = { "https://example.com/garden" },
		},
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

-- Attachments asked for of the fake, as "key index to".
local fetched: { string } = {}

-- Invites answered through the fake, as "key answer".
local responded: { string } = {}

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
		-- As greed-mail sends it: a JSON array.
		tags = greed.json.array(table.clone(m.tags)),
		message_id = `{string.sub(m.key, -1)}@example.com`,
		attached = if m.key == "m:1:b" then 1 else 0,
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
local ACTIONS: { [string]: (m: Fake, tag: string?) -> () } = {
	tag = function(m, tag)
		table.insert(m.tags, tag or "")
	end,
	untag = function(m, tag)
		local i = table.find(m.tags, tag or "")
		if i then
			table.remove(m.tags, i)
		end
	end,
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

-- A copy of `mail` to change.
local function copy(mail: { Fake }): { Fake }
	local out: { Fake } = {}
	for _, m in mail do
		local one = table.clone(m)
		one.flags = table.clone(m.flags)
		one.tags = table.clone(m.tags)
		table.insert(out, one)
	end
	return out
end

-- The mail as it was before the last change, for the fake's undo.
local before: { Fake }? = nil
-- Whether the fake's undo takes back the mail sent last.
local sending = false
-- How the fake's account sends from its addresses, when a test says.
local identities: { { [string]: string } }? = nil

local function fake()
	now = copy(MAIL)
	before = nil
	sending = false
	identities = nil
	acted = {}
	sent = {}
	fetched = {}
	responded = {}
	local changed: () -> () = function() end
	changed = mail.backend.use({
		search = function(parsed: core.Query): ({ string }?, string?)
			local keys, _, why = core.query.search(index :: any, parsed, mail.source)
			return keys, why
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
					message.attachments = if m.key == "m:1:b"
						then { { name = "invoice-41.pdf", mime = "application/pdf", size = 20480 } }
						else {}
					message.complete = true
					message.html = m.html ~= nil
					message.invite = m.invite
					local messages = table.clone(m.earlier or {})
					table.insert(messages, message)
					return { key = m.thread, subject = m.subject, messages = messages }
				end
			end
			return nil
		end,
		find = function(id: string): (string?, string?)
			for _, m in now do
				if summary(m).message_id == id then
					return m.key, nil
				end
			end
			return nil, nil
		end,
		sync = function() end,
		accounts = function(): { any }
			return {
				{
					name = "home",
					address = "me@example.com",
					aliases = { "me@alias.example" },
					identities = identities,
				},
			}
		end,
		contacts = function(typed: string): { string }
			local out: { string } = {}
			for _, who in { "Anna Berg <anna@example.com>", "Bob <bob@example.com>" } do
				if string.find(string.lower(who), string.lower(typed), 1, true) then
					table.insert(out, who)
				end
			end
			return out
		end,
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
		render = function(key: string): any
			for _, m in now do
				if m.key == key then
					return m.html
				end
			end
			return nil
		end,
		attachment = function(key: string, index: number, to: string?): (string?, string?)
			table.insert(fetched, `{key} {index} {to or "-"}`)
			return to or `/kept/{key}/{index}`, nil
		end,
		browse = function(key: string): (string?, string?)
			return `/pages/{key}.html`, nil
		end,
		send = function(draft: any): (boolean, string?, number?)
			table.insert(sent, draft)
			before = nil
			sending = true
			return true, nil, 10
		end,
		respond = function(key: string, answer: string): (boolean, string?)
			table.insert(responded, `{key} {answer}`)
			return true, nil
		end,
		act = function(
			keys: { string },
			action: string,
			tag: string?,
			for_good: boolean?
		): (number?, string?, number?)
			local hits: { Fake } = {}
			for _, m in now do
				if table.find(keys, m.key) or table.find(keys, m.thread) then
					table.insert(hits, m)
				end
			end
			if action == "trash" and not for_good then
				local in_trash = 0
				for _, m in hits do
					in_trash += if table.find(m.tags, "Trash") then 1 else 0
				end
				if in_trash > 0 then
					return 0, nil, in_trash
				end
			end
			before = copy(now)
			for _, key in keys do
				table.insert(acted, if tag then `{action} {tag} {key}` else `{action} {key}`)
			end
			for _, m in hits do
				ACTIONS[action](m, tag)
			end
			changed()
			return #keys, nil, nil
		end,
		undo = function(): (string?, string?)
			if sending then
				sending = false
				table.remove(sent)
				return "sent", nil
			end
			if before == nil then
				return nil, "nothing to undo"
			end
			now = before :: { Fake }
			before = nil
			table.insert(acted, "undo")
			changed()
			return "changes", nil
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
	-- Ending in a space, so what's typed adds a word.
	assert(greed.view():buffer():text() == "in:inbox ", greed.view():buffer():text())
end)

test("what's typed narrows the list as it's typed", function(t)
	fake()
	t:buffer("|x")
	t:run("mail")
	t:keys("i s : u n r e a d")
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

test(
	"a quick look is one float of the tab: threads open in it, q goes back, :mail finds it",
	function(t)
		local panes = require("@panes")
		fake()
		t:buffer("|x")
		t:run("mail")
		t:keys("esc")
		local window = greed.view()
		assert(window:buffer():kind() == "mail", window:buffer():kind())
		assert(table.find(panes.floats.all(), window), "a float of the tab, which alt-f hides")
		t:keys("enter")
		assert(
			greed.view() == window and window:buffer():kind() == "mail-thread",
			"read in the same float"
		)
		t:keys("q")
		assert(window:buffer():kind() == "mail", "back in the list")
		t:run("mail")
		assert(#panes.floats.all() == 1, "still one mail float")
		assert(greed.view() == window, "the one there is comes to the front")
	end
)

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

test("a quick look marks what it reads read, and changes mail as the page does", function(t)
	fake()
	t:buffer("|x")
	t:run("mail")
	t:keys("esc j enter")
	assert(table.concat(acted, ", ") == "read t:1:a", table.concat(acted, ", "))
	t:keys("e")
	assert(acted[2] == "archive m:1:a", "the messages found: " .. tostring(acted[2]))
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

-- The names of the actions `space .` offers on the first thing at the cursor.
local function offered(window: greed.View): (core.Target?, { string })
	local target = core.actions.at(window)[1]
	local names: { string } = {}
	if target then
		for _, action in core.actions.for_kind(target.kind, target) do
			table.insert(names, action.name)
		end
	end
	table.sort(names)
	return target, names
end

test(
	"an agent is told what the mail you're in is: the list and its search, a thread, a draft",
	function(t)
		fake()
		in_the_mail_session(function()
			t:buffer("|x")
			local window = greed.view()
			t:run("mail")
			t:keys("esc")
			local list = core.about.of(window:buffer()) or ""
			assert(
				string.find(
					list,
					'^the mail list, searching "in:inbox" %(the saved search Inbox%), %d+ shown$'
				),
				list
			)
			t:keys("enter")
			local thread = core.about.of(window:buffer()) or ""
			assert(string.find(thread, "^a mail thread of %d+ messages?$"), thread)
			t:keys("r")
			assert(
				core.about.of(window:buffer()) == "mail the user is writing, which only they send"
			)
		end)
	end
)

test("space . acts on the mail under the cursor, the thread read and the draft written", function(t)
	fake()
	in_the_mail_session(function()
		t:buffer("|x")
		local window = greed.view()
		t:run("mail")
		t:keys("esc")
		local target, names = offered(window)
		assert(target and target.kind == "mail" and target.label == "Invoice 41", "the row")
		assert(table.find(names, "archive") and table.find(names, "read"), table.concat(names, " "))
		for _, action in core.actions.for_kind("mail", target) do
			if action.name == "archive" then
				core.actions.run(action, target :: core.Target)
			end
		end
		assert(acted[#acted] == "archive m:1:b", "as e does: " .. tostring(acted[#acted]))
		local row = offered(window)
		assert(row and core.actions.run_default(row), "enter reads it")
		assert(window:buffer():kind() == "mail-thread", window:buffer():kind())
		target, names = offered(window)
		assert(target and target.label == "Garden plans", "the thread")
		assert(not table.find(names, "read"), "read only from a list")
		t:keys("r")
		target, names = offered(window)
		assert(target and target.kind == "mail-draft", "the draft")
		for _, name in { "open", "send", "discard" } do
			assert(table.find(names, name), `{name}: {table.concat(names, " ")}`)
		end
		for _, action in core.actions.for_kind("mail-draft", target) do
			assert(action.name ~= "send" or action.danger, "an agent sending asks you")
		end
		assert(core.risk.of_editor_command("mail-send"), "an agent's :mail-send asks you too")
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
		local head =
			"From: me@example.com\nTo: Anna Berg <anna@example.com>\nCc: \nSubject: Re: Invoice 41\n\n"
		assert(string.sub(text, 1, #head) == head, text)
		assert(string.find(text, "> please pay by Friday", 1, true), text)
		local at = window:cursor()
		assert(at == buffer:line_start(5), "the cursor where the text goes")
		buffer:edit(function(e)
			e:replace(at, at, "Paid.")
		end)
		t:keys("i ctrl-enter")
		assert(#sent == 1, "ctrl-enter sends it, while typing too")
		assert(sent[1].replying == "m:1:b" and sent[1].subject == "Re: Invoice 41")
		assert(sent[1].markdown == true, "Markdown, as mail-markdown says by default")
		assert(string.sub(sent[1].text, 1, 7) == "Paid.\n\n", sent[1].text)
		assert(window:buffer():kind() == "mail", "back in the list")
	end)
end)

-- Types `text` where the cursor is in mail being written in `window`.
local function type_in(window: greed.View, text: string)
	local at = window:cursor()
	window:buffer():edit(function(e)
		e:replace(at, at, text)
	end)
end

test("mail being written is kept as a draft, which :mail-drafts writes again", function(t)
	fake()
	in_the_mail_session(function()
		t:buffer("|x")
		local window = greed.view()
		t:run("mail")
		t:keys("esc r")
		type_in(window, "Paid.")
		assert(#mail.drafts() == 0, "not before the typing stops")
		t:wait(1100)
		local kept = mail.drafts()
		assert(#kept == 1, "kept once it stops")
		assert(string.find(kept[1].kept.text, "Paid.", 1, true), kept[1].kept.text)
		assert(kept[1].kept.replying == "m:1:b", "with what it answers")
		-- Closed, as when the session ends.
		local compose = window:buffer()
		t:run("mail-close")
		assert(not compose:valid(), "closed")
		mail.open_draft(kept[1].path)
		local again = window:buffer()
		assert(again:kind() == "mail-compose", again:kind())
		assert(again:text() == kept[1].kept.text, again:text())
		t:run("mail-send")
		assert(#sent == 1 and sent[1].replying == "m:1:b", "it still answers it")
		assert(#mail.drafts() == 1, "kept while z can take it back")
		t:wait(16000)
		assert(#mail.drafts() == 0, "gone once it's sent")
	end)
end)

test("mail taken back with z is written again; :w keeps a draft at once", function(t)
	fake()
	in_the_mail_session(function()
		t:buffer("|x")
		local window = greed.view()
		t:run("mail")
		t:keys("esc c")
		type_in(window, "anna@example.com")
		t:run("save")
		assert(#mail.drafts() == 1, ":w kept it")
		t:run("mail-send")
		assert(window:buffer():kind() == "mail", "back in the list")
		t:run("mail-undo")
		assert(#sent == 0, "taken back")
		local buffer = window:buffer()
		assert(buffer:kind() == "mail-compose", "written again")
		assert(string.find(buffer:text(), "To: anna@example.com", 1, true), buffer:text())
		t:wait(16000)
		assert(#mail.drafts() == 1, "its draft stays")
		mail.discard_draft(mail.drafts()[1].path)
		assert(#mail.drafts() == 0, "discarded")
		assert(window:buffer():kind() == "mail", "and closed")
	end)
end)

test("mail goes out as its From's identity says: name, Reply-To, Bcc and signature", function(t)
	fake()
	local own: { [string]: string } = {
		address = "me@example.com",
		display_name = "Me Myself",
		signature = "Me\nexample.com",
		bcc = "me@example.com",
	}
	local alias: { [string]: string } =
		{ address = "me@alias.example", reply_to = "help@alias.example" }
	identities = { own, alias }
	in_the_mail_session(function()
		t:buffer("|x")
		local window = greed.view()
		t:run("mail")
		t:keys("esc c")
		local text = window:buffer():text()
		local new =
			"From: Me Myself <me@example.com>\nTo: \nCc: \nBcc: me@example.com\nSubject: \n\n\n\n-- \nMe\nexample.com\n"
		assert(text == new, text)
		t:run("mail-close")
		t:keys("r")
		text = window:buffer():text()
		local at = window:cursor()
		local before = string.find(text, "\n-- \nMe\nexample.com\n", 1, true)
		local quote = string.find(text, "> please pay by Friday", 1, true)
		assert(before and quote and before < quote, "the signature above the quote: " .. text)
		assert(at < (before :: number), "you write above it")
		type_in(window, "Paid.")
		t:run("mail-send")
		assert(sent[1].bcc == "me@example.com" and sent[1].from == "Me Myself <me@example.com>")
		-- An alias's own: its Reply-To, and nothing it doesn't say.
		local alias = mail.as_identity({
			from = "me@alias.example",
			to = "bob@example.com",
			cc = "",
			bcc = "",
			subject = "hi",
			text = "",
		})
		assert(alias.reply_to == "help@alias.example" and alias.bcc == "", "its own")
		assert(alias.text == "" and alias.from == "me@alias.example", "no name, no signature")
		assert(mail.as_identity({
			from = "x@other.example",
			to = "",
			cc = "",
			bcc = "",
			subject = "",
			text = "a",
		}).text == "a", "not yours: as it was")
	end)
end)

test("new mail is from mail.toml's from, and :mail-from changes who with its signature", function(t)
	fake()
	local own: { [string]: string } = { address = "me@example.com", signature = "Me" }
	local alias: { [string]: any } = {
		address = "me@alias.example",
		display_name = "Alias Desk",
		signature = "The desk",
		reply_to = "help@alias.example",
		default = true,
	}
	identities = { own, alias }
	in_the_mail_session(function()
		t:buffer("|x")
		local window = greed.view()
		t:run("mail")
		t:keys("esc c")
		local buffer = window:buffer()
		local text = buffer:text()
		assert(
			string.find(text, "^From: Alias Desk <me@alias%.example>\n"),
			"the default: " .. text
		)
		assert(string.find(text, "Reply-To: help@alias.example", 1, true), text)
		-- Where the text goes: past the header's blank line.
		window:set_cursor((string.find(text, "\n\n", 1, true) :: number) + 1)
		type_in(window, "Hello")
		t:run("mail-from")
		t:keys("m e @ e x a m p l e enter")
		text = buffer:text()
		assert(string.find(text, "^From: me@example%.com\n"), text)
		assert(not string.find(text, "Reply-To", 1, true), "the alias's Reply-To went: " .. text)
		assert(
			string.find(text, "\n\nHello\n\n-- \nMe\n", 1, true),
			"its signature in the other's place: " .. text
		)
		assert(not string.find(text, "The desk", 1, true), text)
		-- A signature edited by hand stays as it is.
		buffer:edit(function(e)
			local at = (string.find(buffer:text(), "-- \nMe", 1, true) :: number) + 3
			e:replace(at, at + 2, "Me, from my phone")
		end)
		t:run("mail-from")
		t:keys("D e s k enter")
		text = buffer:text()
		assert(string.find(text, "Me, from my phone", 1, true), "kept: " .. text)
		assert(
			not string.find(text, "The desk", 1, true),
			"and no second signature under it: " .. text
		)
		assert(string.find(text, "From: Alias Desk", 1, true), text)
	end)
end)

test("a greed-mail that speaks another protocol, or none, says what to rebuild", function(t)
	local dir = t:tempdir()
	-- Stand-ins for greed-mail: each answers the first request, by its id.
	local function stand_in(name: string, answer: string): string
		local path = `{dir}/{name}`
		greed.fs.write(
			path,
			"#!/bin/sh\n"
				.. `read line; id=$(printf '%s' "$line" | sed 's/.*"id":\\([0-9]*\\).*/\\1/'); `
				.. `printf '\{"jsonrpc":"2.0","id":%s,{answer}\}\\n' "$id"; sleep 5\n`
		)
		greed.process.run({ "chmod", "+x", path })
		return path
	end
	local other = stand_in("other", '"result":{"protocol":99}')
	local old = stand_in("old", '"error":{"code":-32601,"message":"no method hello"}')
	mail.backend.use(nil)
	local ok, err: any = pcall(function()
		greed.option.set("mail-program", other)
		local inbox = assert(mail.query("in:inbox"))
		local _, said = mail.backend.get().search(inbox)
		assert(string.find(said or "", "speaks mail protocol 99", 1, true), tostring(said))
		assert(string.find(said or "", "it's newer", 1, true), tostring(said))
		greed.option.set("mail-program", old)
		_, said = mail.backend.get().search(inbox)
		assert(string.find(said or "", "older than this Greed", 1, true), tostring(said))
		assert(string.find(said or "", "no method hello", 1, true), "why: " .. tostring(said))
	end)
	greed.option.set("mail-program", "")
	fake()
	assert(ok, tostring(err))
end)

test("the owner searches greed-mail's index; what a view gets is the keys", function(t)
	local dir = t:tempdir()
	-- A greed-mail that says where its index is, which a test wrote.
	local program = `{dir}/greed-mail`
	local script = [[#!/bin/sh
while read line; do
	id=$(printf '%s' "$line" | sed 's/.*"id":\([0-9]*\).*/\1/')
	case "$line" in
	*'"hello"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocol":1}}\n' "$id" ;;
	*'"index"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"path":"INDEX"}}\n' "$id" ;;
	esac
done
]]
	greed.fs.write(program, (string.gsub(script, "INDEX", `{dir}/index.db`)))
	greed.process.run({ "chmod", "+x", program })
	local found: { string }? = nil
	local why: string? = nil
	local done = false
	greed.spawn(function()
		local index = assert(greed.index.writer(`{dir}/index.db`))
		assert(index:write({
			{ key = "m:1", text = "plots", fields = { from = "Bea", tag = { "INBOX" } } },
			{ key = "m:2", text = "rent", fields = { from = "Cal", tag = { "INBOX" } } },
		} :: any))
		mail.backend.use(nil)
		greed.option.set("mail-program", program)
		local bea = assert(mail.query("from:bea"))
		found, why = mail.backend.get().search(bea)
		done = true
	end)
	t:wait_for(function(): boolean
		return done
	end)
	greed.option.set("mail-program", "")
	fake()
	assert(found and #found == 1 and found[1] == "m:1", `{greed.json.encode(found)} {why}`)
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
		local text = window:buffer():text()
		assert(text == "From: me@example.com\nTo: \nCc: \nSubject: \n\n", text)
		assert(window:cursor() == window:buffer():line_end(1), "on To")
	end)
end)

test(
	"addresses complete from your mail, From from your own, and :mail-attach adds a file",
	function(t)
		fake()
		in_the_mail_session(function()
			t:buffer("|x")
			t:run("mail")
			t:keys("esc c")
			local view = greed.view()
			local buffer = view:buffer()
			view:set_cursor(buffer:line_end(1))
			buffer:edit(function(e)
				e:insert(buffer:line_end(1), "carl@x, an")
			end)
			view:set_cursor(buffer:line_end(1))
			local items = mail.addressed(view) or {}
			assert(
				#items == 1 and items[1].text == "Anna Berg <anna@example.com>",
				tostring(#items)
			)
			assert(items[1].from == buffer:line_end(1) - 2, "replaces what was typed")
			view:set_cursor(buffer:line_end(0))
			local own = mail.addressed(view) or {}
			assert(
				#own == 1 and own[1].text == "me@example.com",
				"your own addresses, as far as typed"
			)
			view:set_cursor(buffer:line_end(3))
			assert(#(mail.addressed(view) or {}) == 0, "nothing for the subject")
			local dir = t:tempdir({ ["plan.pdf"] = "%PDF" })
			t:run("mail-attach", { `{dir}/plan.pdf` })
			t:run("mail-attach", { `{dir}/notes.txt` })
			local draft = mail.parse_draft(buffer:text())
			assert(draft.attach and #draft.attach == 2, buffer:text())
			assert(draft.from == "me@example.com" and draft.to == "carl@x, an", draft.to)
		end)
	end
)

test("mail is written from a quick look too, and goes back to it once sent", function(t)
	fake()
	t:buffer("|x")
	t:run("mail")
	t:keys("esc c")
	assert(greed.view():buffer():kind() == "mail-compose", greed.view():buffer():kind())
	t:keys("i a n n a @ x esc")
	t:run("mail-send")
	assert(sent[1] and sent[1].to == "anna@x", tostring(sent[1] and sent[1].to))
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

test("t tags the message under the cursor, and takes the tag off again", function(t)
	fake()
	in_the_mail_session(function()
		t:buffer("|x")
		t:run("mail")
		t:keys("esc t g a r d e n enter")
		assert(table.concat(acted, ", ") == "tag garden m:1:b", table.concat(acted, ", "))
		assert(
			mail.tag_text(mail.shown()[1].tags) == "#Work #garden",
			mail.tag_text(mail.shown()[1].tags)
		)
		t:keys("t G a r d e n enter")
		assert(acted[2] == "untag garden m:1:b", "off as it is: " .. acted[2])
		assert(mail.tag_text(mail.shown()[1].tags) == "#Work", "the inbox isn't shown")
	end)
end)

test("a thread reads from its HTML, its links open, and h reads it as text", function(t)
	fake()
	local opened: { string } = {}
	local open_link, open_page = core.file.open_link, core.file.open_page
	core.file.open_link = function(uri: string)
		table.insert(opened, uri)
	end
	core.file.open_page = function(path: string)
		table.insert(opened, `page {path}`)
	end
	local ok, err: any = pcall(function()
		t:buffer("|x")
		t:run("mail")
		t:keys("esc j enter")
		local buffer = greed.view():buffer()
		local text = buffer:text()
		assert(string.find(text, "Tomatoes by the fence", 1, true), text)
		local at = string.find(text, "Read more", 1, true)
		assert(at, text)
		greed.view():set_cursor(at - 1)
		t:keys("enter")
		assert(opened[1] == "https://example.com/garden", tostring(opened[1]))
		t:keys("b")
		assert(opened[2] == "page /pages/m:1:a.html", "in the browser: " .. tostring(opened[2]))
		t:keys("h")
		text = buffer:text()
		assert(string.find(text, "tomatoes by the fence", 1, true), text)
		assert(not string.find(text, "Read more", 1, true), "as text: " .. text)
	end)
	core.file.open_link, core.file.open_page = open_link, open_page
	assert(ok, tostring(err))
end)

test("what's attached shows by its kind, a program as one that never opens", function()
	local function icon(name: string, mime: string): string
		return mail.attachment_icon({ name = name, mime = mime, size = 1 })
	end
	assert(icon("photo.jpg", "image/jpeg") == "🖼")
	assert(icon("invoice.pdf", "application/pdf") == "📄")
	assert(
		icon(
			"report.docx",
			"application/vnd.openxmlformats-officedocument.wordprocessingml.document"
		) == "📄"
	)
	assert(icon("song.mp3", "audio/mpeg") == "🎵")
	assert(icon("photos.zip", "application/zip") == "📦")
	assert(icon("invite.ics", "text/calendar") == "📅")
	assert(icon("setup.exe", "application/octet-stream") == "⚠", "never opened")
	assert(icon("data.dat", "application/octet-stream") == "📎")
	local _, says = core.file.opening("setup.exe", "application/octet-stream")
	assert(says == "a program: it's saved, never opened", says)
end)

test("what's attached opens when pressed, and S saves it where you say", function(t)
	fake()
	local opened: { string } = {}
	local open = core.file.open
	core.file.open = function(path: string)
		table.insert(opened, path)
	end
	local ok, err: any = pcall(function()
		t:buffer("|x")
		t:run("mail")
		t:keys("esc")
		local list = table.concat(t:screen(120, 20), "\n")
		assert(string.find(list, "📎[^\n]*Invoice 41"), "a clip on its row: " .. list)
		assert(not string.find(list, "📎[^\n]*Garden plans"), "none without: " .. list)
		t:keys("enter")
		local text = greed.view():buffer():text()
		assert(string.find(text, "📎 1 attached", 1, true), text)
		local at = string.find(text, "📄 invoice-41.pdf  20.5 kB · opens in Greed", 1, true)
		assert(at, text)
		greed.view():set_cursor(at + #"📄 " - 1)
		t:keys("enter")
		assert(fetched[1] == "m:1:b 0 -", tostring(fetched[1]))
		assert(opened[1] == "/kept/m:1:b/0", "as its kind opens: " .. tostring(opened[1]))
		greed.view():set_cursor(0)
		t:keys("S")
		assert(
			greed.view():buffer():text() == "~/Downloads/invoice-41.pdf",
			"the only one, offered"
		)
		t:keys("enter")
		assert(fetched[2] == "m:1:b 0 ~/Downloads/invoice-41.pdf", tostring(fetched[2]))
	end)
	core.file.open = open
	assert(ok, tostring(err))
end)

test("space . on what's attached opens, saves, saves all and copies its path", function(t)
	fake()
	t:buffer("|x")
	t:run("mail")
	t:keys("esc enter")
	local window = greed.view()
	local text = window:buffer():text()
	local at = string.find(text, "invoice-41.pdf", 1, true)
	assert(at, text)
	window:set_cursor(at - 1)
	local target: core.Target? = nil
	local thread_at = 0
	for i, found in core.actions.at(window) do
		if found.kind == "mail-attachment" and target == nil then
			target = found
			assert(thread_at == 0, "the attachment, before its thread")
		elseif found.kind == "mail" then
			thread_at = i
		end
	end
	assert(target, "the attachment")
	assert(target.label == "invoice-41.pdf", target.label)
	local actions: { [string]: any } = {}
	for _, action in core.actions.for_kind(target.kind, target) do
		actions[action.name] = action
	end
	for _, name in { "open", "open-outside", "save", "save-all", "copy-path" } do
		assert(actions[name], name)
	end
	core.actions.run(actions["copy-path"], target)
	local copied = (greed.clipboard.get() or {})[1]
	assert(copied == "/kept/m:1:b/0", tostring(copied))
	-- It asks, so it runs as a key's command would, and enter answers.
	greed.spawn(function()
		core.actions.run(actions["save-all"], target :: core.Target)
	end)
	t:wait(10)
	assert(greed.view():buffer():text() == "~/Downloads", "asks for the folder")
	t:keys("enter")
	assert(
		fetched[#fetched] == "m:1:b 0 ~/Downloads/invoice-41.pdf",
		"each by its name: " .. tostring(fetched[#fetched])
	)
end)

test("a list shows a thread once, as its newest message found", function()
	local function message(key: string, thread: string, unread: boolean, tags: { string }): any
		return {
			key = key,
			thread = thread,
			from = "Bob <bob@example.com>",
			subject = "Plans",
			unread = unread,
			flagged = false,
			tags = tags,
		}
	end
	local rows = mail.threads({
		message("m:1:c", "t:1:x", false, { "Inbox" }),
		message("m:1:b", "t:1:y", false, { "Inbox" }),
		message("m:1:a", "t:1:x", true, { "Work" }),
	})
	assert(#rows == 2, tostring(#rows))
	assert(rows[1].key == "m:1:c", "the newest stands for it")
	assert(rows[1].unread, "unread if any found is")
	assert(table.concat(rows[1].tags, " ") == "Inbox Work")
	assert(table.concat(rows[1].found or {}, " ") == "m:1:c m:1:a", "what a change changes")
	assert(table.concat(rows[2].found or {}, " ") == "m:1:b")
end)

test(
	"saved searches show over the list with their unread; tab, alt and a number go to them",
	function(t)
		fake()
		in_the_mail_session(function()
			t:buffer("|x")
			local window = greed.view()
			t:run("mail")
			t:keys("esc")
			local top = string.match(window:buffer():text(), "^[^\n]*") or ""
			assert(string.find(top, "1 Inbox 1", 1, true), top)
			assert(
				string.find(top, "3 Flagged ", 1, true)
					and not string.find(top, "Flagged 1", 1, true),
				top
			)
			t:keys("alt-2")
			assert(table.concat(subjects(), ", ") == "Garden plans", table.concat(subjects(), ", "))
			assert(window:buffer():kind() == "mail")
			t:keys("tab")
			assert(#mail.shown() == 0, "on to Flagged, none")
			t:keys("shift-tab shift-tab")
			assert(
				table.concat(subjects(), ", ") == "Invoice 41, Garden plans",
				"back round to the inbox"
			)
			t:keys("] [")
			assert(#mail.shown() == 2, "] and [ go round too")
			-- However many there are, g s picks one by its name.
			t:keys("g s U n r e a d enter")
			assert(table.concat(subjects(), ", ") == "Garden plans", table.concat(subjects(), ", "))
		end)
	end
)

test("rules act on new mail they find, only that, and only in the mail session", function()
	fake()
	mail.rules = { { query = "from:bob", tag = "garden", read = true, archive = true } }
	local ok, err: any = pcall(function()
		mail.backend.arrived({ "m:1:a", "m:1:b" })
		assert(#acted == 0, "not outside the mail session: " .. table.concat(acted, ", "))
		in_the_mail_session(function()
			mail.backend.arrived({ "m:1:b" })
			assert(#acted == 0, "Bob's isn't new: " .. table.concat(acted, ", "))
			mail.backend.arrived({ "m:1:a", "m:1:b" })
			assert(
				table.concat(acted, ", ") == "read m:1:a, tag garden m:1:a, archive m:1:a",
				table.concat(acted, ", ")
			)
		end)
	end)
	mail.rules = {}
	assert(ok, tostring(err))
end)

test("a rule is tried on the mail there, changing nothing, then run over it once asked", function(t)
	fake()
	mail.rules = {
		{ query = "in:inbox", tag = "seen-it" },
		{ query = "from:nobody", archive = true },
	}
	local ok, err: any = pcall(function()
		in_the_mail_session(function()
			t:buffer("|x")
			t:run("mail")
			t:keys("esc")
			t:run("mail-rule-try")
			t:keys("1 . enter")
			assert(#acted == 0, "trying changes nothing: " .. table.concat(acted, ", "))
			local said = table.concat(t:messages(), "\n")
			assert(string.find(said, "in:inbox finds 2 now; it would tag seen-it", 1, true), said)
			t:run("mail-rule-run")
			t:keys("1 . enter n")
			assert(#acted == 0, "not without a yes")
			t:run("mail-rule-run")
			t:keys("1 . enter y")
			table.sort(acted)
			assert(
				table.concat(acted, ", ") == "tag seen-it m:1:a, tag seen-it m:1:b",
				table.concat(acted, ", ")
			)
		end)
	end)
	mail.rules = {}
	assert(ok, tostring(err))
end)

test("a rule over all mail keeps mail an age, but never moves many on its own", function(t)
	fake()
	mail.rules = { { query = "date:..2026-01-01", archive = true, all = true } }
	local many = mail.MANY
	local ok, err: any = pcall(function()
		in_the_mail_session(function()
			mail.run_standing()
			assert(table.concat(acted, ", ") == "archive m:1:c", table.concat(acted, ", "))
			acted = {}
			mail.rules = { { query = "in:inbox", trash = true, all = true } }
			mail.MANY = 1
			mail.run_standing()
			assert(#acted == 0, "two is many here: " .. table.concat(acted, ", "))
			local said = table.concat(t:messages(), "\n")
			assert(string.find(said, "finds more than 1: :mail-rule-run", 1, true), said)
		end)
	end)
	mail.MANY = many
	mail.rules = {}
	assert(ok, tostring(err))
end)

test("T makes a todo of the message in your inbox note, and its link reads it again", function(t)
	fake()
	local dir = t:tempdir()
	greed.option.set("notes-folder", dir)
	greed.option.set("notes-project-folder", `{dir}/.no-project-notes`)
	t:buffer("|x")
	t:run("mail")
	-- The prompt ends in a space, so when it's due is typed right after.
	t:keys("esc T f r i d a y enter")
	local text = greed.fs.read(`{dir}/inbox.md`) or ""
	local due = core.dates.read_words("friday").date
	assert(text == `- [ ] Anna Berg: Invoice 41 [mail](mail:b@example.com) due:{due}\n`, text)
	local said = table.concat(t:messages(), "\n")
	assert(string.find(said, "added to your inbox: Anna Berg: Invoice 41, due", 1, true), said)
	t:keys("q")
	core.file.open_link("mail:b@example.com")
	assert(greed.view():buffer():kind() == "mail-thread", greed.view():buffer():kind())
	assert(string.find(greed.view():buffer():text(), "Invoice 41", 1, true) ~= nil)
	t:keys("q")
	core.file.open_link("mail:gone@example.com")
	said = table.concat(t:messages(), "\n")
	assert(string.find(said, "isn't here", 1, true), said)
end)

test("a mail link keeps an odd Message-ID whole", function()
	local id = "a b(c)[d]<e>%f@x"
	local link = mail.link(id)
	assert(link == "[mail](mail:a%20b%28c%29%5Bd%5D%3Ce%3E%25f@x)", link)
	assert(mail.linked(string.match(link, "%((.*)%)") :: string) == id)
end)

test(
	"an invite shows as a card in its thread, and Accept answers it from the mail session",
	function(t)
		fake()
		local invite: any = {
			method = "REQUEST",
			summary = "Invoice review",
			location = "The shed",
			start = "2026-10-24T10:00:00+02:00",
			["end"] = "2026-10-24T11:00:00+02:00",
			all_day = false,
			organizer = { name = "Anna Berg", address = "anna@example.com" },
			attendees = {},
			repeats = true,
			cancelled = false,
			answer = "NEEDS-ACTION",
		}
		now[2].invite = invite
		in_the_mail_session(function()
			t:buffer("|x")
			t:run("mail")
			t:keys("esc enter")
			local text = greed.view():buffer():text()
			for _, shown in
				{ "Invoice review", "10:00 to 11:00, repeating", "The shed", "From: Anna Berg" }
			do
				assert(string.find(text, shown, 1, true), `{shown} in {text}`)
			end
			local at = string.find(text, " Accept ", 1, true)
			assert(at, text)
			greed.view():set_cursor(at)
			t:keys("enter")
			assert(responded[1] == "m:1:b accepted", tostring(responded[1]))
			text = greed.view():buffer():text()
			assert(string.find(text, "You accepted", 1, true), text)
		end)
		t:keys("q esc")
		t:run("mail")
		t:keys("esc enter")
		local text = greed.view():buffer():text()
		local at = string.find(text, " Decline ", 1, true)
		assert(at, text)
		greed.view():set_cursor(at)
		t:keys("enter")
		assert(
			responded[2] == "m:1:b declined",
			"from a quick look too: " .. tostring(responded[2])
		)
		invite.cancelled = true
		t:keys("q esc")
		t:run("mail")
		t:keys("esc enter")
		text = greed.view():buffer():text()
		assert(string.find(text, "Cancelled", 1, true) ~= nil, text)
		assert(string.find(text, " Accept ", 1, true) == nil, "nothing to answer: " .. text)
	end
)

test("an invite's time reads in words, all day or across midnight", function()
	local invite: any = {
		start = "2026-10-24",
		all_day = true,
	}
	assert(mail.invite_when(invite) == core.dates.day("2026-10-24"), mail.invite_when(invite))
	invite = { start = "2026-10-24T23:00:00+02:00", ["end"] = "2026-10-25T01:00:00+02:00" }
	assert(
		mail.invite_when(invite)
			== `{core.dates.day("2026-10-24")} 23:00 to {core.dates.day("2026-10-25")} 01:00`,
		mail.invite_when(invite)
	)
end)

test("z undoes the last change, and deleting for good asks first", function(t)
	fake()
	in_the_mail_session(function()
		t:buffer("|x")
		t:run("mail")
		t:keys("esc e")
		assert(table.concat(subjects(), ", ") == "Garden plans", table.concat(subjects(), ", "))
		t:keys("z")
		assert(acted[#acted] == "undo", tostring(acted[#acted]))
		assert(
			table.concat(subjects(), ", ") == "Invoice 41, Garden plans",
			"back in the inbox: " .. table.concat(subjects(), ", ")
		)
		t:keys("z")
		assert(
			string.find(table.concat(t:messages(), "\n"), "nothing to undo", 1, true) ~= nil,
			"once"
		)
		-- In the trash, d asks before deleting for good.
		now[2].tags = { "Trash" }
		t:keys("/ ctrl-u i n : t r a s h enter")
		local count = #acted
		t:keys("d n")
		assert(#acted == count, "kept: " .. table.concat(acted, ", "))
		assert(string.find(table.concat(t:messages(), "\n"), "can't be undone", 1, true) ~= nil)
		t:keys("d y")
		assert(acted[#acted] == "trash m:1:b", tostring(acted[#acted]))
	end)
end)

test("sent mail says z takes it back", function(t)
	fake()
	t:buffer("|x")
	t:run("mail")
	t:keys("esc c")
	t:keys("i a n n a @ x esc")
	t:run("mail-send")
	assert(
		string.find(table.concat(t:messages(), "\n"), "sending in 10 s: z takes it back", 1, true)
			~= nil
	)
end)

test("a long quote folds into a line to press, and o shows all of the thread", function(t)
	fake()
	now[2].text = "Paid.\n\nOn Sun, Anna Berg wrote:\n> please\n> pay\n>\n> by\n> Friday\n"
	t:buffer("|x")
	t:run("mail")
	t:keys("esc enter")
	local text = greed.view():buffer():text()
	assert(string.find(text, "··· 6 lines quoted", 1, true) ~= nil, text)
	assert(string.find(text, "> pay", 1, true) == nil, "folded: " .. text)
	assert(string.find(text, "Paid.", 1, true) ~= nil, text)
	local at = string.find(text, "··· 6", 1, true) :: number
	greed.view():set_cursor(at - 1)
	t:keys("enter")
	text = greed.view():buffer():text()
	assert(string.find(text, "On Sun, Anna Berg wrote:\n> please", 1, true) ~= nil, text)
	local runs = mail.quoted_runs({ "hi", "> a", "> b", "> c" })
	assert(#runs == 0, "three quoted lines stay")
end)

test("earlier messages read before show as a line each until pressed", function(t)
	fake()
	now[2].earlier = {
		{
			key = "m:1:b0",
			thread = "t:1:b",
			from = "Anna Berg <anna@example.com>",
			subject = "Invoice 41",
			date = "2026-10-17T08:00:00+02:00",
			unread = false,
			flagged = false,
			tags = {},
			to = "me@example.com",
			cc = "",
			text = "The first word on it\nand more",
			attachments = {},
			complete = true,
			html = false,
		},
	}
	t:buffer("|x")
	t:run("mail")
	t:keys("esc enter")
	local text = greed.view():buffer():text()
	assert(string.find(text, "▸ Anna Berg", 1, true) ~= nil, text)
	assert(string.find(text, "The first word on it", 1, true) ~= nil, text)
	assert(string.find(text, "and more", 1, true) == nil, "closed: " .. text)
	assert(string.find(text, "please pay by Friday", 1, true) ~= nil, "the last is open")
	t:keys("o")
	text = greed.view():buffer():text()
	assert(string.find(text, "and more", 1, true) ~= nil, "all open: " .. text)
end)

test(
	"a thread opened at one message, as a mail: link opens it, shows it unfolded there",
	function(t)
		fake()
		now[2].earlier = {
			{
				key = "m:1:b0",
				thread = "t:1:b",
				from = "Anna Berg <anna@example.com>",
				subject = "Invoice 41",
				date = "2026-10-17T08:00:00+02:00",
				unread = false,
				flagged = false,
				tags = {},
				to = "me@example.com",
				cc = "",
				text = "The first word on it\nand more",
				attachments = {},
				complete = true,
				html = false,
			},
		}
		t:buffer("|x")
		-- The line the cursor is on.
		local function here(): (string, number)
			local view = greed.view()
			local buffer = view:buffer()
			local line = buffer:line_of(view:cursor())
			return buffer:slice(buffer:line_start(line), buffer:line_end(line)), line
		end
		mail.read("m:1:b", nil, "m:1:b0")
		local text = greed.view():buffer():text()
		assert(string.find(text, "and more", 1, true) ~= nil, "unfolded: " .. text)
		local line, first = here()
		assert(line == "From: Anna Berg <anna@example.com>" and first > 0, line)
		mail.read("m:1:b", nil, "m:1:b")
		local last_line, last = here()
		assert(last_line == "From: Anna Berg <anna@example.com>" and last > first, `{last} {first}`)
	end
)

test("greed-mail is the one mail-program names, or the one beside greed", function()
	greed.option.set("mail-program", "/opt/mail/greed-mail")
	assert(mail.backend.program() == "/opt/mail/greed-mail")
	greed.option.set("mail-program", "")
	local found = mail.backend.program()
	local beside = string.match(greed.session.program() or "", "^(.*)/[^/]*$")
	assert(
		found == `{beside}/greed-mail` or found == "greed-mail",
		`beside greed when it's there, else on PATH: {found}`
	)
end)

test("the list says what greed-mail is busy with: indexing, then syncing", function(t)
	fake()
	t:buffer("|x")
	t:run("mail")
	t:keys("esc")
	local backend = mail.backend
	backend.heard("indexing", { done = 40000, of = 143691 })
	local text = greed.view():buffer():text()
	assert(string.find(text, "indexing your mail ▕", 1, true) ~= nil, text)
	assert(string.find(text, "40,000 of 143,691", 1, true) ~= nil, text)
	backend.heard("indexing", { done = 143691, of = 143691 })
	backend.heard("progress", { account = "proton", messages = 85412 })
	text = greed.view():buffer():text()
	assert(string.find(text, "indexing", 1, true) == nil, "done: " .. text)
	assert(string.find(text, "syncing proton: 85,412 messages in", 1, true) ~= nil, text)
	backend.heard("synced", { account = "proton", messages = 90000, done = true })
	text = greed.view():buffer():text()
	assert(string.find(text, "syncing", 1, true) == nil, "all in: " .. text)
end)

-- Runs the agent tool `name` with `args`.
local function tool(name: string, args: { [string]: any }): any
	local agent = require("@agent")
	for _, found in agent.tools() do
		if found.name == name then
			return found.run(args, agent.caller())
		end
	end
	error(`no tool {name}`)
end

test(
	"an agent searches the mail and reads a thread, which stays unread, marked as from outside",
	function(t)
		fake()
		local found = tool("mail_search", { query = "from:anna" })
		assert(string.find(found, "^<untrusted%-%x+ source=\"a search of the user's mail"), found)
		local rows = greed.json.decode(assert(string.match(found, "\n(.*)\n</untrusted")))
		assert(#rows == 1 and rows[1].key == "m:1:b" and rows[1].subject == "Invoice 41", found)
		assert(rows[1].attached == 1)
		local none = greed.json.decode(
			assert(
				string.match(tool("mail_search", { query = "from:nobody" }), "\n(.*)\n</untrusted")
			)
		)
		assert(#none == 0, "nothing found is an empty list")
		assert(
			not pcall(tool, "mail_search", { query = "date:not-a-date" }),
			"a query that won't read fails"
		)
		local thread = tool("mail_read", { key = "m:1:a" })
		assert(string.find(thread, 'source="mail the user received"', 1, true), thread)
		local read = greed.json.decode(assert(string.match(thread, "\n(.*)\n</untrusted")))
		assert(
			read.subject == "Garden plans" and read.messages[1].text == "tomatoes by the fence",
			thread
		)
		assert(#acted == 0, "reading for an agent leaves it unread")
		assert(not pcall(tool, "mail_read", { key = "m:9:z" }), "no such mail")
	end
)

test("an agent shows you a thread, and marks or archives mail after asking", function(t)
	fake()
	in_the_mail_session(function()
		t:buffer("|x")
		local window = greed.view()
		tool("mail_show", { key = "m:1:b" })
		t:wait(0)
		local shown = false
		for _, view in greed.floats() do
			shown = shown or view:buffer():kind() == "mail-thread"
		end
		assert(shown or window:buffer():kind() == "mail-thread", "the thread shows")
		local agent = require("@agent")
		for _, found in agent.tools() do
			if found.name == "mail_act" then
				assert(agent.asks(found), "changing mail asks first")
			elseif found.name == "mail_search" or found.name == "mail_read" then
				assert(not agent.asks(found), "searching and reading don't")
			end
		end
		acted = {}
		assert(tool("mail_act", { keys = { "m:1:a" }, action = "archive" }) == "changed 1")
		assert(acted[1] == "archive m:1:a", tostring(acted[1]))
		assert(not pcall(tool, "mail_act", { keys = { "m:1:a" }, action = "tag" }), "tag needs one")
		tool("mail_act", { keys = { "m:1:a" }, action = "trash" })
		local again = tool("mail_act", { keys = { "m:1:a" }, action = "trash" })
		assert(string.find(again, "only the user's to do", 1, true), again)
	end)
end)
