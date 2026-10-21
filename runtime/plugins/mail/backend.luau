-- What the mail view asks for its mail: `greed-mail serve`, started once
-- and kept running while the plugin is loaded, over JSON-RPC. It syncs in
-- the background and keeps an index the view searches itself; this asks
-- it where that is, what a list shows of what the search found, and a
-- thread's messages. Tests put a fake in its place (`use`).

local greed = require("@greed")
local core = require("@core")

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
	--- The index to search, or nil and why.
	index: () -> (greed.Index?, string?),
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

--- The session `greed mail` starts, which syncs the mail; others read what
--- it synced.
M.SESSION = "mail"

--- Whether this is the mail session.
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
	greed.plugin.tie(core.registry.put(listeners, listener))
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
	greed.plugin.tie(core.registry.put(arrivals, listener))
end

--- Says the mail with `keys` arrived, as greed-mail does (and a test).
function M.arrived(keys: { string })
	core.registry.tell(arrivals, keys)
end

--- What greed-mail is busy with, as it says: indexing (how far, of how
--- many), and each account's sync while it isn't all in (how many
--- messages so far).
export type Busy = {
	indexing: { done: number, of: number }?,
	syncing: { [string]: number },
}

M.busy = { syncing = {} } :: Busy

-- What wants to know when what greed-mail is busy with changed.
local busy_listeners: { () -> () } = {}

--- Calls `listener` whenever what greed-mail is busy with changes. It goes
--- with the plugin that added it.
function M.on_busy(listener: () -> ())
	greed.plugin.tie(core.registry.put(busy_listeners, listener))
end

--- Notes what greed-mail said it's doing (`indexing`, `progress`,
--- `synced`), as it does (and a test).
function M.heard(method: string, params: any)
	local busy = M.busy
	if method == "indexing" then
		busy.indexing = if params.done < params.of
			then { done = params.done, of = params.of }
			else nil
	elseif method == "progress" then
		busy.syncing[params.account] = params.messages
	elseif method == "synced" then
		busy.syncing[params.account] = if params.done then nil else params.messages
	else
		return
	end
	core.registry.tell(busy_listeners)
end

--- Which accounts greed-mail syncs and how much of each is in, in words,
--- or nil when none.
function M.syncing_text(): string?
	local syncing = M.busy.syncing
	local accounts: { string } = {}
	for account in syncing do
		table.insert(accounts, account)
	end
	table.sort(accounts)
	local said: { string } = {}
	for _, account in accounts do
		table.insert(said, `{account}: {core.text.count(syncing[account])} messages in`)
	end
	return if #said > 0 then `syncing {table.concat(said, ", ")}` else nil
end

-- Who waits for an attachment, by "key index", for greed-mail to say where
-- it went.
local awaiting: { [string]: greed.Signal } = {}

-- How long an attachment may take to come.
local PATIENCE = 120 * 1000

-- greed-mail, once it's started, and the index it keeps.
local connection: greed.RpcConnection? = nil
local opened: greed.Index? = nil

--- The greed-mail to run: the `mail-program` option's when it's set,
--- else the one beside this greed (as Greed's packages have it), else
--- the one on PATH.
function M.program(): string
	local set = tostring(greed.option.get("mail-program"))
	if set ~= "" then
		return set
	end
	local greed_program = greed.session.program()
	local folder = if greed_program then string.match(greed_program, "^(.*)/[^/]*$") else nil
	local beside = if folder then `{folder}/greed-mail` else nil
	if beside and greed.fs.stat(beside) then
		return beside
	end
	return "greed-mail"
end

-- greed-mail, started if it isn't running.
local function served(): (greed.RpcConnection?, string?)
	if connection and connection:alive() then
		return connection, nil
	end
	local program = M.program()
	-- Only the mail session syncs; anywhere else greed-mail reads what it
	-- synced.
	local command = if M.here() then { program, "serve" } else { program, "--read", "serve" }
	local started, err = greed.rpc.start(command, {
		framing = "lines",
		on_notify = function(method: string, params: any)
			if method == "arrived" then
				M.arrived(params.keys)
			elseif method == "changed" then
				changed()
			elseif method == "refused" then
				greed.echo(`{params.account}: {params.message}`)
			elseif method == "indexing" or method == "progress" or method == "synced" then
				M.heard(method, params)
			elseif method == "sent" then
				greed.echo("mail sent")
			elseif method == "attachment" then
				local waiting = awaiting[`{params.key} {params.index}`]
				if waiting then
					waiting:send(params)
				end
			end
		end,
	})
	if started == nil then
		return nil, `couldn't start {program}: {err}`
	end
	connection = started
	opened = nil
	return started, nil
end

-- The result of request `method`, or nil and why.
local function ask(method: string, params: any): (any, string?)
	local rpc, err = served()
	if rpc == nil then
		return nil, err
	end
	local result, trouble = rpc:request(method, params)
	if trouble then
		-- Gone, it said why as it went.
		local said = if rpc:alive()
			then trouble
			else string.match(rpc:stderr(), "greed%-mail: (.-)%s*$")
		return nil, said or `greed-mail: {trouble}`
	end
	return result
end

--- greed-mail.
M.served = {
	index = function(): (greed.Index?, string?)
		if opened then
			return opened, nil
		end
		local found, err = ask("index", {})
		if found == nil then
			return nil, err
		end
		local index, trouble = greed.index.open(found.path)
		opened = index
		-- Made by an older greed-mail: the mail session's makes it again.
		if index == nil and string.find(trouble or "", "another Greed", 1, true) then
			trouble = if M.here()
				then "your mail is being indexed again for this version of Greed: it shows once that's done"
				else "your mail isn't indexed for this version of Greed yet: :mail-session starts the mail session, which does it"
		end
		return index, trouble
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
