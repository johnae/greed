-- The hub: one session on the machine follows all the others, so every
-- session can say what waits elsewhere and go there, and one place decides
-- what to tell you. The hub is a role, not a process: among the running
-- sessions of this greed's build, the one `hub-session` names, or else the
-- first by name. Each session works it out again as sessions come and go,
-- so when the hub ends another takes over.
--
-- The hub follows each other session with `greed ctl watch` and adds what
-- they say to its own status (`machine`); the others follow only the hub.
-- Every message is a whole status, so a missed one only means a later look.
--
-- Hubs follow hubs: the machines you reached with `greed ssh` lately, and
-- the hosts in `hub-hosts`, are other machines whose hubs this one follows
-- over ssh (`greed ssh HOST ctl watch --hub`), and what they say of the
-- machines they know comes along (`machines`). There's no
-- main hub: every entry names the machine it's about, a hub ignores news
-- of its own machine, and of each other machine it keeps what it heard
-- itself, else the freshest, so loops die out.
--
--   space i A   the agents of every session you can reach: enter goes there

local greed = require("@greed")
local agent = require("@agent")
local picker = require("@picker")
local statusline = require("@statusline")

greed.option.define({
	name = "hub-session",
	doc = "The session that follows the others on this machine; empty for the first running one by name",
	default = "",
})

greed.option.define({
	name = "hub-hosts",
	doc = 'More machines whose hubs this machine\'s hub follows, beside the ones you reached with greed ssh lately, as ssh hosts separated by spaces, like "eris mini"',
	default = "",
})

local M = {}

--- How often a session looks again at which sessions run, in milliseconds.
M.LOOK = 3000

--- How long a session or machine that couldn't be followed (an older
--- greed, a machine that's off) is left alone, in milliseconds; twice as
--- long each time again, up to `M.SKIP_MOST`.
M.SKIP = 60000
M.SKIP_MOST = 30 * 60000

--- How old, in seconds, news of another machine may be before it's
--- dropped: a hub says its status at least every 15 seconds.
M.STALE = 90

--- How long, in seconds, a machine you reached with `greed ssh` is
--- followed after you last did.
M.REMEMBER = 14 * 24 * 3600

--- How long to leave alone what couldn't be followed `fails` times in a
--- row, in milliseconds.
function M.backoff(fails: number): number
	return math.min(M.SKIP * 2 ^ math.max(fails - 1, 0), M.SKIP_MOST)
end

--- The hub among `sessions` (as `greed.session.list` gives them): the one
--- `wanted` names if it runs, else the first by name of those of `build`.
function M.elect(sessions: { greed.SessionInfo }, build: string, wanted: string?): string?
	local names: { string } = {}
	for _, session in sessions do
		if session.name == wanted then
			return wanted
		elseif session.build == nil or session.build == build then
			table.insert(names, session.name)
		end
	end
	table.sort(names)
	return names[1]
end

--- The hub of this machine now.
function M.hub(): string?
	local wanted = greed.option.get("hub-session")
	return M.elect(
		greed.session.list(),
		greed.session.build(),
		if type(wanted) == "string" and wanted ~= "" then wanted else nil
	)
end

--- Greed's data folder, where the hub keeps what it told and `greed ssh`
--- notes the machines you reach; tests point it elsewhere.
M.dirs = { data = greed.fs.dirs().data }

-- Where `greed ssh` notes the machines you reach, with when (seconds, like
-- `os.time()`).
local function reached_file(): string?
	local data = M.dirs.data
	return if data then `{data}/ssh-hosts` else nil
end

--- The machines you reached with `greed ssh`, by ssh host, with when you
--- last did (seconds, like `os.time()`).
function M.reached(): { [string]: number }
	local file = reached_file()
	local ok, said = pcall(function()
		return greed.json.decode((if file then greed.fs.read(file) else nil) or "{}")
	end)
	local out: { [string]: number } = {}
	if ok and type(said) == "table" then
		for host, at in said do
			if type(host) == "string" and type(at) == "number" then
				out[host] = at
			end
		end
	end
	return out
end

--- Stops following `host` until you reach it with `greed ssh` again.
function M.forget(host: string)
	local reached = M.reached()
	reached[host] = nil
	local file = reached_file()
	if file then
		greed.fs.write(file, greed.json.encode(reached))
	end
end

--- The other machines' hosts the hub follows: the ones you reached with
--- `greed ssh` in the last `M.REMEMBER` seconds and the ones in
--- `hub-hosts`, by name.
function M.hosts(): { string }
	local seen: { [string]: boolean } = {}
	local now = os.time()
	for host, at in M.reached() do
		if now - at <= M.REMEMBER then
			seen[host] = true
		end
	end
	local said = greed.option.get("hub-hosts")
	for host in string.gmatch(if type(said) == "string" then said else "", "[^%s,]+") do
		seen[host] = true
	end
	local hosts: { string } = {}
	for host in seen do
		table.insert(hosts, host)
	end
	table.sort(hosts)
	return hosts
end

--- The whole lines in `pending`, and what's left after them.
function M.lines(pending: string): ({ string }, string)
	local lines = {}
	while true do
		local at = string.find(pending, "\n", 1, true)
		if at == nil then
			return lines, pending
		end
		table.insert(lines, string.sub(pending, 1, at - 1))
		pending = string.sub(pending, at + 1)
	end
end

--- What one session says, as its status gives it.
export type Status = { [string]: any }

-- One followed: the program following it, the status it said last and when
-- (in seconds, like `os.time()`).
type Followed = { child: greed.Child, status: Status?, at: number? }

-- What's followed of one kind, by name, and when each that couldn't be
-- followed was last tried, and how many times in a row it couldn't.
type Tried = { at: number, fails: number }
type Following = { now: { [string]: Followed }, tried: { [string]: Tried } }

-- The sessions on this machine, by name.
local sessions: Following = { now = {}, tried = {} }

-- The other machines' hubs, by ssh host.
local hosts: Following = { now = {}, tried = {} }

-- Looks for what to tell you soon, when this is the hub (set below).
local announce_soon = function() end

-- Tells whoever shows the picture that it changed: the status line, the
-- watchers of this session's status (like the other sessions when this one
-- is the hub), and what tells you an agent waits.
local function changed()
	agent.status_changed()
	announce_soon()
end

-- Follows with `greed ARGS`, a `greed ctl watch` of some kind, keeping what
-- it says as `following.now[name]`.
local function follow(following: Following, name: string, args: { string })
	local program = greed.session.program()
	if program == nil then
		return
	end
	local command = { program }
	for _, arg in args do
		table.insert(command, arg)
	end
	-- It couldn't be followed (again, unless it said something first).
	local function failed(said: boolean)
		local before = following.tried[name]
		local fails = if said or before == nil then 1 else before.fails + 1
		following.tried[name] = { at = greed.now(), fails = fails }
	end
	local child = greed.process.spawn(command)
	if child == nil then
		failed(false)
		return
	end
	local mine: Followed = { child = child }
	following.now[name] = mine
	greed.spawn(function()
		local pending = ""
		while true do
			local piece = child:read()
			if piece == nil then
				break
			end
			local lines
			lines, pending = M.lines(pending .. piece)
			for _, line in lines do
				local status = greed.json.decode(line)
				if following.now[name] == mine and type(status) == "table" then
					mine.status = status
					-- To ten seconds, so hubs following each other don't
					-- tell each other of every second that passes.
					local now = os.time()
					mine.at = now - now % 10
					changed()
				end
			end
		end
		-- It ended: the session went, or it can't be watched (an older greed,
		-- a machine that's off).
		if following.now[name] == mine then
			following.now[name] = nil
			failed(mine.status ~= nil)
			changed()
		end
	end)
end

-- Follows what `want` names, with its arguments, and nothing else.
local function keep(following: Following, want: { [string]: { string } })
	for name, gone in following.now do
		if not want[name] then
			following.now[name] = nil
			gone.child:kill()
		end
	end
	for name, args in want do
		local last = following.tried[name]
		if
			following.now[name] == nil
			and (last == nil or greed.now() - last.at > M.backoff(last.fails))
		then
			follow(following, name, args)
		end
	end
end

--- Follows what this session should: every other session and the other
--- machines' hubs when it's the hub, else the hub alone.
function M.reconcile()
	local me = greed.session.current()
	local hub = M.hub()
	local here: { [string]: { string } } = {}
	local there: { [string]: { string } } = {}
	if me and hub == me then
		for _, session in greed.session.list() do
			if session.name ~= me then
				here[session.name] = { "ctl", "watch", session.name }
			end
		end
		for _, host in M.hosts() do
			there[host] = { "ssh", host, "ctl", "watch", "--hub" }
		end
	elseif me and hub then
		here[hub] = { "ctl", "watch", hub }
	end
	keep(sessions, here)
	keep(hosts, there)
end

--- What each session on the machine says, by name, this one included: as
--- this session follows them when it's the hub, else as the hub says.
function M.machine(): { [string]: Status }
	local all: { [string]: Status } = {}
	local me = greed.session.current()
	for name, follower in sessions.now do
		local status = follower.status
		if status then
			all[name] = status
			-- The hub's own picture of the others.
			local others = status.machine
			if type(others) == "table" then
				for other, said in others do
					if other ~= me then
						all[other] = said
					end
				end
			end
		end
	end
	return all
end

--- Another machine: its id and name, its sessions by name, when it was
--- last heard of (seconds, like `os.time()`), and the ssh host it's
--- reached by, when a hub here follows it; `home` when it's the machine a
--- client attached here from another runs on, which it told of.
export type Machine = {
	host: { id: string, name: string },
	sessions: { [string]: Status },
	at: number,
	via: string?,
	home: boolean?,
}

-- What the hubs say on the machines of the clients attached from elsewhere
-- (over `greed ssh`), by client, with when (seconds, like `os.time()`).
local homes: { [number]: { status: Status, at: number } } = {}

-- The clients being asked what the hub on their machine says, so a
-- session there shows what you have where you are.
local asking: { [number]: boolean } = {}

-- Asks client `id` what the hub on its machine says, unless it's being
-- asked already. That hub's answer has every machine it follows too, so
-- this is one question however many machines you have.
local function ask_home(id: number)
	if asking[id] then
		return
	end
	asking[id] = true
	greed.spawn(function()
		local status = greed.client.home(id)
		local had = homes[id]
		if status then
			local now = os.time()
			homes[id] = { status = status, at = now - now % 10 }
			if had == nil or greed.json.encode(had.status) ~= greed.json.encode(status) then
				changed()
			end
		end
		asking[id] = nil
	end)
end

-- Asks each client attached from elsewhere again, and forgets those gone.
local function ask_homes()
	local attached: { [number]: boolean } = {}
	for _, client in greed.client.list() do
		if client.remote then
			attached[client.id] = true
			ask_home(client.id)
		end
	end
	for id in homes do
		if not attached[id] then
			homes[id] = nil
		end
	end
end

-- A client attaching from elsewhere is asked at once, not at the next look.
greed.on("client.attached", function(event: greed.ClientAttached)
	if event.remote then
		ask_home(event.client)
	end
end)

-- `status` without the others it says of, the way it's passed on.
local function slim(status: Status): Status
	local out = table.clone(status)
	out.machine = nil
	out.machines = nil
	return out
end

--- The other machines, by id: the ones the hub follows itself and those
--- clients attached here from elsewhere run on, as they say, and the ones
--- they and the hub say of, the freshest of each, none older than
--- `M.STALE` and never this one. A session that isn't the hub has them
--- from the hub too.
function M.machines(): { [string]: Machine }
	local me = agent.host().id
	local now = os.time()
	local out: { [string]: Machine } = {}
	local heard: { [string]: boolean } = {}
	local function consider(found: Machine, itself: boolean)
		local id = found.host.id
		if id == me or now - found.at > M.STALE or heard[id] then
			return
		end
		local had = out[id]
		if itself or had == nil or found.at > had.at then
			out[id] = found
			heard[id] = itself
		end
	end
	-- What a status says of other machines; `via` holds only where the ssh
	-- hosts are this machine's.
	local function told(status: Status, via: boolean)
		local others = status.machines
		if type(others) ~= "table" then
			return
		end
		for _, said in others do
			if
				type(said) == "table"
				and type(said.host) == "table"
				and type(said.at) == "number"
			then
				consider({
					host = said.host,
					sessions = if type(said.sessions) == "table" then said.sessions else {},
					at = said.at,
					via = if via then said.via else nil,
					home = if via then said.home else nil,
				}, false)
			end
		end
	end
	-- What a machine's own hub says, heard directly: by following it
	-- (`via`), or from a client that runs there (`home`).
	local function heard_from(status: Status?, at: number?, via: string?, home: boolean?)
		local session, machine = status and status.session, status and status.host
		if status and at and type(session) == "string" and type(machine) == "table" then
			local there: { [string]: Status } = {}
			if type(status.machine) == "table" then
				for name, said in status.machine do
					there[name] = said
				end
			end
			there[session] = slim(status)
			consider(
				{ host = machine :: any, sessions = there, at = at, via = via, home = home },
				true
			)
			told(status, false)
		end
	end
	for _, home in homes do
		heard_from(home.status, home.at, nil, true)
	end
	for host, follower in hosts.now do
		heard_from(follower.status, follower.at, host)
	end
	for _, follower in sessions.now do
		if follower.status then
			told(follower.status, true)
		end
	end
	return out
end

-- The hub adds the others to its status, so they follow only it: the
-- sessions here, each without its own picture, and the other machines.
agent.status_part("machine", function()
	if M.hub() ~= greed.session.current() then
		return nil
	end
	local out: { [string]: Status } = {}
	for name, follower in sessions.now do
		local status = follower.status
		if status then
			out[name] = slim(status)
		end
	end
	return out
end)

agent.status_part("machines", function()
	if M.hub() ~= greed.session.current() then
		return nil
	end
	return M.machines()
end)

-- Which session is the hub, for `greed ctl watch --hub`.
agent.method("hub/name", function()
	return M.hub()
end)

--- Another session, here or on another machine: its name, what it says
--- of itself when that's known, and for another machine its name and how
--- to get there: the ssh host that reaches it, or `home` for the machine
--- your client runs on.
export type Session = {
	session: string,
	status: Status?,
	machine: string?,
	via: string?,
	home: boolean?,
}

--- An agent in another session: the session, as `M.sessions` gives it,
--- with what its status says of the agent.
export type Found = {
	session: string,
	agent: { [string]: any },
	machine: string?,
	via: string?,
	home: boolean?,
}

--- Where a session is, as you're told it: its name, and the machine when
--- it's another.
function M.place(found: { session: string, machine: string? }): string
	return if found.machine then `{found.session} on {found.machine}` else found.session
end

--- Sends the client to a session, wherever it is.
function M.go(found: { session: string, via: string?, home: boolean? })
	if found.home then
		greed.session.switch({ name = found.session, home = true })
	else
		greed.session.switch({ name = found.session, host = found.via })
	end
end

--- The other sessions here and on the other machines, by machine then
--- name: those the hub has heard from, and with `all` the ones here it
--- hasn't yet. Listing those looks at every session's socket, so the
--- status line, drawn on every frame, leaves `all` off.
function M.sessions(all: boolean?): { Session }
	local out: { Session } = {}
	local me = greed.session.current()
	local here = M.machine()
	for name, status in here do
		if name ~= me then
			table.insert(out, { session = name, status = status })
		end
	end
	if all then
		for _, running in greed.session.list() do
			if running.name ~= me and here[running.name] == nil then
				table.insert(out, { session = running.name })
			end
		end
	end
	for _, there in M.machines() do
		for name, status in there.sessions do
			table.insert(out, {
				session = name,
				status = status,
				machine = there.host.name,
				via = if there.home then nil else there.via or there.host.name,
				home = there.home,
			})
		end
	end
	table.sort(out, function(a: Session, b: Session): boolean
		if a.machine ~= b.machine then
			return (a.machine or "") < (b.machine or "")
		end
		return a.session < b.session
	end)
	return out
end

--- The agents of the other sessions here and on the other machines, by
--- machine, session, then label.
function M.elsewhere(): { Found }
	local out: { Found } = {}
	for _, found in M.sessions() do
		local agents = found.status and found.status.agents
		if type(agents) == "table" then
			local by: { Found } = {}
			for _, said in agents do
				table.insert(by, {
					session = found.session,
					agent = said,
					machine = found.machine,
					via = found.via,
					home = found.home,
				})
			end
			table.sort(by, function(a: Found, b: Found): boolean
				return tostring(a.agent.label) < tostring(b.agent.label)
			end)
			table.move(by, 1, #by, #out + 1, out)
		end
	end
	return out
end

--- Your other sessions and the agents in them, everywhere, as `space space`
--- lists them: `@session` or `@agent` keeps one kind, and an agent's state
--- (`@waiting`) or a machine's name (`@eris`, `@here`) those.
function M.places(): { picker.Place }
	local out: { picker.Place } = {}
	for _, found in M.sessions(true) do
		local states: { string } = {}
		local agents = found.status and found.status.agents
		if type(agents) == "table" then
			for _, said in agents do
				table.insert(states, tostring(said.status))
			end
		end
		local said = agent.status_summary(states)
		table.insert(out, {
			kind = "session",
			label = if said then `{M.place(found)}  {said}` else M.place(found),
			tags = { found.machine or "here" },
			go = function()
				M.go(found)
			end,
		})
	end
	for _, found in M.elsewhere() do
		local said = found.agent
		local what = if said.question then `: {said.question}` else ""
		table.insert(out, {
			kind = "agent",
			label = `{said.agent or said.label} {said.status} in {M.place(found)}{what}`,
			tags = { tostring(said.status), found.machine or "here" },
			go = function()
				M.go(found)
			end,
		})
	end
	return out
end

picker.add_places("hub", M.places)

-- How the agents elsewhere are doing, as the status line says it: "◆ 1
-- waiting in greed-2", or "elsewhere" for several sessions.
statusline.add("right", "elsewhere", function()
	local states: { string } = {}
	local where: { [string]: boolean } = {}
	local count = 0
	for _, found in M.elsewhere() do
		table.insert(states, tostring(found.agent.status))
		if found.agent.status == "waiting" or found.agent.status == "working" then
			local place = M.place(found)
			if not where[place] then
				where[place] = true
				count += 1
			end
		end
	end
	local said = agent.status_summary(states)
	if said == nil then
		return nil
	end
	local place = next(where)
	local text = if count == 1 and place then `in {place}` else "elsewhere"
	return { text = `{said} {text}`, style = "ui.statusline.message" }
end, "agents")

greed.command({
	name = "machine",
	doc = "The agents of every other session, here and on the machines the hub follows: enter goes there (space i A)",
	run = function()
		local items: { picker.Item } = {}
		for _, place in M.places() do
			if place.kind == "agent" then
				table.insert(items, { label = place.label, value = place })
			end
		end
		if #items == 0 then
			greed.echo("no agents in your other sessions")
			return
		end
		picker.pick("Agents in your sessions", items, function(item)
			item.value.go()
		end)
	end,
})

greed.command({
	name = "machine-forget",
	doc = "Stop following a machine you reached with greed ssh, until you do again",
	run = function()
		local items: { picker.Item } = {}
		for host, at in M.reached() do
			table.insert(items, { label = `{host}  {os.date("%Y-%m-%d", at)}`, value = host })
		end
		if #items == 0 then
			greed.echo("no machines reached with greed ssh")
			return
		end
		picker.pick("Forget a machine", items, function(item)
			M.forget(item.value)
			greed.echo(`forgot {item.value}`)
		end)
	end,
})

-- Telling you ----------------------------------------------------------------
--
-- The hub tells you when an agent starts waiting, here or on a machine it
-- follows: each machine you're attached from gets it once, through one of
-- its clients, so two windows on one machine don't both say it. An agent on
-- another machine is that machine's hub's to tell where it can, so this hub
-- tells only the machines that one doesn't reach. What it told is kept, so
-- a restart or a new hub doesn't tell it again.

--- Where you can be told: for each machine with a client attached in any
--- of `statuses` (by session), a session it's attached to and that client's
--- name ("gui@laptop"), the first by session name.
function M.reachable(
	statuses: { [string]: Status }
): { [string]: { session: string, client: string } }
	local names: { string } = {}
	for name in statuses do
		table.insert(names, name)
	end
	table.sort(names)
	local out: { [string]: { session: string, client: string } } = {}
	for _, name in names do
		local clients = statuses[name].clients
		if type(clients) == "table" then
			for _, found in clients do
				local client = tostring(found)
				local machine = string.match(client, "@(.+)$") or client
				out[machine] = out[machine] or { session = name, client = client }
			end
		end
	end
	return out
end

--- An agent waiting in one of `statuses`, with what tells this time apart
--- from another time it waits (`key`), and the words to tell you with.
export type Waiting = { key: string, session: string, title: string, body: string }

--- The agents waiting for you in `statuses`, by session name, on this
--- machine or the one `machine` names.
function M.waiting(
	statuses: { [string]: Status },
	machine: { id: string, name: string }?
): { Waiting }
	local out: { Waiting } = {}
	for name, status in statuses do
		local agents = status.agents
		if type(agents) == "table" then
			for _, found in agents do
				if found.status == "waiting" then
					local what = found.question or found.label or found.agent
					local key = `{name}|{found.id}|{found.since or found.question or ""}`
					table.insert(out, {
						key = if machine then `{machine.id}|{key}` else key,
						session = name,
						title = `{found.label or found.agent} waits for you`,
						body = if machine
							then `{what} · {name} on {machine.name}`
							else `{what} · {name}`,
					})
				end
			end
		end
	end
	table.sort(out, function(a: Waiting, b: Waiting): boolean
		return a.key < b.key
	end)
	return out
end

-- How many of what it told the hub keeps.
local KEPT = 500

-- What was told, as keys, oldest first, and kept in the data folder.
local told: { string }? = nil

local function told_file(): string?
	local data = M.dirs.data
	return if data then `{data}/hub-told` else nil
end

local function was_told(): { string }
	if told == nil then
		local file = told_file()
		local text = if file then greed.fs.read(file) else nil
		local list = {}
		for line in string.gmatch(text or "", "[^\n]+") do
			table.insert(list, line)
		end
		told = list
	end
	return told :: { string }
end

local function remember(key: string)
	local list = was_told()
	table.insert(list, key)
	while #list > KEPT do
		table.remove(list, 1)
	end
	local file = told_file()
	if file then
		greed.fs.write(file, table.concat(list, "\n") .. "\n")
	end
end

-- Notifies through this session's client called `client`, if it's attached.
local function notify_here(client: string, title: string, body: string?): boolean
	for _, attached in greed.client.list() do
		if attached.name == client then
			greed.client.notify(title, body, attached.id)
			return true
		end
	end
	return false
end

-- Tells the client `client` of session `session` (this one or another).
local function tell_client(session: string, client: string, title: string, body: string)
	if session == greed.session.current() then
		notify_here(client, title, body)
		return
	end
	local program = greed.session.program()
	if program then
		local said = greed.json.encode({ title = title, body = body, client = client })
		local env: { [string]: string | false } = { GREED_SESSION = session }
		greed.process.run({ program, "ctl", "hub_notify", said }, { env = env })
	end
end

-- Tells you what started waiting since the last look, when this is the hub.
local function announce()
	local me = greed.session.current()
	if me == nil or M.hub() ~= me then
		return
	end
	local statuses = M.machine()
	statuses[me] = agent.status()
	local list = was_told()
	local where = M.reachable(statuses)
	-- Tells each machine in `where` but those in `skip`, once.
	local function tell(waiting: Waiting, skip: { [string]: any })
		if table.find(list, waiting.key) then
			return
		end
		remember(waiting.key)
		for machine, target in where do
			if skip[machine] == nil then
				tell_client(target.session, target.client, waiting.title, waiting.body)
			end
		end
	end
	for _, waiting in M.waiting(statuses) do
		tell(waiting, {})
	end
	for _, there in M.machines() do
		local theirs = M.reachable(there.sessions)
		for _, waiting in M.waiting(there.sessions, there.host) do
			tell(waiting, theirs)
		end
	end
end

local announcing = false
announce_soon = function()
	if announcing then
		return
	end
	announcing = true
	greed.spawn(function()
		greed.sleep(50)
		announcing = false
		-- Telling you is this plugin's own doing, whatever changed.
		greed.vouch(announce)
	end)
end

agent.tool({
	name = "hub_notify",
	shell_only = true,
	description = "For the hub: notifies your desktop through this session's client called "
		.. "`client` (like gui@laptop), with `title` and `body`",
	input = agent.schema.object({
		title = { type = "string" },
		body = { type = "string" },
		client = { type = "string" },
	}, { "title", "client" }),
	run = function(args)
		if notify_here(args.client, tostring(args.title), args.body) then
			return "told"
		end
		return `no client {args.client} here`
	end,
})

greed.keymap.bind({ layer = "leader" }, { ["i A"] = "machine" })

-- Looks at which sessions run, again and again, while this is a session:
-- from when the editor has started, since a session learns its name only
-- after its plugins load.
greed.on("editor.started", function()
	greed.spawn(function()
		while greed.session.current() do
			M.reconcile()
			ask_homes()
			greed.sleep(M.LOOK)
		end
	end)
end)

return M
