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
--   space i A   the agents of every session here: enter goes there

local greed = require("@greed")
local agent = require("@agent")
local picker = require("@picker")
local statusline = require("@statusline")

greed.option.define({
	name = "hub-session",
	doc = "The session that follows the others on this machine; empty for the first running one by name",
	default = "",
})

local M = {}

--- How often a session looks again at which sessions run, in milliseconds.
M.LOOK = 3000

--- How long a session that couldn't be followed (an older greed) is left
--- alone, in milliseconds.
M.SKIP = 60000

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

-- The sessions followed, by name: the program following it and the status
-- it said last.
type Followed = { child: greed.Child, status: { [string]: any }? }
local followed: { [string]: Followed } = {}

-- When each session that couldn't be followed was last tried.
local tried: { [string]: number } = {}

-- Looks for what to tell you soon, when this is the hub (set below).
local announce_soon = function() end

-- Tells whoever shows the picture that it changed: the status line, the
-- watchers of this session's status (like the other sessions when this one
-- is the hub), and what tells you an agent waits.
local function changed()
	agent.status_changed()
	announce_soon()
end

-- Follows the session `name` with `greed ctl watch`, keeping what it says.
local function follow(name: string)
	local program = greed.session.program()
	if program == nil then
		return
	end
	local child = greed.process.spawn({ program, "ctl", "watch", name })
	if child == nil then
		tried[name] = greed.now()
		return
	end
	local mine: Followed = { child = child }
	followed[name] = mine
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
				if followed[name] == mine and type(status) == "table" then
					mine.status = status
					changed()
				end
			end
		end
		-- It ended: the session went, or it can't be watched (an older greed).
		if followed[name] == mine then
			followed[name] = nil
			tried[name] = greed.now()
			changed()
		end
	end)
end

local function unfollow(name: string)
	local gone = followed[name]
	followed[name] = nil
	if gone then
		gone.child:kill()
	end
end

--- Follows what this session should: every other session when it's the
--- hub, else the hub alone.
function M.reconcile()
	local me = greed.session.current()
	local hub = M.hub()
	local want: { [string]: boolean } = {}
	if me and hub == me then
		for _, session in greed.session.list() do
			if session.name ~= me then
				want[session.name] = true
			end
		end
	elseif me and hub then
		want[hub] = true
	end
	for name in followed do
		if not want[name] then
			unfollow(name)
		end
	end
	for name in want do
		local last = tried[name]
		if followed[name] == nil and (last == nil or greed.now() - last > M.SKIP) then
			follow(name)
		end
	end
end

--- What each session on the machine says, by name, this one included: as
--- this session follows them when it's the hub, else as the hub says.
function M.machine(): { [string]: { [string]: any } }
	local all: { [string]: { [string]: any } } = {}
	local me = greed.session.current()
	for name, follower in followed do
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

-- The hub adds the others to its status, so they follow only it. Each
-- session there is said without its own `machine`.
agent.status_part("machine", function()
	if M.hub() ~= greed.session.current() then
		return nil
	end
	local out: { [string]: any } = {}
	for name, follower in followed do
		local status = follower.status
		if status then
			local slim = table.clone(status)
			slim.machine = nil
			out[name] = slim
		end
	end
	return out
end)

--- An agent somewhere on the machine: the session it's in, and what that
--- session's status says of it.
export type Found = { session: string, agent: { [string]: any } }

--- The agents of the other sessions on the machine, by session then label.
function M.elsewhere(): { Found }
	local out: { Found } = {}
	local me = greed.session.current()
	for name, status in M.machine() do
		local agents = status.agents
		if name ~= me and type(agents) == "table" then
			for _, found in agents do
				table.insert(out, { session = name, agent = found })
			end
		end
	end
	table.sort(out, function(a: Found, b: Found): boolean
		if a.session ~= b.session then
			return a.session < b.session
		end
		return tostring(a.agent.label) < tostring(b.agent.label)
	end)
	return out
end

-- How the agents elsewhere are doing, as the status line says it: "◆ 1
-- waiting in greed-2", or "elsewhere" for several sessions.
statusline.add("right", "elsewhere", function()
	local states: { string } = {}
	local where: { [string]: boolean } = {}
	local count = 0
	for _, found in M.elsewhere() do
		table.insert(states, tostring(found.agent.status))
		if found.agent.status == "waiting" or found.agent.status == "working" then
			if not where[found.session] then
				where[found.session] = true
				count += 1
			end
		end
	end
	local said = agent.status_summary(states)
	if said == nil then
		return nil
	end
	local session = next(where)
	local place = if count == 1 and session then `in {session}` else "elsewhere"
	return { text = `{said} {place}`, style = "ui.statusline.message" }
end, "agents")

greed.command({
	name = "machine",
	doc = "The agents of every session on this machine: enter goes to its session (space i A)",
	run = function()
		local items: { picker.Item } = {}
		for _, found in M.elsewhere() do
			local said = found.agent
			table.insert(items, {
				label = `{found.session}  {said.agent or said.label}  {said.status}`,
				value = found.session,
			})
		end
		if #items == 0 then
			greed.echo("no agents in the other sessions on this machine")
			return
		end
		picker.pick("Agents on this machine", items, function(item)
			greed.session.switch({ name = item.value })
		end)
	end,
})

-- Telling you ----------------------------------------------------------------
--
-- The hub tells you when an agent starts waiting, anywhere on the machine:
-- each machine you're attached from gets it once, through one of its
-- clients, so two windows on one machine don't both say it. What it told
-- is kept, so a restart or a new hub doesn't tell it again.

--- What one session says, as its status gives it.
export type Status = { [string]: any }

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

--- The agents waiting for you in `statuses`, by session name.
function M.waiting(statuses: { [string]: Status }): { Waiting }
	local out: { Waiting } = {}
	for name, status in statuses do
		local agents = status.agents
		if type(agents) == "table" then
			for _, found in agents do
				if found.status == "waiting" then
					local what = found.question or found.label or found.agent
					table.insert(out, {
						key = `{name}|{found.id}|{found.since or found.question or ""}`,
						session = name,
						title = `{found.label or found.agent} waits for you`,
						body = `{what} · {name}`,
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
	local data = greed.fs.dirs().data
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
	for _, waiting in M.waiting(statuses) do
		if not table.find(list, waiting.key) then
			remember(waiting.key)
			for _, target in where do
				tell_client(target.session, target.client, waiting.title, waiting.body)
			end
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
			greed.sleep(M.LOOK)
		end
	end)
end)

return M
