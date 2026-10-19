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
}

--- Something attached, as the message lists it.
export type Attachment = { name: string, mime: string, size: number }

--- A message as it's read; `text` nil until its body is in.
export type Message = Summary & {
	to: string,
	cc: string,
	text: string?,
	attachments: { Attachment },
	complete: boolean,
}

--- A thread: what it's called and its messages, oldest first.
export type Thread = { key: string, subject: string, messages: { Message } }

--- What the view needs from wherever its mail comes from.
export type Backend = {
	--- The index to search, or nil and why.
	index: () -> (greed.Index?, string?),
	--- What a list shows of the messages with `keys`, in that order.
	summaries: (keys: { string }) -> ({ Summary }?, string?),
	--- The thread `key` names, or the one message `key` is in.
	thread: (key: string) -> (Thread?, string?),
	--- Syncs now.
	sync: () -> (),
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
	doc = "The greed-mail program that syncs your mail: its name on PATH, or a path",
	default = "greed-mail",
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

-- greed-mail, once it's started, and the index it keeps.
local connection: greed.RpcConnection? = nil
local opened: greed.Index? = nil

-- greed-mail, started if it isn't running.
local function served(): (greed.RpcConnection?, string?)
	if connection and connection:alive() then
		return connection, nil
	end
	local program = tostring(greed.option.get("mail-program"))
	-- Only the mail session syncs; anywhere else greed-mail reads what it
	-- synced.
	local command = if M.here() then { program, "serve" } else { program, "--read", "serve" }
	local started, err = greed.rpc.start(command, {
		framing = "lines",
		on_notify = function(method: string)
			if method == "changed" then
				changed()
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
		return index, trouble
	end,
	summaries = function(keys: { string }): ({ Summary }?, string?)
		return ask("summaries", { keys = keys })
	end,
	thread = function(key: string): (Thread?, string?)
		return ask("thread", { key = key })
	end,
	sync = function()
		ask("sync", {})
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
