-- What the mail view asks for its mail, through the `mail` service
-- (`@service`). Its owner, in the mail service's session, runs `greed-mail
-- serve` over JSON-RPC, which syncs in the background and keeps an index,
-- and searches it; views in every session ask the owner what a search
-- finds, what a list shows of it, and a thread's messages, and hear from it
-- what greed-mail says. Tests put a fake in its place (`use`).

local greed = require("@greed")
local core = require("@core")
local services = require("@service")

local M = {}

--- A message as a list shows it.
export type Summary = {
	key: string,
	thread: string?,
	from: string,
	subject: string,
	date: string?,
	unread: boolean,
	flagged: boolean,
	--- Where it is and what it's tagged with, as `in:` finds it.
	tags: { string },
	--- In a list of threads, the messages found of its thread, newest
	--- first: what a change to the row changes.
	found: { string }?,
	--- Its Message-ID, without the `<>`: what a `mail:` link names.
	message_id: string?,
	--- How many things are attached to it (in a list of threads, to the
	--- messages found), once its body is in.
	attached: number?,
}

--- Something attached, as the message lists it.
export type Attachment = { name: string, mime: string, size: number }

--- Someone an invite names, and their answer (ACCEPTED, TENTATIVE,
--- DECLINED, NEEDS-ACTION) for an attendee.
export type Person = { name: string?, address: string, answer: string? }

--- An invite a message carries: what `method` (REQUEST asks, CANCEL, REPLY
--- answers yours), when (RFC 3339 in local time, a date when `all_day`),
--- who, and your `answer` so far.
export type Invite = {
	method: string,
	summary: string,
	location: string?,
	start: string?,
	["end"]: string?,
	all_day: boolean,
	organizer: Person?,
	attendees: { Person },
	repeats: boolean,
	cancelled: boolean,
	answer: string?,
}

--- A message as it's read; `text` nil until its body is in.
export type Message = Summary & {
	to: string,
	cc: string,
	text: string?,
	attachments: { Attachment },
	complete: boolean,
	--- Whether it has an HTML part, which `render` lays out.
	html: boolean,
	invite: Invite?,
}

--- A thread: what it's called and its messages, oldest first.
export type Thread = { key: string, subject: string, messages: { Message } }

--- A message's HTML as it reads: lines of spans, each styled (strong,
--- emphasis, code, strike, link, image) or not, a link's span saying which
--- of `links` (from 0) it goes to.
export type Rendered = {
	lines: { { { text: string, style: string?, link: number? } } },
	links: { string },
}

--- Mail as it's written: addresses apart by commas, and the key of the
--- message it answers.
export type Draft = {
	--- Who it's from: an account's address or one of its aliases.
	from: string?,
	to: string,
	cc: string,
	bcc: string,
	--- Where replies to it go, when not to who it's from.
	reply_to: string?,
	subject: string,
	text: string,
	replying: string?,
	--- Whether its text is Markdown, sent with the HTML it makes.
	markdown: boolean?,
	--- The files it carries, by path.
	attach: { string }?,
}

--- How mail goes out from one of an account's addresses: the name its
--- From line shows, its signature, where replies go and a copy to
--- yourself, as mail.toml says.
export type Identity = {
	address: string,
	display_name: string?,
	signature: string?,
	reply_to: string?,
	bcc: string?,
	--- Whether new mail is from it (mail.toml's `from`).
	default: boolean?,
}

--- An account in mail.toml: what it's called, its address and the
--- others it sends from, and how mail goes out from each.
export type Account = {
	name: string,
	address: string,
	aliases: { string },
	identities: { Identity }?,
}

--- What the view needs from wherever its mail comes from.
export type Backend = {
	--- The keys of the messages `parsed` finds, sorted and cut as its view
	--- says, or nil and why.
	search: (parsed: core.Query) -> ({ string }?, string?),
	--- What a list shows of the messages with `keys`, in that order.
	summaries: (keys: { string }) -> ({ Summary }?, string?),
	--- The thread `key` names, or the one message `key` is in.
	thread: (key: string) -> (Thread?, string?),
	--- The key of the message whose Message-ID is `id`, or nil and why.
	find: (id: string) -> (string?, string?),
	--- Syncs now.
	sync: () -> (),
	--- Makes `action` (read, unread, flag, unflag, archive, trash, or tag
	--- and untag with `tag`) on the messages and threads `keys` name;
	--- gives how many it changed, or nil and why. Trashing what's in the
	--- trash deletes it for good, only `for_good`: otherwise it changes
	--- nothing and gives how many are in the trash third.
	act: (
		keys: { string },
		action: string,
		tag: string?,
		for_good: boolean?
	) -> (number?, string?, number?),
	--- Undoes the last change, or takes back the mail just sent while it
	--- waits: "changes" or "sent", or nil and why not.
	undo: () -> (string?, string?),
	--- A reply to the message `key`, to everyone it went to with `all`.
	draft: (key: string, all: boolean) -> (Draft?, string?),
	--- The accounts, in mail.toml's order.
	accounts: () -> { Account },
	--- People whose name or address starts as `typed`, as "Name
	--- <address>": those you write to most first.
	contacts: (typed: string) -> { string },
	--- Sends `draft` after a few seconds (how many, third), in which `undo`
	--- takes it back; or says why it can't.
	send: (draft: Draft) -> (boolean, string?, number?),
	--- Sends `answer` (accepted, tentative, declined) to the invite in the
	--- message `key` to its organizer, or says why it can't.
	respond: (key: string, answer: string) -> (boolean, string?),
	--- The message `key`'s HTML laid out `width` cells wide; nil when it
	--- has none.
	render: (key: string, width: number) -> Rendered?,
	--- The message `key`'s HTML as a page that loads nothing, for a
	--- browser: where it is, or nil and why.
	browse: (key: string) -> (string?, string?),
	--- Thing number `index` (from 0) attached to the message `key`, saved
	--- `to` a path or kept beside the store: where it is, once it's there,
	--- or nil and why.
	attachment: (key: string, index: number, to: string?) -> (string?, string?),
}

--- The session of the mail service, which syncs the mail; `greed mail`
--- shows it.
M.SESSION = services.session_of("mail")

--- Whether this is the mail service's session.
function M.here(): boolean
	return greed.session.current() == M.SESSION
end

greed.option.define({
	name = "mail-program",
	doc = "The greed-mail program that syncs your mail, its name on PATH or a path; empty for the one beside greed, or else on PATH",
	default = "",
})

-- What wants to know when the index changed.
local listeners: { () -> () } = {}

--- Calls `listener` whenever the mail changed: new mail, flags, a body
--- that came. It goes with the plugin that added it.
function M.on_changed(listener: () -> ())
	greed.plugin.cleanup(core.registry.put(listeners, listener))
end

local function changed()
	core.registry.tell(listeners)
end

-- What wants to know of new mail.
local arrivals: { (keys: { string }) -> () } = {}

--- Calls `listener` with the keys of mail that arrived, once it's in the
--- index: new since its mailbox was all in, never what a first sync
--- brings. It goes with the plugin that added it.
function M.on_arrived(listener: (keys: { string }) -> ())
	greed.plugin.cleanup(core.registry.put(arrivals, listener))
end

--- Says the mail with `keys` arrived, as greed-mail does (and a test).
function M.arrived(keys: { string })
	core.registry.tell(arrivals, keys)
end

--- An account's sync while it isn't all in: how many messages are here,
--- of how many on the server when it says.
export type Syncing = { account: string, messages: number, of: number? }

--- What greed-mail is busy with, as it says: indexing (how far, of how
--- many), each account's sync while it isn't all in, the password commands
--- it waits on (by account, the program), and what went wrong syncing an
--- account, until a round goes well.
export type Busy = {
	indexing: { done: number, of: number }?,
	syncing: { [string]: Syncing },
	waiting: { [string]: string },
	trouble: { [string]: string },
}

M.busy = { syncing = {}, waiting = {}, trouble = {} } :: Busy

-- What wants to know when what greed-mail is busy with changed.
local busy_listeners: { () -> () } = {}

--- Calls `listener` whenever what greed-mail is busy with changes. It goes
--- with the plugin that added it.
function M.on_busy(listener: () -> ())
	greed.plugin.cleanup(core.registry.put(busy_listeners, listener))
end

-- What wants to know when an account's round of syncing is over.
local synced_listeners: { (account: string) -> () } = {}

--- Calls `listener` with an account's name each time a round of its sync
--- is over. It goes with the plugin that added it.
function M.on_synced(listener: (account: string) -> ())
	greed.plugin.cleanup(core.registry.put(synced_listeners, listener))
end

--- Notes what greed-mail said it's doing (`indexing`, `progress`,
--- `synced`, `waiting`, `trouble`), as it does (and a test).
function M.heard(method: string, params: any)
	local busy = M.busy
	if method == "indexing" then
		busy.indexing = if params.done < params.of
			then { done = params.done, of = params.of }
			else nil
	elseif method == "progress" or method == "synced" then
		local account: string = params.account
		if method == "synced" and params.done then
			busy.syncing[account] = nil
		else
			busy.syncing[account] =
				{ account = account, messages = params.messages, of = params.of }
		end
		busy.trouble[account] = nil
		if method == "synced" then
			core.registry.tell(synced_listeners, account)
		end
	elseif method == "waiting" then
		busy.waiting[params.account] = params.program
	elseif method == "trouble" then
		busy.trouble[params.account] = params.message
	else
		return
	end
	core.registry.tell(busy_listeners)
end

--- The accounts greed-mail syncs, by name.
function M.syncing(): { Syncing }
	local list: { Syncing } = {}
	for _, one in M.busy.syncing do
		table.insert(list, one)
	end
	table.sort(list, function(a: Syncing, b: Syncing): boolean
		return a.account < b.account
	end)
	return list
end

--- What keeps accounts from syncing, in words, one line each: a password
--- command waiting (to be unlocked, most likely), or what went wrong.
function M.stuck_lines(): { string }
	local busy = M.busy
	local accounts: { string } = {}
	for account in busy.waiting do
		table.insert(accounts, account)
	end
	for account in busy.trouble do
		if not busy.waiting[account] then
			table.insert(accounts, account)
		end
	end
	table.sort(accounts)
	local lines: { string } = {}
	for _, account in accounts do
		local program = busy.waiting[account]
		local trouble = busy.trouble[account] or ""
		-- Some say which account already, as greed-mail's own errors do.
		local prefix = `{account}: `
		local named = string.sub(trouble, 1, #prefix) == prefix
		table.insert(
			lines,
			if program
				then `{account}: waiting for {program} to give the password; is it locked?`
				elseif named then trouble
				else `{account}: {trouble}`
		)
	end
	return lines
end

-- Who waits for an attachment, by "key index", for greed-mail to say where
-- it went.
local awaiting: { [string]: greed.Signal } = {}

-- How long an attachment may take to come.
local PATIENCE = 120 * 1000

-- The owner's greed-mail, once it's started, and the index it keeps,
-- searched here.
local connection: greed.RpcConnection? = nil
local opened: greed.Index? = nil
local offer: services.Offer? = nil

-- What greed-mail says by itself, as each session hears it from the owner.
local function heard(method: string, params: any)
	if method == "arrived" then
		M.arrived(params.keys)
	elseif method == "changed" then
		changed()
	elseif method == "refused" then
		greed.echo(`{params.account}: {params.message}`)
	elseif
		method == "indexing"
		or method == "progress"
		or method == "synced"
		or method == "waiting"
		or method == "trouble"
	then
		M.heard(method, params)
	elseif method == "sent" then
		greed.echo("mail sent")
	elseif method == "attachment" then
		local waiting = awaiting[`{params.key} {params.index}`]
		if waiting then
			waiting:send(params)
		end
	end
end

--- The requests and notifications this speaks with greed-mail: its
--- `PROTOCOL` (serve.rs) must be the same, which it says in `hello`.
M.PROTOCOL = 1

--- The greed-mail to run: the `mail-program` option's when it's set,
--- else the one beside this greed (as Greed's packages have it), else
--- the one on PATH.
function M.program(): string
	return core.file.companion("mail-program", "greed-mail")
end

-- Why greed-mail at `rpc` didn't answer: what it said as it went, when it
-- went, else `trouble`.
local function gone_why(rpc: greed.RpcConnection, trouble: string): string
	if rpc:alive() then
		return trouble
	end
	local said = string.match(rpc:stderr(), "greed%-mail: (.-)%s*$")
	return said or `greed-mail: {trouble}`
end

-- In the owner's session: greed-mail, started if it isn't running. What
-- asks while it starts waits for that one: a second would find the store
-- taken and stop.
local served = core.joined(function(): (greed.RpcConnection?, string?)
	if connection and connection:alive() then
		return connection, nil
	end
	local program = M.program()
	local started, err = greed.rpc.start({ program, "serve" }, {
		framing = "lines",
		env = core.file.companion_env(),
		-- Every session hears it, this one too.
		on_notify = function(method: string, params: any)
			if offer then
				offer:notify(method, params)
			end
		end,
	})
	if started == nil then
		return nil, `couldn't start {program}: {err}`
	end
	-- One that speaks otherwise would misread what's asked of it, and
	-- this what it says: so first it says which it speaks.
	local hello, trouble = started:request("hello", {})
	local speaks = if type(hello) == "table" then hello.protocol else nil
	if speaks ~= M.PROTOCOL then
		local gone = if started:alive() then nil else gone_why(started, trouble or "it exited")
		started:close()
		if gone then
			return nil, gone
		end
		if speaks == nil then
			return nil,
				`{program} is older than this Greed ({trouble or "it doesn't say which protocol it speaks"}): rebuild or update it, or :set mail-program to the one beside greed`
		end
		local newer = if speaks > M.PROTOCOL then "newer" else "older"
		return nil,
			`{program} speaks mail protocol {speaks}, this Greed {M.PROTOCOL}: it's {newer}; use the greed-mail that came with this Greed`
	end
	connection = started
	opened = nil
	return started, nil
end)

-- In the owner's session: the result of greed-mail's request `method`, or
-- nil and why.
local function owner_ask(method: string, params: any): (any, string?)
	local rpc, err = served("")
	if rpc == nil then
		return nil, err
	end
	local result, trouble = rpc:request(method, params)
	if trouble ~= nil then
		local said: string = trouble
		return nil, gone_why(rpc, said)
	end
	return result
end

--- What a search's fields and flags mean (the mail plugin's), for the
--- owner to run what views ask it to find.
M.source = nil :: core.QuerySource?

-- In the owner's session: the keys of the messages `parsed` finds in
-- greed-mail's index, or nil and why. Views never open the index: what
-- they search goes to the owner as data.
local function owner_search(parsed: core.Query): ({ string }?, string?)
	if opened == nil then
		local found, err = owner_ask("index", {})
		if found == nil then
			return nil, err
		end
		local index, trouble = greed.index.open(found.path)
		if index == nil then
			-- Made by an older greed-mail: the mail service makes it again.
			if string.find(trouble or "", "another Greed", 1, true) then
				return nil,
					"your mail is being indexed again for this version of Greed: it shows once that's done"
			end
			return nil, trouble
		end
		opened = index
	end
	local source = M.source
	if source == nil then
		return nil, "mail can't search yet"
	end
	local keys, _, trouble = core.query.search(opened :: greed.Index, parsed, source)
	return keys, trouble
end

-- Whether there's mail to sync: then its owner starts with Greed.
local function configured(): boolean
	local config = greed.fs.dirs().config
	return config ~= nil and greed.fs.stat(`{config}/mail.toml`) ~= nil
end

services.define({ name = "mail", start = configured })

if services.owner("mail") then
	offer = services.offer("mail", {
		version = 1,
		handle = function(method: string, params: any): (any, string?)
			if method == "ask" then
				return owner_ask(params.method, params.params)
			elseif method == "search" then
				return owner_search(params.parsed)
			end
			return nil, `mail has no {method}`
		end,
	})
end

local view = services.use("mail", {
	version = 1,
	topics = {
		"arrived",
		"changed",
		"refused",
		"indexing",
		"progress",
		"synced",
		"waiting",
		"trouble",
		"sent",
		"attachment",
	},
	on = heard,
	-- Reached, or the owner started again: what was found may have
	-- changed, and how the sync stands is asked rather than waited for.
	reset = function(reached: services.View)
		changed()
		local status = reached:request("ask", { method = "status", params = {} })
		for _, account in if status then status.accounts or {} else {} do
			if not account.done then
				M.heard(
					"progress",
					{ account = account.name, messages = account.messages, of = account.of }
				)
			end
			if account.trouble then
				M.heard("trouble", { account = account.name, message = account.trouble })
			end
		end
	end,
})

-- The result of greed-mail's request `method`, through the owner, or nil
-- and why.
local function ask(method: string, params: any): (any, string?)
	return view:request("ask", { method = method, params = params })
end

--- greed-mail.
M.served = {
	search = function(parsed: core.Query): ({ string }?, string?)
		return view:request("search", { parsed = parsed })
	end,
	summaries = function(keys: { string }): ({ Summary }?, string?)
		return ask("summaries", { keys = keys })
	end,
	thread = function(key: string): (Thread?, string?)
		return ask("thread", { key = key })
	end,
	find = function(id: string): (string?, string?)
		local found, err = ask("find", { message_id = id })
		return if found then found.key else nil, err
	end,
	sync = function()
		ask("sync", {})
	end,
	act = function(
		keys: { string },
		action: string,
		tag: string?,
		for_good: boolean?
	): (number?, string?, number?)
		local done, err =
			ask("act", { keys = keys, action = action, tag = tag, for_good = for_good })
		if done == nil then
			return nil, err, nil
		end
		return done.changed, nil, done.in_trash
	end,
	undo = function(): (string?, string?)
		local done, err = ask("undo", {})
		return if done then done.undone else nil, err
	end,
	draft = function(key: string, all: boolean): (Draft?, string?)
		return ask("draft", { key = key, all = all })
	end,
	accounts = function(): { Account }
		return ask("accounts", {}) or {}
	end,
	contacts = function(typed: string): { string }
		return ask("contacts", { typed = typed }) or {}
	end,
	send = function(draft: Draft): (boolean, string?, number?)
		local posted, err = ask("send", draft)
		return posted ~= nil, err, if posted then posted.seconds else nil
	end,
	respond = function(key: string, answer: string): (boolean, string?)
		local posted, err = ask("respond", { key = key, answer = answer })
		return posted ~= nil, err
	end,
	render = function(key: string, width: number): Rendered?
		return ask("render", { key = key, width = width })
	end,
	browse = function(key: string): (string?, string?)
		local page, err = ask("browse", { key = key })
		return if page then page.path else nil, err
	end,
	attachment = function(key: string, index: number, to: string?): (string?, string?)
		local asked, err = ask("attachment", { key = key, index = index, to = to })
		if asked == nil then
			return nil, err
		elseif asked.path then
			return asked.path, nil
		end
		-- Fetched in the sync's next step, it says when it's there.
		local at = `{key} {index}`
		local done = greed.signal()
		awaiting[at] = done
		greed.spawn(function()
			greed.sleep(PATIENCE)
			done:send({ error = "it didn't come: the server may be slow, try again" })
		end)
		local got = done:wait()
		awaiting[at] = nil
		return got.path, got.error
	end,
} :: Backend

-- What the view uses: greed-mail, or what a test put in its place.
local using: Backend = M.served

--- What the view uses now.
function M.get(): Backend
	return using
end

--- Puts `backend` in greed-mail's place, as tests do; nil for greed-mail.
--- Gives the function that says the mail changed, for a fake to call.
function M.use(backend: Backend?): () -> ()
	using = backend or M.served
	return changed
end

return M
