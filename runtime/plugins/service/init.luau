-- Services: state that lives in one place, the session of its owner, shown
-- and acted on from any session through views. The owner offers a service;
-- a view uses it, in the owner's session directly and elsewhere over the
-- owner's session socket, through `greed mcp` started for that session.
-- Greed starts the owner's session when a view needs it.
--
-- On the socket, as JSON-RPC: `service/hello` (which version the owner
-- speaks, and its incarnation: an id that changes whenever it starts
-- again), `service/listen` and `service/ignore` (topics), `service/request`,
-- and the owner's `service/notify` to views listening.

local greed = require("@greed")
local core = require("@core")
local agent = require("@agent")

local registry = core.registry

local M = {}

--- Who asked an owner: the session a view is in, as it said.
export type Caller = { session: string? }

--- When an owner starts: when a view first needs it, when Greed starts, or
--- when Greed starts if the function says so.
export type Start = "use" | "always" | () -> boolean

export type Definition = { name: string, start: Start? }

export type OfferSpec = {
	version: number,
	handle: (method: string, params: any, caller: Caller) -> (any, string?),
}

--- How a view is: not connected yet (`idle`), `connecting`, `ready`, or
--- `unreachable`.
export type State = "idle" | "connecting" | "ready" | "unreachable"

export type ViewSpec = {
	version: number,
	topics: { string }?,
	on: ((topic: string, params: any) -> ())?,
	reset: ((view: View) -> ())?,
}

export type Offer = {
	--- Tells every view listening to `topic` that something changed.
	notify: (self: Offer, topic: string, params: any) -> (),
}

export type View = {
	--- Asks the owner and waits for the answer: the result, or nil and why.
	request: (
		self: View,
		method: string,
		params: any?,
		opts: { timeout: number? }?
	) -> (any, string?),
	listen: (self: View, topic: string) -> (),
	ignore: (self: View, topic: string) -> (),
	--- How it is, and since when (seconds since 1970) once unreachable,
	--- with why.
	state: (self: View) -> (State, number?, string?),
	--- Lets go of the owner; the view is done.
	close: (self: View) -> (),
}

--- A connection to an owner's session, as `greed.rpc.start` makes them.
export type Link = {
	request: (self: Link, method: string, params: any) -> (any, string?),
	close: (self: Link) -> (),
}

--- How long a request waits by default, in seconds.
M.TIMEOUT = 30

--- How often connecting is tried before the owner counts as unreachable,
--- and the wait before trying again, in milliseconds: an owner's session
--- listens before its plugins have offered anything.
M.TRIES = 20
M.RETRY = 250

--- How long a view that listens waits before connecting again after the
--- link went, in milliseconds.
M.AGAIN = 2000

--- The name of the session the owner of `name` runs in.
function M.session_of(name: string): string
	return `{name}.service`
end

--- This session's name. Tests put theirs in its place.
function M.session(): string?
	return greed.session.current()
end

--- Starts the session `session` in the background unless it runs. Tests
--- put theirs in its place.
function M.start(session: string): (boolean?, string?)
	return greed.session.start(session)
end

--- Connects to the session `session`. Tests put theirs in its place.
function M.connect(
	session: string,
	on_notify: (method: string, params: any) -> (),
	on_exit: (why: string) -> ()
): (Link?, string?)
	local program = greed.session.program()
	if not program then
		return nil, "can't tell where greed is"
	end
	local env: { [string]: string | false } = { GREED_SESSION = session, GREED_TERMINAL = false }
	local options: greed.RpcOptions = {
		framing = "lines",
		env = env,
		on_notify = on_notify,
		on_exit = on_exit,
	}
	local conn, err = greed.vouch(greed.rpc.start, { program, "mcp" }, options)
	return conn :: any, err
end

--- Sends a notification to the socket connection `connection`. Tests put
--- theirs in its place.
function M.send(connection: number, method: string, params: any): boolean
	return greed.vouch(greed.control.send, connection, method, params)
end

type Defined = { definition: Definition, plugin: string? }

type Offered = {
	name: string,
	spec: OfferSpec,
	-- `spec.handle`, run as the owner's plugin, whoever passed it the
	-- request (greed.plugin.handler).
	handle: (method: string, params: any, caller: Caller) -> (any, string?),
	incarnation: string,
	-- The topics each socket connection listens to.
	listeners: { [number]: { [string]: boolean } },
}

type Viewing = {
	name: string,
	spec: ViewSpec,
	topics: { [string]: boolean },
	state: State,
	since: number?,
	why: string?,
	link: Link?,
	-- Whether it reaches the owner in this session, not over a link.
	direct: boolean,
	-- Whether something needed it, so it connects again once the link goes.
	wanted: boolean,
	connecting: boolean,
	waiting: { greed.Signal },
	closed: boolean,
	view: View,
}

local defined: { [string]: Defined } = {}
local offers: { [string]: Offered } = {}
-- The views of each service in this session.
local views: { [string]: { Viewing } } = {}
-- What each socket connection said of itself in its hello.
local hellos: { [number]: Caller } = {}

local function sorted<T>(t: { [string]: T }): { string }
	local keys = {}
	for key in t do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

--- Says there's a service called `definition.name`, and when its owner
--- starts. Two can't share a name. It goes when the plugin does.
function M.define(definition: Definition)
	local had = defined[definition.name]
	if had then
		error(
			`there's a service called {definition.name} already, from {had.plugin or "your config"}`,
			2
		)
	end
	local start = definition.start
	if type(start) == "function" then
		-- Run later from here, it checks with the defining plugin's
		-- capabilities, as `handle` does.
		definition = table.clone(definition)
		definition.start = greed.plugin.handler(start)
	end
	local entry: Defined = { definition = definition, plugin = nil }
	entry.plugin = greed.plugin.cleanup(registry.set(defined, definition.name, entry))
end

--- The services defined, by name.
function M.defined(): { string }
	return sorted(defined)
end

--- Whether this is the session of `name`'s owner. An editor that isn't a
--- session (`GREED_NO_SESSION`, tests) has no other to reach: it owns
--- every service itself.
function M.owner(name: string): boolean
	local here = M.session()
	return here == nil or here == M.session_of(name)
end

-- Every waiter on `v` goes on, now that it's ready or not.
local function settle(v: Viewing)
	local waiting = v.waiting
	v.waiting = {}
	for _, signal in waiting do
		signal:send(true)
	end
end

local function went(v: Viewing, why: string)
	v.state = "unreachable"
	v.since = os.time()
	v.why = why
	settle(v)
end

-- `v` reaches its owner now: whoever waited goes on, and it fetches what it
-- shows.
local function became_ready(v: Viewing)
	v.state = "ready"
	v.since = nil
	v.why = nil
	settle(v)
	local reset = v.spec.reset
	if reset then
		greed.spawn(reset, v.view)
	end
end

-- Why `v` can't use an owner speaking `version`.
local function mismatch(v: Viewing, version: number): string
	local service = M.session_of(v.name)
	if version < v.spec.version then
		return `{service} speaks version {version} of {v.name} and this session {v.spec.version}: `
			.. `:service-restart {v.name} starts it again with this greed`
	end
	return `{service} speaks version {version} of {v.name} and this session only {v.spec.version}: `
		.. "this session is older, restart it"
end

local connect: (v: Viewing) -> ()

-- Connects `v` again after a while, if something still needs it.
local function again(v: Viewing)
	greed.spawn(function()
		greed.sleep(M.AGAIN)
		if not v.closed and v.wanted and next(v.topics) ~= nil and v.state == "unreachable" then
			connect(v)
		end
	end)
end

-- Tries to reach `v`'s owner, starting its session if need be, until it
-- answers or it's tried enough; sets `v`'s state either way. Runs as a task.
function connect(v: Viewing)
	if v.connecting or v.closed then
		return
	end
	v.connecting = true
	v.state = "connecting"
	if M.owner(v.name) then
		-- In the owner's session: ready once it offers.
		v.direct = true
		v.connecting = false
		if offers[v.name] then
			became_ready(v)
		end
		return
	end
	local session = M.session_of(v.name)
	local why = `{v.name} isn't reachable`
	for try = 1, M.TRIES do
		if v.closed then
			v.connecting = false
			return
		end
		local started, failed = M.start(session)
		if started then
			local link: Link?
			local function heard(method: string, params: any)
				if
					method == "service/notify"
					and params
					and params.service == v.name
					and v.link == link
				then
					local on = v.spec.on
					if on and v.topics[params.topic] then
						on(params.topic, params.params)
					end
				end
			end
			local function exited()
				if link and v.link == link then
					v.link = nil
					went(v, `the {v.name} service went`)
					again(v)
				end
			end
			local made, err = M.connect(session, heard, exited)
			link = made
			if made then
				local hello, refused = made:request(
					"service/hello",
					{ service = v.name, version = v.spec.version, session = M.session() }
				)
				if hello and hello.version ~= v.spec.version then
					made:close()
					v.connecting = false
					went(v, mismatch(v, hello.version))
					return
				elseif hello then
					v.link = made
					local topics = sorted(v.topics)
					if #topics > 0 then
						made:request("service/listen", { service = v.name, topics = topics })
					end
					v.connecting = false
					became_ready(v)
					return
				end
				made:close()
				why = refused or why
			else
				why = err or why
			end
		else
			why = failed or why
		end
		if try < M.TRIES then
			greed.sleep(M.RETRY)
		end
	end
	v.connecting = false
	went(v, why)
end

-- How `v` is now; a function, as connecting changes it while code waits.
local function state_of(v: Viewing): State
	return v.state
end

-- Waits until `v` is ready, at most `timeout` seconds; why not, if it isn't.
local function ready(v: Viewing, timeout: number): string?
	if v.closed then
		return "the view was closed"
	end
	v.wanted = true
	if state_of(v) == "ready" then
		return nil
	end
	if not v.connecting then
		greed.spawn(connect, v)
	end
	if state_of(v) == "ready" then
		return nil
	elseif state_of(v) == "unreachable" and not v.connecting then
		return v.why
	end
	local signal = greed.signal()
	table.insert(v.waiting, signal)
	greed.spawn(function()
		greed.sleep(timeout * 1000)
		signal:send(false)
	end)
	signal:wait()
	if state_of(v) == "ready" then
		return nil
	end
	return v.why or `{v.name} isn't ready yet`
end

-- `request`'s answer, or why there's none within `timeout` seconds.
local function within(timeout: number, ask: () -> (any, string?)): (any, string?)
	local signal = greed.signal()
	greed.spawn(function()
		local result, why = ask()
		signal:send({ ok = true, result = result, why = why })
	end)
	greed.spawn(function()
		greed.sleep(timeout * 1000)
		signal:send({ ok = false })
	end)
	local got = signal:wait()
	if not got.ok then
		return nil, `no answer within {timeout} s`
	end
	return got.result, got.why
end

--- The owner offers `name` to views; only in its own session. It goes when
--- the plugin does.
function M.offer(name: string, spec: OfferSpec): Offer
	if not M.owner(name) then
		error(`{name} is offered in its own session, {M.session_of(name)}`, 2)
	end
	local offered: Offered = {
		name = name,
		spec = spec,
		handle = greed.plugin.handler(spec.handle),
		incarnation = greed.hash.random(8),
		listeners = {},
	}
	greed.plugin.cleanup(registry.set(offers, name, offered))
	local offer = {} :: Offer
	function offer.notify(_, topic: string, params: any)
		for connection, topics in offered.listeners do
			if topics[topic] then
				M.send(connection, "service/notify", {
					service = name,
					incarnation = offered.incarnation,
					topic = topic,
					params = params,
				})
			end
		end
		for _, v in views[name] or {} :: { Viewing } do
			local on = v.spec.on
			if v.direct and v.state == "ready" and on and v.topics[topic] then
				greed.spawn(on, topic, params)
			end
		end
	end
	-- Views here that waited for it reach it now.
	for _, v in views[name] or {} :: { Viewing } do
		if v.direct and v.state ~= "ready" and not v.closed then
			became_ready(v)
		end
	end
	return offer
end

--- A view of `name`, in this session. It connects the first time it's
--- needed, starting the owner's session if it isn't running; in the
--- owner's own session it's ready as soon as the service is offered. It
--- goes when the plugin does.
function M.use(name: string, spec: ViewSpec): View
	local topics: { [string]: boolean } = {}
	for _, topic in spec.topics or {} :: { string } do
		topics[topic] = true
	end
	local v: Viewing = {
		name = name,
		spec = spec,
		topics = topics,
		state = "idle",
		since = nil,
		why = nil,
		link = nil,
		direct = M.owner(name),
		wanted = false,
		connecting = false,
		waiting = {},
		closed = false,
		view = nil :: any,
	}
	local view = {} :: View
	v.view = view

	function view.request(
		_,
		method: string,
		params: any?,
		opts: { timeout: number? }?
	): (any, string?)
		local timeout = opts and opts.timeout or M.TIMEOUT
		local why = ready(v, timeout)
		if why then
			return nil, why
		end
		if v.direct then
			local offered = offers[name]
			if not offered then
				return nil, `{name} isn't offered any more`
			end
			return within(timeout, function()
				return offered.handle(method, params, { session = M.session() })
			end)
		end
		local link = v.link
		if not link then
			return nil, v.why or `{name} isn't reachable`
		end
		return within(timeout, function()
			return link:request(
				"service/request",
				{ service = name, method = method, params = params }
			)
		end)
	end

	function view.listen(_, topic: string)
		if v.topics[topic] then
			return
		end
		v.topics[topic] = true
		local link = v.link
		if link then
			greed.spawn(function()
				link:request("service/listen", { service = name, topics = { topic } })
			end)
		elseif not v.direct then
			v.wanted = true
			greed.spawn(connect, v)
		end
	end

	function view.ignore(_, topic: string)
		v.topics[topic] = nil
		local link = v.link
		if link then
			greed.spawn(function()
				link:request("service/ignore", { service = name, topics = { topic } })
			end)
		end
	end

	function view.state(_): (State, number?, string?)
		return v.state, v.since, v.why
	end

	function view.close(_)
		if v.closed then
			return
		end
		v.closed = true
		local link = v.link
		v.link = nil
		if link then
			link:close()
		end
		settle(v)
		local list = views[name]
		local at = list and table.find(list, v)
		if list and at then
			table.remove(list, at)
		end
	end

	views[name] = views[name] or {}
	table.insert(views[name], v)
	greed.plugin.cleanup(function()
		view:close()
	end)
	-- Nothing to connect to in the owner's session: it hears what changes
	-- from the start.
	if v.direct and offers[name] then
		became_ready(v)
	end
	return view
end

--- Quits the owner's session of `name` and starts it again, as after an
--- upgrade; views here connect again.
function M.restart(name: string): (boolean?, string?)
	local program = greed.session.program()
	if not program then
		return nil, "can't tell where greed is"
	end
	local session = M.session_of(name)
	local opts: greed.RunOptions = { timeout = 10000 }
	local ran, err = greed.vouch(greed.process.run, { program, "ctl", "quit", session }, opts)
	if not ran then
		return nil, err
	end
	-- Gone once it doesn't answer; then it starts with this greed.
	for _ = 1, 100 do
		local running = false
		for _, s in greed.session.list() do
			running = running or s.name == session
		end
		if not running then
			break
		end
		greed.sleep(100)
	end
	return M.start(session)
end

-- The owner's side of the socket.

local function offered(params: any): Offered
	local o = params and offers[params.service]
	if not o then
		local service = params and params.service or "?"
		error(`{M.session_of(service)} doesn't offer {service}`, 0)
	end
	return o
end

--- Answers a view's `method` on the socket connection `connection`: what
--- `agent.method` hands this, and tests directly.
function M.answer(method: string, params: any, connection: number): any
	local o = offered(params)
	if method == "service/hello" then
		hellos[connection] = { session = params.session }
		return { version = o.spec.version, incarnation = o.incarnation }
	elseif method == "service/listen" or method == "service/ignore" then
		local topics: { [string]: boolean } = o.listeners[connection] or {}
		for _, topic in params.topics or {} :: { string } do
			if method == "service/listen" then
				topics[topic] = true
			else
				topics[topic] = nil
			end
		end
		if next(topics) ~= nil then
			o.listeners[connection] = topics
		else
			o.listeners[connection] = nil
		end
		return true
	end
	local result, why = o.handle(params.method, params.params, hellos[connection] or {})
	if why then
		error(why, 0)
	end
	return result
end

--- Forgets what the socket connection `connection` listened to, once it
--- closed.
function M.closed(connection: number)
	hellos[connection] = nil
	for _, o in offers do
		o.listeners[connection] = nil
	end
end

for _, method in { "service/hello", "service/listen", "service/ignore", "service/request" } do
	agent.method(method, function(request: greed.ControlRequest)
		return M.answer(method, request.params, request.connection or 0)
	end)
end

greed.on("control.closed", function(event: greed.ControlClosed)
	M.closed(event.connection)
end)

--- Whether `name`'s owner starts with Greed, as its definition says.
function M.starts_with_greed(name: string): boolean
	local entry = defined[name]
	local start = if entry then entry.definition.start else nil
	return start == "always" or (type(start) == "function" and start())
end

-- Owners that start with Greed, from any session but a service's.
greed.on("editor.started", function()
	local here = M.session()
	if not here or string.find(here, "%.service$") then
		return
	end
	for name in defined do
		if M.starts_with_greed(name) then
			greed.spawn(M.start, M.session_of(name))
		end
	end
end)

greed.command({
	name = "service-restart",
	doc = "Quit a service's session and start it again with this greed, as after an upgrade",
	args = { { name = "service", doc = "Which service, like chat" } },
	run = function(ctx: greed.Context)
		local name = ctx.args[1]
		if defined[name] == nil then
			greed.echo(`which service? {table.concat(M.defined(), ", ")}`)
			return
		end
		local ok, why = M.restart(name)
		greed.echo(if ok then `{name} started again` else `couldn't restart {name}: {why}`)
	end,
})

return M
