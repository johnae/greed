-- Tools for agents: search the mail, read a thread, show one to the user,
-- and mark, tag or archive what they found. What they give back was
-- written by whoever sent the mail, so it goes between untrusted tags.
-- Reading a thread here leaves it unread; showing it reads it, as the
-- user does.

local greed = require("@greed")
local agent = require("@agent")
local backend = require("./backend")

-- The most messages a search gives an agent, and how many by default.
local MOST = 100
local SOME = 20

-- The most characters of one message's text a thread gives an agent.
local LONGEST = 20000

-- How long reading a thread waits for bodies not fetched yet, in ms.
local WAIT = 15000

-- The width HTML is laid out at, for a message with no text of its own.
local WIDTH = 100

local ACTIONS = { "read", "unread", "flag", "unflag", "archive", "trash", "tag", "untag" }

return function(mail: any)
	local object = agent.schema.object

	agent.group(
		"mail",
		"Your mail: searching it, reading threads, showing one to you, and marking, tagging "
			.. "and archiving"
	)

	agent.tool({
		name = "mail_search",
		group = "mail",
		description = "Search the user's mail, every account, newest first: each message's key "
			.. "(for mail_read, mail_show and mail_act), thread, sender, subject, date, whether "
			.. "it's unread or flagged, its folders and tags, and how many things are attached. "
			.. "The query is the one the mail list's search box takes: words, from:, to:, "
			.. "subject:, in:inbox (a folder, label or tag), account:NAME, list:, file: and "
			.. "type:pdf (what's attached), date:2w.. or date:2026-01..2026-03, is:unread, "
			.. "is:flagged, is:mine (sent by the user), is:attachment, - for not, OR, ( )",
		input = object({
			query = { type = "string", description = 'Like "from:bank card date:2026-01.."' },
			limit = {
				type = "integer",
				description = `How many at most, {SOME} if left out, {MOST} at most`,
			},
		}, { "query" }),
		run = function(args)
			local parsed, problem = mail.query(args.query)
			if parsed == nil then
				error(problem, 0)
			end
			parsed.view.limit = math.clamp(tonumber(args.limit) or SOME, 1, MOST)
			local found, err = mail.search(parsed)
			if found == nil then
				error(err or "the mail can't be searched now", 0)
			end
			local out: { any } = {}
			for _, m in found do
				table.insert(out, {
					key = m.key,
					thread = m.thread,
					from = m.from,
					subject = m.subject,
					date = m.date,
					unread = m.unread,
					flagged = m.flagged,
					tags = greed.json.array(m.tags),
					attached = m.attached,
				})
			end
			return agent.untrusted(
				`a search of the user's mail for "{args.query}"`,
				greed.json.encode(greed.json.array(out))
			)
		end,
	})

	-- The thread `key` names, once each message's text is in or `WAIT`
	-- has gone by.
	local function whole(key: string): backend.Thread
		local waited = 0
		while true do
			local thread, err = backend.get().thread(key)
			if thread == nil then
				error(err or `there's no mail {key}`, 0)
			end
			local missing = false
			for _, m in thread.messages do
				missing = missing or m.text == nil
			end
			if not missing or waited >= WAIT then
				return thread
			end
			greed.sleep(250)
			waited += 250
		end
	end

	-- What `m` says: its text, or laid out from its HTML when it has no
	-- text of its own, cut at `LONGEST`.
	local function text_of(m: backend.Message): string
		local text = m.text or ""
		if string.match(text, "^%s*$") then
			text = mail.html_text(m, WIDTH) or text
		end
		if #text > LONGEST then
			local at = utf8.offset(text, LONGEST) or LONGEST
			text = string.sub(text, 1, at - 1) .. `\n(cut here: {#text - at + 1} more bytes)`
		end
		return text
	end

	agent.tool({
		name = "mail_read",
		group = "mail",
		description = "A thread of the user's mail, by a message's or the thread's key from "
			.. "mail_search: its subject and each message, oldest first, with who it's from "
			.. "and to, when, its folders and tags, its text and what's attached. It stays "
			.. "unread; mail_show shows it to the user",
		input = object({ key = { type = "string" } }, { "key" }),
		run = function(args)
			local thread = whole(args.key)
			local messages: { any } = {}
			for _, m in thread.messages do
				local attached: { any } = {}
				for _, a in m.attachments do
					table.insert(attached, { name = a.name, type = a.mime, bytes = a.size })
				end
				table.insert(messages, {
					key = m.key,
					from = m.from,
					to = m.to,
					cc = if m.cc ~= "" then m.cc else nil,
					date = m.date,
					unread = m.unread,
					tags = greed.json.array(m.tags),
					text = if m.text == nil and not m.html
						then "(its text hasn't come from the server yet)"
						else text_of(m),
					attached = greed.json.array(attached),
				})
			end
			return agent.untrusted(
				"mail the user received",
				greed.json.encode({
					thread = thread.key,
					subject = thread.subject,
					messages = greed.json.array(messages),
				})
			)
		end,
	})

	agent.tool({
		name = "mail_show",
		group = "mail",
		description = "Show the user a thread of their mail, by a key from mail_search, as "
			.. "if they'd opened it: on the mail page, or over what they're doing elsewhere. "
			.. "It's marked read, as reading it does",
		input = object({ key = { type = "string" } }, { "key" }),
		run = function(args)
			mail.read(args.key, nil, args.key)
			return `showing {args.key}`
		end,
	})

	agent.tool({
		name = "mail_act",
		group = "mail",
		kind = "edit",
		description = "Change the user's mail, by keys from mail_search (a thread's key "
			.. "changes all of it): mark it read or unread, flag or unflag it, archive it, "
			.. "move it to the trash, or tag and untag it with `tag`. The server gets it "
			.. "within seconds, and the user can undo it with z in the mail. Mail already in "
			.. "the trash is never deleted for good this way. Gives how many it changed",
		input = object({
			keys = { type = "array", items = { type = "string" } },
			action = { type = "string", enum = ACTIONS },
			tag = { type = "string", description = "For tag and untag" },
		}, { "keys", "action" }),
		run = function(args)
			if (args.action == "tag" or args.action == "untag") and not args.tag then
				error(`{args.action} needs the tag`, 0)
			end
			local keys: { string } = {}
			for _, key in args.keys do
				table.insert(keys, tostring(key))
			end
			local changed, err, in_trash = backend.get().act(keys, args.action, args.tag)
			if changed == nil then
				error(err or "it couldn't be changed", 0)
			end
			if in_trash and in_trash > 0 then
				return `{in_trash} of them are in the trash already; deleting them for good `
					.. "is only the user's to do"
			end
			return `changed {changed}`
		end,
	})
end
