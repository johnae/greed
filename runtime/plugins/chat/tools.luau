-- Tools for agents: list the rooms, read one, search the messages, and
-- send one. Reading leaves rooms unread. What they give back was written
-- by other people, so it goes between untrusted tags. Sending asks you
-- every time, saying what goes where.

local greed = require("@greed")
local core = require("@core")
local agent = require("@agent")
local backend = require("./backend")
local accounts = require("./accounts")
local search = require("./search")

-- How many messages reading a room gives, by default and at most.
local SOME = 30
local MOST = 200

-- How much of a message the question before sending shows.
local SHOWN = 120

local object = agent.schema.object

-- Every account's key, sorted.
local function keys(): { string }
	backend.start()
	return accounts.keys()
end

-- Account `key`'s rooms, as its service lists them; an error when it can't.
local function rooms_of(key: string): { backend.Room }
	local rooms, why = accounts.ask(key, "rooms")
	if rooms == nil then
		error(`{key}: {why or "its rooms can't be listed now"}`, 0)
	end
	return rooms
end

-- The name room `room` of account `key` has, or the room's id.
local function name_of(key: string, room: string): string
	for _, one in rooms_of(key) do
		if one.id == room then
			return one.name
		end
	end
	return room
end

-- The account `key` names, or an error saying which there are.
local function account(key: any): string
	local given = tostring(key or "")
	if backend.accounts[given] then
		return given
	end
	error(`there's no chat account {given}; there are {table.concat(keys(), ", ")}`, 0)
end

local function iso(ms: number): string
	return core.time.iso_text(ms // 1000)
end

-- What sending `args` does, for the question before it: the text, cut,
-- and where it goes.
local function sending(args: { [string]: any }): string
	local key = tostring(args.account or "")
	local where = if backend.accounts[key]
		then name_of(key, tostring(args.room))
		else tostring(args.room)
	local text = core.text.clip(string.gsub(tostring(args.text or ""), "%s+", " "), SHOWN)
	return `sends "{text}" to {where} as you`
end

return function(chat: any)
	agent.group(
		"chat",
		"Your chat (Matrix and Mattermost): listing rooms, reading and searching them, and sending a message, which asks you"
	)

	agent.tool({
		name = "chat_rooms",
		group = "chat",
		description = "The user's chat rooms, channels and direct messages, every account: each one's "
			.. "account and room (for chat_read and chat_send), name, kind (room, direct, group, "
			.. "space, invite), how many messages are unread and mention the user, and when it was "
			.. "last active. Those with mentions or unread messages come first",
		input = object({
			query = { type = "string", description = "Only those whose names have these letters" },
		}, {}),
		run = function(args)
			local query = string.lower(tostring(args.query or ""))
			local found: { { key: string, room: backend.Room } } = {}
			for _, key in keys() do
				for _, one in rooms_of(key) do
					if query == "" or string.find(string.lower(one.name), query, 1, true) then
						table.insert(found, { key = key, room = one })
					end
				end
			end
			table.sort(found, function(a, b): boolean
				return chat.ahead(a.room, b.room)
			end)
			local out: { any } = {}
			for _, one in found do
				table.insert(out, {
					account = one.key,
					room = one.room.id,
					name = one.room.name,
					kind = one.room.kind,
					unread = one.room.unread,
					mentions = one.room.mentions,
					active = if one.room.active then iso(one.room.active) else nil,
				})
			end
			return agent.untrusted(
				"the user's chat rooms",
				greed.json.encode(greed.json.array(out))
			)
		end,
	})

	agent.tool({
		name = "chat_read",
		group = "chat",
		description = "The latest messages of a chat room, newest first, by the account and room from "
			.. "chat_rooms or chat_search: who wrote each, when, its text, its event (to reply to it) "
			.. "and thread, and whether the user wrote it. Give `before` from an answer to read "
			.. "older ones. The room stays unread",
		input = object({
			account = { type = "string" },
			room = { type = "string" },
			limit = {
				type = "integer",
				description = `How many at most, {SOME} if left out, {MOST} at most`,
			},
			before = { type = "string", description = "The `before` an earlier answer gave" },
		}, { "account", "room" }),
		run = function(args)
			local key = account(args.account)
			local history, why = accounts.ask(key, "history", {
				room = tostring(args.room),
				before = args.before,
				limit = math.clamp(tonumber(args.limit) or SOME, 1, MOST),
			})
			if history == nil then
				error(why or "the room can't be read now", 0)
			end
			local out: { any } = {}
			for _, said in history.messages or {} :: { any } do
				table.insert(out, {
					event = said.event,
					from = said.sender.name,
					at = iso(said.at),
					text = said.text,
					thread = said.thread,
					mine = said.mine,
				})
			end
			return agent.untrusted(
				`messages in the chat room {name_of(key, tostring(args.room))}`,
				greed.json.encode({ messages = greed.json.array(out), before = history.before })
			)
		end,
	})

	agent.tool({
		name = "chat_search",
		group = "chat",
		description = "Search the user's chat messages, every account, newest first: each one's "
			.. "account, room and room's name (for chat_read and chat_send), event, who wrote it, "
			.. "when and its text. The query is the chat search box's: words, from:, in:ROOM, "
			.. "date:2w.., is:mine, is:direct, - for not, OR",
		input = object({
			query = { type = "string", description = 'Like "deploy from:bea date:1w.."' },
			limit = { type = "integer", description = "How many at most, 50 if left out" },
		}, { "query" }),
		run = function(args)
			local limit = math.clamp(tonumber(args.limit) or 50, 1, MOST)
			local found, why = search.search(tostring(args.query))
			if found == nil then
				error(why or "the chat can't be searched now", 0)
			end
			local out: { any } = {}
			for i, one in found do
				if i > limit then
					break
				end
				table.insert(out, {
					account = one.account,
					room = one.room,
					room_name = one.room_name,
					event = one.item.event,
					from = one.item.sender.name,
					at = iso(one.item.at),
					text = one.item.text,
				})
			end
			return agent.untrusted(
				`a search of the user's chat for "{args.query}"`,
				greed.json.encode(greed.json.array(out))
			)
		end,
	})

	agent.tool({
		name = "chat_send",
		group = "chat",
		kind = "edit",
		description = "Send a message as the user, to a room by the account and room from chat_rooms or "
			.. "chat_search, written as Markdown; `reply_to` (an event) answers a message, `thread` "
			.. "(its first message's event) writes in a thread. The user is asked every time, shown "
			.. "what goes where. Slash commands aren't sent",
		input = object({
			account = { type = "string" },
			room = { type = "string" },
			text = { type = "string" },
			reply_to = { type = "string" },
			thread = { type = "string" },
		}, { "account", "room", "text" }),
		danger = sending,
		run = function(args)
			local key = account(args.account)
			local text = tostring(args.text)
			if string.match(text, "^%s*/") then
				error("slash commands are the user's to run", 0)
			end
			local _, why = accounts.ask(key, "send", {
				room = tostring(args.room),
				text = text,
				reply_to = args.reply_to,
				thread = args.thread,
			})
			if why then
				error(why, 0)
			end
			return `sent to {name_of(key, tostring(args.room))}`
		end,
	})
end
