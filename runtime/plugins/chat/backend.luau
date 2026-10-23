-- Chat's two halves, joined by the `chat` service (`@service`). The owner,
-- in the chat service's session, runs `greed-matrix serve` and
-- `greed-mattermost serve`, each started when first needed, over JSON-RPC
-- in one protocol, and keeps the accounts' secrets (tokens and store keys)
-- in the keyring: one secret a service (`chat-matrix`, `chat-mattermost`)
-- holding its accounts', handed back to the service when it starts. The
-- views, in every session, ask the owner and hear from it what the
-- services say; secrets never reach them. Tests put a fake in a service's
-- place (`use`).

local greed = require("@greed")
local core = require("@core")
local services = require("@service")
local index = require("./index")

local M = {}

--- The services there are, as their programs are named.
M.SERVICES = { "matrix", "mattermost" }

--- The session of the chat service, which `greed chat` shows.
M.SESSION = services.session_of("chat")

--- Whether this is the chat service's session.
function M.here(): boolean
	return greed.session.current() == M.SESSION
end

--- The protocol this speaks with the services, which they say in `hello`.
M.PROTOCOL = 1

-- What chat's owner and views speak (`@service`'s version).
local VERSION = 1

export type Account = {
	id: string,
	server: string,
	name: string?,
	state: { state: string, why: string? },
	--- Which service it's on, added here.
	service: string,
}

export type Room = {
	id: string,
	account: string,
	name: string,
	kind: string,
	topic: string?,
	parent: string?,
	unread: number,
	mentions: number,
	favourite: boolean,
	muted: boolean,
	encrypted: boolean,
	active: number?,
	--- For a direct message: "online", "away", "dnd" or "offline".
	presence: string?,
}

--- A file a message carries.
export type Media = {
	name: string,
	mime: string,
	size: number?,
	width: number?,
	height: number?,
	thumbnail: boolean,
}

export type Item = {
	id: string,
	event: string?,
	sender: { id: string, name: string, avatar: string? },
	at: number,
	kind: string,
	text: string,
	reply_to: string?,
	thread: string?,
	replies: number,
	reactions: { { key: string, count: number, mine: boolean } },
	edited: boolean,
	mine: boolean,
	sending: { state: string, why: string? }?,
	--- Who has read up to here (Matrix).
	read_by: { { id: string, name: string } }?,
	--- The file it carries.
	media: Media?,
	--- Where it opens in the service's own app, as for joining a call.
	link: string?,
	--- What its first link leads to, where the service gives it (Mattermost).
	preview: Preview?,
	--- For a poll: what it asks, and how it stands (Matrix).
	poll: Poll?,
	--- For a location: where.
	location: Location?,
	--- Buttons and menus an integration put in it (Mattermost).
	actions: { Action }?,
}

--- What a link leads to, as the page says of itself.
export type Preview = { url: string, title: string?, description: string?, site: string? }

--- Where a location message points.
export type Location = { latitude: number, longitude: number }

--- A poll: its answers with their votes, and whether one is yours.
export type Poll = {
	question: string,
	answers: { { id: string, text: string, votes: number, mine: boolean } },
	picks: number,
	ended: boolean,
}

--- A button, or with `options` a menu, in a message.
export type Action = { id: string, name: string, options: { { text: string, value: string } }? }

--- A new message for you (`alert`).
export type Alert = {
	room: string,
	room_name: string,
	event: string,
	sender: { id: string, name: string },
	body: string,
	--- Whether it names you, outside a direct message.
	mention: boolean,
	--- Whether it's in a direct message.
	direct: boolean,
}

--- What a service answers with: `request(method, params)` gives the result
--- or nil and why. Tests put a table of functions by method instead.
export type Service = { request: (method: string, params: any) -> (any, string?) }

for _, service in M.SERVICES do
	greed.option.define({
		name = `chat-{service}-program`,
		doc = `The greed-{service} program, its name on PATH or a path; empty for the one beside greed, or else on PATH`,
		default = "",
	})
end

-- Who wants to know what, in this session's views.
local account_listeners: { () -> () } = {}
local room_listeners: { (account: string) -> () } = {}
local timeline_listeners: { (account: string, room: string, thread: string?, changes: { any }) -> () } =
	{}
local typing_listeners: { (account: string, room: string, who: { string }) -> () } = {}
local step_listeners: { (login: string, step: any) -> () } = {}
local verify_listeners: { (account: string, about: any) -> () } = {}
local alerted_listeners: { (account: string, alert: Alert) -> () } = {}
local link_listeners: { (link: string) -> () } = {}
local reset_listeners: { () -> () } = {}
-- And in the owner's session.
local alert_listeners: { (account: string, alert: Alert) -> () } = {}
local read_listeners: { (account: string, room: string) -> () } = {}

--- Calls `listener` when an account comes, goes or changes state.
function M.on_accounts(listener: () -> ())
	greed.plugin.cleanup(core.registry.put(account_listeners, listener))
end

--- Calls `listener` with an account whose rooms changed.
function M.on_rooms(listener: (account: string) -> ())
	greed.plugin.cleanup(core.registry.put(room_listeners, listener))
end

--- Calls `listener` with the changes to an open timeline, a room's or
--- (with `thread`) a thread's.
function M.on_timeline(
	listener: (account: string, room: string, thread: string?, changes: { any }) -> ()
)
	greed.plugin.cleanup(core.registry.put(timeline_listeners, listener))
end

--- Calls `listener` with who's writing in a room whose timeline is open.
function M.on_typing(listener: (account: string, room: string, who: { string }) -> ())
	greed.plugin.cleanup(core.registry.put(typing_listeners, listener))
end

--- Calls `listener` with how a verification of an account's device goes
--- (`verify.changed`: asked, compare with its emoji, done, cancelled).
function M.on_verify(listener: (account: string, about: any) -> ())
	greed.plugin.cleanup(core.registry.put(verify_listeners, listener))
end

--- Calls `listener` with a sign-in's next step when it comes by itself,
--- as when the browser came back.
function M.on_step(listener: (login: string, step: any) -> ())
	greed.plugin.cleanup(core.registry.put(step_listeners, listener))
end

--- Calls `listener` with each alert the owner raised, wherever you are.
function M.on_alerted(listener: (account: string, alert: Alert) -> ())
	greed.plugin.cleanup(core.registry.put(alerted_listeners, listener))
end

--- Calls `listener` with a link a browser sign-in ended on, handed to the
--- owner (`greed link`), for the session whose sign-in waits for it.
function M.on_link(listener: (link: string) -> ())
	greed.plugin.cleanup(core.registry.put(link_listeners, listener))
end

--- Calls `listener` each time the views reach the owner again, as after it
--- started again: open timelines are asked for again.
function M.on_reset(listener: () -> ())
	greed.plugin.cleanup(core.registry.put(reset_listeners, listener))
end

--- In the owner's session: calls `listener` with a new message for you, as
--- the service decides.
function M.on_alert(listener: (account: string, alert: Alert) -> ())
	greed.plugin.cleanup(core.registry.put(alert_listeners, listener))
end

--- In the owner's session: calls `listener` with a room read in any
--- session.
function M.on_read(listener: (account: string, room: string) -> ())
	greed.plugin.cleanup(core.registry.put(read_listeners, listener))
end

--- An account's service and its id there, from its key "service id".
function M.split(key: string): (string, string)
	local service, id = string.match(key, "^(%S+) (.*)$")
	return service or key, id or ""
end

-- What each service can do beyond what all do, from `hello`, as a set.
local function set_of(can: { string }?): { [string]: boolean }
	local set: { [string]: boolean } = {}
	local listed: { string } = can or {}
	for _, one in listed do
		set[one] = true
	end
	return set
end

--- What each service can do beyond what all do, as it says in `hello`:
--- "encryption", "threads"...
M.can = {} :: { [string]: { [string]: boolean } }

--- The accounts signed in, by "service id".
M.accounts = {} :: { [string]: Account }

--- The program for `service`: its option's, else the one beside this
--- greed, else the one on PATH.
function M.program(service: string): string
	return core.file.companion(`chat-{service}-program`, `greed-{service}`)
end

-- The owner: it runs the services and keeps their accounts' secrets, in
-- the chat service's session. Nothing below reaches a view but through
-- `tell`, so secrets stay here.

-- The services running, or put in place by a test.
local running: { [string]: Service } = {}
-- The accounts the owner's services have, and what they can do.
local owned: { [string]: Account } = {}
local capable: { [string]: { [string]: boolean } } = {}
-- The sessions that have each timeline open, by "service|account|room|thread".
local opens: { [string]: { [string]: boolean } } = {}
-- The rooms each session shows, as "key|room", and when it said so.
local shown_by: { [string]: { rooms: { [string]: boolean }, at: number } } = {}
local offer: services.Offer? = nil

-- How long what a session said it shows counts, in seconds: views say it
-- again more often than that.
local SHOWN_FOR = 15

-- Tells the views `method` happened, as the service said it.
local function tell(method: string, params: any)
	if offer then
		offer:notify(method, params)
	end
end

-- The secret holding `service`'s accounts' secrets.
local function keyring_name(service: string): string
	return `chat-{service}`
end

-- `service`'s kept secrets, by account.
local function kept(service: string): { [string]: string }
	-- Vouched for: only chat's own secrets, and only these, are read and
	-- kept.
	local text = greed.vouch(greed.secrets.get, keyring_name(service))
	if text == nil or text == "" then
		return {}
	end
	local decoded = greed.json.decode(text)
	return if type(decoded) == "table" then decoded else {}
end

-- Keeps `secret` for `account` of `service`, or forgets it when nil.
local function keep(service: string, account: string, secret: string?)
	local secrets = kept(service)
	if secret then
		secrets[account] = secret
	else
		secrets[account] = nil
	end
	local _, why = greed.vouch(greed.secrets.set, keyring_name(service), greed.json.encode(secrets))
	if why then
		greed.echo(`can't keep the chat account's secret: {why}`)
	end
end

-- Where the owner notes which accounts it has, by "service id", without
-- their secrets: every session can tell from it whether to start the
-- owner with Greed, without reading the keyring.
local function accounts_file(): string?
	local data = greed.fs.dirs().data
	return if data then `{data}/chat/accounts.json` else nil
end

-- The accounts the owner noted it has.
local function noted(): { [string]: boolean }
	local file = accounts_file()
	local text = if file then greed.fs.read(file) else nil
	local decoded = if text then greed.json.decode(text) else nil
	return if type(decoded) == "table" then decoded else {}
end

-- Notes that the owner has account `key`, or not.
local function note(key: string, has: boolean)
	local file = accounts_file()
	local accounts = noted()
	if file == nil or (accounts[key] == true) == has then
		return
	end
	if has then
		accounts[key] = true
	else
		accounts[key] = nil
	end
	greed.fs.write(file, greed.json.encode(accounts))
end

-- Catches account `key` up on the messages kept to search (below).
local catch_up: (key: string) -> ()
-- The accounts caught up since the owner started.
local caught: { [string]: boolean } = {}

local function took(service: string, account: any)
	local taken: Account = account
	taken.service = service
	local key = `{service} {taken.id}`
	owned[key] = taken
	note(key, true)
	tell("account.changed", { service = service, params = taken })
	local can = capable[service]
	if taken.state.state == "ready" and can and can.history and not caught[key] then
		caught[key] = true
		greed.spawn(catch_up, key)
	end
end

-- A sign-in's step as views may see it: a finished one's account is taken
-- in and its secret kept here, never passed on.
local function finished(service: string, step: any): any
	if type(step) ~= "table" or step.step ~= "done" then
		return step
	end
	keep(service, step.account.id, step.secret)
	took(service, step.account)
	return { step = "done", account = step.account }
end

-- What a service says by itself.
local function heard(service: string, method: string, params: any)
	if method == "account.changed" then
		took(service, params)
	elseif method == "account.secret" then
		keep(service, params.account, params.secret)
	elseif method == "alert" then
		core.registry.tell(alert_listeners, `{service} {params.account}`, params)
	elseif method == "messages" then
		-- Kept to search here; views ask the owner what a search finds.
		greed.spawn(index.keep, service, `{service} {params.account}`, params.messages)
	elseif method == "unsaid" then
		greed.spawn(index.forget, `{service} {params.account}`, params.room, params.event)
	elseif method == "login.step" then
		tell(method, {
			service = service,
			params = { login = params.login, step = finished(service, params.step) },
		})
	else
		tell(method, { service = service, params = params })
	end
end

--- In the owner's session: `service`, started and its accounts restored if
--- it isn't running, or nil and why.
local function started(service: string): (Service?, string?)
	local found = running[service]
	if found then
		return found, nil
	end
	local program = M.program(service)
	-- Vouched for: only the service's own program, which may be asked for
	-- from a picker's choice.
	local options: greed.RpcOptions = {
		framing = "lines",
		env = core.file.companion_env(),
		on_notify = function(method: string, params: any)
			heard(service, method, params)
		end,
	}
	local connection_or_nil, err = greed.vouch(greed.rpc.start, { program, "serve" }, options)
	if connection_or_nil == nil then
		return nil, `couldn't start {program}: {err}`
	end
	local connection: greed.RpcConnection = connection_or_nil
	local hello = connection:request("hello", {})
	local speaks = if type(hello) == "table" then hello.protocol else nil
	if speaks ~= M.PROTOCOL then
		connection:close()
		return nil,
			`{program} speaks chat protocol {speaks or "?"}, this Greed {M.PROTOCOL}: use the one that came with this Greed`
	end
	capable[service] = set_of(hello.can)
	local wrapped: Service = {
		request = function(method: string, params: any): (any, string?)
			local result, trouble = connection:request(method, params)
			if trouble and not connection:alive() then
				running[service] = nil
				local said = string.match(connection:stderr(), `greed%-{service}: (.-)%s*$`)
				return nil, said or trouble
			end
			return result, trouble
		end,
	}
	running[service] = wrapped
	for id, secret in kept(service) do
		local account, why = wrapped.request("restore", { secret = secret })
		if account then
			took(service, account)
		else
			greed.echo(`chat: {id}: {why}`)
		end
	end
	return wrapped, nil
end

-- Asks `service` for `method` for the session `session`: a timeline stays
-- open while any session has it open, and a sign-in's secret stays here.
local function owner_ask(
	service: string,
	method: string,
	params: any,
	session: string
): (any, string?)
	if method == "timeline" or method == "timeline.close" then
		local which = `{service}|{params.account}|{params.room}|{params.thread or ""}`
		local sessions = opens[which] or {}
		if method == "timeline" then
			sessions[session] = true
			opens[which] = sessions
		else
			sessions[session] = nil
			if next(sessions) ~= nil then
				return nil
			end
			opens[which] = nil
		end
	elseif method == "read" then
		core.registry.tell(read_listeners, `{service} {params.account}`, params.room)
	end
	local found, err = started(service)
	if found == nil then
		return nil, err
	end
	local result, why = found.request(method, params)
	if method == "login.start" and type(result) == "table" then
		result.step = finished(service, result.step)
	elseif method == "login.answer" then
		result = finished(service, result)
	end
	return result, why
end

function catch_up(key: string)
	local service = M.split(key)
	index.catch_up(key, function(method: string, params: any): (any, string?)
		return owner_ask(service, method, params, "")
	end)
end

-- Signs `key` ("service id") out, and forgets its secret.
local function owner_logout(key: string): (any, string?)
	local account = owned[key]
	if account == nil then
		return nil, "no such account"
	end
	local found = running[account.service]
	local why: string? = nil
	if found then
		local _, trouble = found.request("logout", { account = account.id })
		why = trouble
	end
	keep(account.service, account.id, nil)
	owned[key] = nil
	note(key, false)
	tell("account.gone", { key = key })
	return true, why
end

--- In the owner's session: whether room `room` of account `key` is shown in
--- any session, as they said lately.
function M.shown_anywhere(key: string, room: string): boolean
	local now = os.time()
	for _, said in shown_by do
		if now - said.at <= SHOWN_FOR and said.rooms[`{key}|{room}`] then
			return true
		end
	end
	return false
end

--- In the owner's session: tells the views it raised `alert`.
function M.alerted(account: string, alert: Alert)
	tell("alerted", { account = account, alert = alert })
end

-- How much of a file one request carries, in bytes: files go between the
-- owner and views as data in pieces, never as a path on the owner's
-- machine.
M.PIECE = 512 * 1024

-- Files fetched for views to read in pieces, and files views are sending
-- in pieces, by handle.
local held: { [string]: string } = {}
local coming: { [string]: { string } } = {}

-- The file a message carries, fetched by its service, held for a view to
-- read: its handle and size.
local function media_open(service: string, params: any, session: string): (any, string?)
	local got, why = owner_ask(service, "media.get", params, session)
	if got == nil then
		return nil, why
	end
	local bytes, trouble = greed.fs.read_bytes(got.path)
	if bytes == nil then
		return nil, trouble
	end
	local handle = greed.hash.random(8)
	held[handle] = bytes
	return { handle = handle, size = #bytes }
end

-- The piece of held file `handle` from byte `from`; the last one lets it go.
local function media_read(handle: string, from: number): (any, string?)
	local bytes = held[handle]
	if bytes == nil then
		return nil, "that file isn't held any more"
	end
	if from + M.PIECE >= #bytes then
		held[handle] = nil
	end
	return { data = greed.base64.encode(string.sub(bytes, from + 1, from + M.PIECE)) }
end

-- A piece of a file a view sends; with the last, it's written here and
-- uploaded by `service` as `params` say, and goes once that's done.
local function media_put(params: any, session: string): (any, string?)
	local pieces = coming[params.handle] or {}
	coming[params.handle] = pieces
	local piece = greed.base64.decode(params.data)
	if piece == nil then
		coming[params.handle] = nil
		return nil, "a piece of the file came garbled"
	end
	table.insert(pieces, piece)
	if not params.last then
		return true
	end
	coming[params.handle] = nil
	local cache = greed.fs.dirs().cache
	if cache == nil then
		return nil, "there's no cache folder to keep the file in while it's sent"
	end
	local path = `{cache}/chat/sending/{params.handle}-{params.name}`
	local wrote, why = greed.fs.write(path, table.concat(pieces), { private = true })
	if not wrote then
		return nil, why
	end
	local upload: { [string]: any } = table.clone(params.params)
	upload.path = path
	local result, trouble = owner_ask(params.service, "upload", upload, session)
	greed.fs.remove(path)
	return result, trouble
end

-- What the owner answers views.
local function handle(method: string, params: any, caller: services.Caller): (any, string?)
	local session = caller.session or ""
	if method == "ask" then
		return owner_ask(params.service, params.method, params.params, session)
	elseif method == "search" then
		return index.search(params.parsed)
	elseif method == "media.open" then
		return media_open(params.service, params.params, session)
	elseif method == "media.read" then
		return media_read(params.handle, params.from)
	elseif method == "media.put" then
		return media_put(params, session)
	elseif method == "accounts" then
		local accounts: { Account } = {}
		for _, account in owned do
			table.insert(accounts, account)
		end
		local can: { [string]: { string } } = {}
		for service, set in capable do
			local names: { string } = {}
			for one in set do
				table.insert(names, one)
			end
			can[service] = greed.json.array(names)
		end
		return { accounts = greed.json.array(accounts), can = can }
	elseif method == "logout" then
		return owner_logout(params.key)
	elseif method == "shown" then
		local rooms: { [string]: boolean } = {}
		for _, one in params.rooms do
			rooms[one] = true
		end
		shown_by[session] = { rooms = rooms, at = os.time() }
		return true
	elseif method == "link" then
		tell("link", { link = params.link })
		return true
	end
	return nil, `chat has no {method}`
end

-- Starts every service that has accounts kept, so they connect.
local function start_kept()
	for _, service in M.SERVICES do
		if next(kept(service)) ~= nil then
			local _, err = started(service)
			if err then
				greed.echo(`chat: {err}`)
			end
		end
	end
end

-- Whether the owner has accounts: then it starts with Greed.
local function any_kept(): boolean
	return next(noted()) ~= nil
end

services.define({ name = "chat", start = any_kept })

if services.owner("chat") then
	offer = services.offer("chat", { version = VERSION, handle = handle })
	-- In its own session the accounts connect at once, so alerts come before
	-- anything asks; elsewhere (tests, no sessions) when first asked.
	if M.here() then
		greed.spawn(start_kept)
	end
end

-- The views: what this session shows, filled from the owner.

-- What the owner said happened.
local function dispatch(method: string, said: any)
	local params = said.params
	if method == "account.changed" then
		local account: Account = params
		account.service = said.service
		M.accounts[`{said.service} {account.id}`] = account
		core.registry.tell(account_listeners)
	elseif method == "account.gone" then
		M.accounts[said.key] = nil
		core.registry.tell(account_listeners)
	elseif method == "rooms.changed" then
		core.registry.tell(room_listeners, `{said.service} {params.account}`)
	elseif method == "timeline.changed" then
		core.registry.tell(
			timeline_listeners,
			`{said.service} {params.account}`,
			params.room,
			params.thread,
			params.changes
		)
	elseif method == "typing.changed" then
		core.registry.tell(
			typing_listeners,
			`{said.service} {params.account}`,
			params.room,
			params.who
		)
	elseif method == "verify.changed" then
		core.registry.tell(verify_listeners, `{said.service} {params.account}`, params)
	elseif method == "login.step" then
		core.registry.tell(step_listeners, params.login, params.step)
	elseif method == "alerted" then
		core.registry.tell(alerted_listeners, said.account, said.alert)
	elseif method == "link" then
		core.registry.tell(link_listeners, said.link)
	end
end

-- Fetches the accounts and what their services can do, as the owner has
-- them now.
local function refresh(view: services.View)
	local got = view:request("accounts")
	if got == nil then
		return
	end
	local accounts: { [string]: Account } = {}
	for _, account in got.accounts do
		accounts[`{account.service} {account.id}`] = account
	end
	M.accounts = accounts
	for service, can in got.can do
		M.can[service] = set_of(can)
	end
	core.registry.tell(account_listeners)
	core.registry.tell(reset_listeners)
end

local view = services.use("chat", {
	version = VERSION,
	topics = {
		"account.changed",
		"account.gone",
		"rooms.changed",
		"timeline.changed",
		"typing.changed",
		"verify.changed",
		"login.step",
		"alerted",
		"link",
	},
	on = dispatch,
	reset = refresh,
})

--- Asks `service` for `method`, through the owner: the result, or nil and
--- why.
function M.ask(service: string, method: string, params: any): (any, string?)
	return view:request("ask", { service = service, method = method, params = params })
end

--- Reaches the owner, starting it if it isn't running, and fetches the
--- accounts. Waits.
function M.start()
	if view:state() ~= "ready" then
		view:request("accounts")
	end
end

-- With accounts kept, every session's views connect as Greed starts, so a
-- verification asked from another device, or a sign-in's link, reaches
-- you wherever you are.
greed.on("editor.started", function()
	if greed.session.current() ~= nil and not services.owner("chat") and any_kept() then
		greed.spawn(M.start)
	end
end)

--- Signs `key` ("service id") out, and forgets its secret.
function M.logout(key: string): string?
	local _, why = view:request("logout", { key = key })
	return why
end

--- Tells the owner which rooms this session shows (as "key|room"), so it
--- doesn't alert you of one you're reading.
function M.showing(rooms: { string })
	view:request("shown", { rooms = greed.json.array(rooms) })
end

--- What a chat search runs over (`index.luau`).
M.source = index.source

--- The messages `parsed` finds in what the owner keeps, newest first
--- unless it sorts otherwise, or nil and why. Waits.
function M.search(parsed: core.Query): ({ index.Found }?, string?)
	return view:request("search", { parsed = parsed })
end

--- Hands the owner `link`, which a browser sign-in ended on, for the
--- session whose sign-in waits for it.
function M.pass_link(link: string): (any, string?)
	return view:request("link", { link = link })
end

--- The bytes of the file a message carries (`params`: account, room,
--- event, thumbnail), fetched by `service` through the owner in pieces, or
--- nil and why. Waits.
function M.media(service: string, params: any): (string?, string?)
	local opened, why = view:request("media.open", { service = service, params = params })
	if opened == nil then
		return nil, why
	end
	local pieces: { string } = {}
	local from = 0
	while from < opened.size do
		local got, trouble = view:request("media.read", { handle = opened.handle, from = from })
		local piece = if got then greed.base64.decode(got.data) else nil
		if piece == nil then
			return nil, trouble or "a piece of the file came garbled"
		end
		table.insert(pieces, piece :: string)
		from += M.PIECE
	end
	return table.concat(pieces), nil
end

--- Sends the file at `path` here to a room through `service` (`params`:
--- account, room, thread), in pieces through the owner: its result, or nil
--- and why. Waits.
function M.upload(service: string, params: any, path: string): (any, string?)
	local bytes, why = greed.fs.read_bytes(path)
	if bytes == nil then
		return nil, why
	end
	local handle = greed.hash.random(8)
	local name = string.match(path, "([^/]+)$") or "file"
	local from = 0
	repeat
		local last = from + M.PIECE >= #bytes
		local result, trouble = view:request("media.put", {
			handle = handle,
			data = greed.base64.encode(string.sub(bytes, from + 1, from + M.PIECE)),
			last = last,
			service = service,
			params = params,
			name = name,
		})
		if last or result == nil then
			return result, trouble
		end
		from += M.PIECE
	until false
end

--- Puts `fake` in `service`'s place, for tests: its methods answer by
--- name, and it can do what `can` says. Gives a function that sends a
--- notification as the service would.
function M.use(
	service: string,
	fake: { [string]: (params: any) -> (any, string?) },
	can: { string }?
): (method: string, params: any) -> ()
	capable[service] = set_of(can)
	M.can[service] = set_of(can)
	running[service] = {
		request = function(method: string, params: any): (any, string?)
			local answer = fake[method]
			if answer == nil then
				return nil, `no {method}`
			end
			return answer(params)
		end,
	}
	return function(method: string, params: any)
		heard(service, method, params)
	end
end

--- Forgets the services and accounts, for tests.
function M.reset()
	running = {}
	owned = {}
	capable = {}
	opens = {}
	shown_by = {}
	caught = {}
	M.accounts = {}
	M.can = {}
end

return M
