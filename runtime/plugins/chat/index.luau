-- The messages kept to search, in the chat service's owner: one index of
-- every message the services tell of (`messages`), taken out again when
-- deleted (`unsaid`), and each room's older ones fetched back to
-- `chat-search-days` (`history`) as an account comes in, gently, a page at
-- a time. Searched with Greed's query language, as mail and notes are:
-- `from:bea in:plans lunch is:mine`.

local greed = require("@greed")
local core = require("@core")

local M = {}

greed.option.define({
	name = "chat-search-days",
	doc = "How many days back each room's messages are fetched and kept to search; newer ones are always kept",
	default = 90,
})

--- A message as it's kept: what `Said` says, with its account's key
--- ("service id") and its own.
export type Kept = {
	key: string,
	account: string,
	service: string,
	room: string,
	room_name: string,
	event: string,
	sender: string,
	sender_id: string,
	at: number,
	text: string,
	thread: string?,
	mine: boolean,
	direct: boolean,
}

--- A message a search found, as chat shows it: its account, room, and
--- the item to show and go to.
export type Found = { account: string, room: string, room_name: string, item: any }

local function field(kind: string, get: (m: Kept) -> (string | { string })?): core.QueryField
	return { kind = kind, get = get :: any }
end

--- What a chat search runs over. `in:` names a room.
M.source = {
	fields = {
		from = field("text", function(m)
			return { m.sender, m.sender_id }
		end),
		room = field("text", function(m)
			return m.room_name
		end),
		account = field("exact", function(m)
			return m.account
		end),
		service = field("exact", function(m)
			return m.service
		end),
		date = field("date", function(m)
			return os.date("!%Y-%m-%dT%H:%M:%SZ", m.at // 1000) :: string
		end),
		thread = field("exact", function(m)
			return m.thread
		end),
		-- What showing and going to a message found needs, kept with it.
		room_id = field("exact", function(m)
			return m.room
		end),
		event = field("exact", function(m)
			return m.event
		end),
		at = field("value", function(m)
			return tostring(m.at)
		end),
	},
	flags = {
		mine = function(m: Kept): boolean
			return m.mine
		end,
		direct = function(m: Kept): boolean
			return m.direct
		end,
	},
	text = function(m: Kept): string
		return m.text
	end,
	places = "room",
	key = function(m: Kept): string
		return m.key
	end,
	stored = { "mine", "direct" },
} :: core.QuerySource

-- The index, once it's opened, in the owner only.
local opened: greed.Index? = nil

--- The index, opened (made) the first time; nil and why when it can't be.
function M.index(): (greed.Index?, string?)
	if opened then
		return opened, nil
	end
	local data = greed.fs.dirs().data
	if data == nil then
		return nil, "there's no data folder to keep messages in"
	end
	local made, why = greed.index.writer(`{data}/chat/messages.db`)
	opened = made
	return made, why
end

--- The key of message `event` in `room` of account `account` ("service id").
function M.key(account: string, room: string, event: string): string
	return `{account}|{room}|{event}`
end

-- `said` (a `Said`) of account `account`, of `service`, as it's kept.
local function kept(service: string, account: string, said: any): Kept
	return {
		key = M.key(account, said.room, said.event),
		account = account,
		service = service,
		room = said.room,
		room_name = said.room_name,
		event = said.event,
		sender = said.sender.name,
		sender_id = said.sender.id,
		at = said.at,
		text = said.text,
		thread = said.thread,
		mine = said.mine,
		direct = said.direct,
	}
end

-- The first value of field `name` of `item`, as the index kept it.
local function first(item: greed.IndexItem, name: string): string?
	local fields: any = item.fields or {}
	local values = fields[name]
	return if values then values[1] else nil
end

--- Keeps `messages` (`Said`s) of account `account` of `service`; gives the
--- keys of those it had already. An edit keeps the date it was written.
function M.keep(service: string, account: string, messages: { any }): { [string]: boolean }
	local index = M.index()
	local had: { [string]: boolean } = {}
	if index == nil or #messages == 0 then
		return had
	end
	local all: { Kept } = {}
	local keys: { string } = {}
	for _, said in messages do
		local one = kept(service, account, said)
		table.insert(all, one)
		table.insert(keys, one.key)
	end
	local before: { [string]: number } = {}
	for _, item in index:items(keys) or {} :: { greed.IndexItem } do
		had[item.key] = true
		before[item.key] = tonumber(first(item, "at")) or 0
	end
	for _, one in all do
		local at = before[one.key]
		if at and at > 0 then
			one.at = at
		end
	end
	index:write(core.query.index_items(all, M.source))
	return had
end

--- Forgets message `event` in `room` of account `account`, deleted.
function M.forget(account: string, room: string, event: string)
	local index = M.index()
	if index then
		index:remove({ M.key(account, room, event) })
	end
end

--- The messages `parsed` finds, newest first unless it sorts otherwise, or
--- nil and why.
function M.search(parsed: core.Query): ({ Found }?, string?)
	local index, why = M.index()
	if index == nil then
		return nil, why
	end
	local asked = table.clone(parsed)
	asked.view = table.clone(parsed.view)
	if #asked.view.sort == 0 then
		asked.view.sort = { { field = "date", descending = true } }
	end
	asked.view.limit = asked.view.limit or 200
	local keys, _, trouble = core.query.search(index, asked, M.source)
	if keys == nil then
		return nil, trouble
	end
	local found: { Found } = {}
	for _, item in index:items(keys) or {} :: { greed.IndexItem } do
		local fields: any = item.fields or {}
		local from = fields.from or {}
		table.insert(found, {
			account = first(item, "account") or "",
			room = first(item, "room_id") or "",
			room_name = first(item, "room") or "",
			item = {
				id = first(item, "event"),
				event = first(item, "event"),
				sender = { name = from[1] or "", id = from[2] or "" },
				at = tonumber(first(item, "at")) or 0,
				text = item.text or "",
			},
		})
	end
	return found, nil
end

-- How long to wait between pages fetched, so catching up never crowds out
-- what you're doing, in milliseconds.
M.BETWEEN = 300

-- The most pages a room is walked back in one catching up.
local PAGES = 100

-- Where the rooms caught up to the horizon are noted, by "account|room".
local function caught_file(): string?
	local data = greed.fs.dirs().data
	return if data then `{data}/chat/caught-up.json` else nil
end

local function caught(): { [string]: boolean }
	local file = caught_file()
	local text = if file then greed.fs.read(file) else nil
	local decoded = if text then greed.json.decode(text) else nil
	return if type(decoded) == "table" then decoded else {}
end

--- Walks each room of account `account` ("service id") back with `ask`
--- (`history`, `rooms`), keeping what it finds: to `chat-search-days` back
--- the first time, after that only to where it already has messages. Rooms
--- in `walked` (by "account|room") are left out, and those it starts on go
--- in it.
function M.catch_up(
	account: string,
	ask: (method: string, params: any) -> (any, string?),
	walked: { [string]: boolean }
)
	local service, id = string.match(account, "^(%S+) (.*)$")
	if service == nil or id == nil then
		return
	end
	local rooms = ask("rooms", { account = id })
	if type(rooms) ~= "table" then
		return
	end
	local days = tonumber(greed.option.get("chat-search-days")) or 90
	local horizon = (os.time() - days * 86400) * 1000
	local done = caught()
	for _, room in rooms do
		local which = `{account}|{room.id}`
		if room.kind == "space" or room.kind == "invite" or walked[which] then
			continue
		end
		walked[which] = true
		local before: string? = nil
		for _ = 1, PAGES do
			local page = ask("history", { account = id, room = room.id, before = before })
			if type(page) ~= "table" then
				break
			end
			local messages: { any } = page.messages or {}
			local had = M.keep(service, account, messages)
			local oldest = messages[#messages]
			if page.before == nil or (oldest and oldest.at < horizon) then
				done[which] = true
				break
			end
			-- Caught up once already: back to where it has messages is enough.
			if done[which] and next(had) ~= nil then
				break
			end
			before = page.before
			greed.sleep(M.BETWEEN)
		end
	end
	local file = caught_file()
	if file then
		greed.fs.write(file, greed.json.encode(done))
	end
end

return M
