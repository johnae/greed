-- What the chat views ask of the services: `greed-matrix serve` and
-- `greed-mattermost serve`, each started when first needed and kept
-- running while the plugin is loaded, over JSON-RPC in one protocol. The
-- accounts' secrets (tokens and store keys) are kept in the keyring, one
-- secret a service (`chat-matrix`, `chat-mattermost`) holding its
-- accounts', and handed back to the service when it starts. Tests put a
-- fake in a service's place (`use`).

local greed = require("@greed")
local core = require("@core")

local M = {}

--- The services there are, as their programs are named.
M.SERVICES = { "matrix", "mattermost" }

--- The session `greed chat` starts, which keeps the accounts connected.
M.SESSION = "chat.service"

--- Whether this is the chat session.
function M.here(): boolean
	return greed.session.current() == M.SESSION
end

--- The protocol this speaks with the services, which they say in `hello`.
M.PROTOCOL = 1

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

-- Who wants to know what.
local account_listeners: { () -> () } = {}
local room_listeners: { (account: string) -> () } = {}
local timeline_listeners: { (account: string, room: string, thread: string?, changes: { any }) -> () } =
	{}
local typing_listeners: { (account: string, room: string, who: { string }) -> () } = {}
local step_listeners: { (login: string, step: any) -> () } = {}
local verify_listeners: { (account: string, about: any) -> () } = {}
local alert_listeners: { (account: string, alert: Alert) -> () } = {}

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

--- Calls `listener` with a new message for you, as the service decides.
function M.on_alert(listener: (account: string, alert: Alert) -> ())
	greed.plugin.cleanup(core.registry.put(alert_listeners, listener))
end

--- An account's service and its id there, from its key "service id".
function M.split(key: string): (string, string)
	local service, id = string.match(key, "^(%S+) (.*)$")
	return service or key, id or ""
end

--- Calls `listener` with a sign-in's next step when it comes by itself,
--- as when the browser came back.
function M.on_step(listener: (login: string, step: any) -> ())
	greed.plugin.cleanup(core.registry.put(step_listeners, listener))
end

--- What each service can do beyond what all do, as it says in `hello`:
--- "encryption", "threads"...
M.can = {} :: { [string]: { [string]: boolean } }

-- Notes that `service` can do what `can` lists.
local function set_can(service: string, can: { string }?)
	local set: { [string]: boolean } = {}
	local listed: { string } = can or {}
	for _, one in listed do
		set[one] = true
	end
	M.can[service] = set
end

--- The accounts signed in, by "service id".
M.accounts = {} :: { [string]: Account }

-- The services running, or put in place by a test.
local running: { [string]: Service } = {}

--- The program for `service`: its option's, else the one beside this
--- greed, else the one on PATH.
function M.program(service: string): string
	return core.file.companion(`chat-{service}-program`, `greed-{service}`)
end

-- The secret holding `service`'s accounts' secrets.
local function keyring_name(service: string): string
	return `chat-{service}`
end

-- `service`'s kept secrets, by account.
local function kept(service: string): { [string]: string }
	-- Vouched for, as the views ask from pickers and prompts: only chat's
	-- own secrets, and only these, are read and kept.
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

local function took(service: string, account: any)
	local taken: Account = account
	taken.service = service
	M.accounts[`{service} {taken.id}`] = taken
	core.registry.tell(account_listeners)
end

-- What a service says by itself.
local function heard(service: string, method: string, params: any)
	if method == "account.changed" then
		took(service, params)
	elseif method == "account.secret" then
		keep(service, params.account, params.secret)
	elseif method == "rooms.changed" then
		core.registry.tell(room_listeners, `{service} {params.account}`)
	elseif method == "timeline.changed" then
		core.registry.tell(
			timeline_listeners,
			`{service} {params.account}`,
			params.room,
			params.thread,
			params.changes
		)
	elseif method == "typing.changed" then
		core.registry.tell(typing_listeners, `{service} {params.account}`, params.room, params.who)
	elseif method == "verify.changed" then
		core.registry.tell(verify_listeners, `{service} {params.account}`, params)
	elseif method == "alert" then
		core.registry.tell(alert_listeners, `{service} {params.account}`, params)
	elseif method == "login.step" then
		core.registry.tell(step_listeners, params.login, params.step)
	end
end

--- `service`, started and its accounts restored if it isn't running, or
--- nil and why.
function M.service(service: string): (Service?, string?)
	local found = running[service]
	if found then
		return found, nil
	end
	local program = M.program(service)
	-- Vouched for: only the service's own program, which may be asked for
	-- from a picker's choice.
	local options: greed.RpcOptions = {
		framing = "lines",
		on_notify = function(method: string, params: any)
			heard(service, method, params)
		end,
	}
	local started, err = greed.vouch(greed.rpc.start, { program, "serve" }, options)
	if started == nil then
		return nil, `couldn't start {program}: {err}`
	end
	local connection: greed.RpcConnection = started
	local hello = connection:request("hello", {})
	local speaks = if type(hello) == "table" then hello.protocol else nil
	if speaks ~= M.PROTOCOL then
		connection:close()
		return nil,
			`{program} speaks chat protocol {speaks or "?"}, this Greed {M.PROTOCOL}: use the one that came with this Greed`
	end
	set_can(service, hello.can)
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

--- Asks `service` for `method`: the result, or nil and why.
function M.ask(service: string, method: string, params: any): (any, string?)
	local found, err = M.service(service)
	if found == nil then
		return nil, err
	end
	return found.request(method, params)
end

--- Starts every service that has accounts kept, so they connect.
function M.start()
	for _, service in M.SERVICES do
		if next(kept(service)) ~= nil then
			local _, err = M.service(service)
			if err then
				greed.echo(`chat: {err}`)
			end
		end
	end
end

--- Takes in a finished sign-in's account and keeps its secret.
function M.signed_in(service: string, done: any)
	keep(service, done.account.id, done.secret)
	took(service, done.account)
end

--- Signs `key` ("service id") out, and forgets its secret.
function M.logout(key: string): string?
	local account = M.accounts[key]
	if account == nil then
		return "no such account"
	end
	local _, why = M.ask(account.service, "logout", { account = account.id })
	keep(account.service, account.id, nil)
	M.accounts[key] = nil
	core.registry.tell(account_listeners)
	return why
end

--- Puts `fake` in `service`'s place, for tests: its methods answer by
--- name, and it can do what `can` says. Gives a function that sends a
--- notification as the service would.
function M.use(
	service: string,
	fake: { [string]: (params: any) -> (any, string?) },
	can: { string }?
): (method: string, params: any) -> ()
	set_can(service, can)
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
	M.accounts = {}
	M.can = {}
end

return M
