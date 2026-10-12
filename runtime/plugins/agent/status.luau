-- The session's status, for `greed ctl status`, agents and later the hub:
-- what needs you (core.attention) and the agents at work (agent sessions,
-- and agents in terminals as their hooks tell), in one table. `schema`
-- says its shape, so a reader can tell an older session's from one it
-- doesn't understand.

local greed = require("@greed")
local core = require("@core")
local agent = require("./registry")

local M = {}

--- The shape of the table `status` gives; it goes up when a field changes
--- meaning or goes, not when one is added.
M.SCHEMA = 1

-- What plugins add to the status, by name (`part`).
local parts: { [string]: () -> any } = {}

-- This machine's id, once read or made.
local machine_id: string? = nil

--- The machine this runs on, as hubs tell machines apart: an id made once
--- and kept in Greed's data folder, so it stays when the machine is renamed
--- and differs between machines of one name, and its name to show. Where
--- it can't be kept, it lasts as long as this session.
function M.host(): { id: string, name: string }
	if machine_id == nil then
		local data = greed.fs.dirs().data
		local file = if data then `{data}/machine-id` else nil
		local read, kept = pcall(function()
			return if file then greed.fs.read(file) else nil
		end)
		machine_id = if read and kept then string.match(kept, "^%s*(%x+)") else nil
		if machine_id == nil then
			local id = greed.hash.random(8)
			machine_id = id
			if file then
				pcall(function()
					greed.fs.write(file, `{id}\n`)
				end)
			end
		end
	end
	return { id = machine_id :: string, name = greed.hostname() or "this machine" }
end

--- This session's status: its name, build and project, the machine it's on,
--- what needs you (oldest first) and its agents with their state.
function M.status(): { [string]: any }
	local needs = {}
	for _, need in core.attention.list() do
		table.insert(needs, {
			id = need.key,
			label = need.label,
			reason = need.reason,
			since = need.since,
		})
	end
	-- What can be done to an agent now, by action name, so a view elsewhere
	-- (another session, another machine) can offer it: answering it while it
	-- waits, stopping it.
	local function actions_of(found: core.Object): { string }
		local names: { string } = {}
		for _, action in core.objects.actions(found) do
			table.insert(names, action.name)
		end
		return greed.json.array(names)
	end
	local agents = {}
	for _, found in core.objects.list("agent-session") do
		local state = core.objects.inspect(found)
		state.id = found.id
		state.label = found.label
		state.actions = actions_of(found)
		table.insert(agents, state)
	end
	-- Agents in terminals, as what they report says, and whether that can be
	-- trusted (their hooks) or might be something a program printed.
	for _, found in core.objects.list("terminal") do
		local running = core.objects.inspect(found).agent
		if running then
			table.insert(agents, {
				id = found.id,
				label = found.label,
				agent = running.name,
				status = running.state,
				since = running.since,
				source = running.source,
				trusted = running.trusted,
				actions = actions_of(found),
			})
		end
	end
	-- Where you are: the clients attached, by name ("gui@laptop").
	local clients = {}
	for _, client in greed.client.list() do
		if client.kind ~= "headless" and client.kind ~= "test" then
			table.insert(clients, client.name)
		end
	end
	local status: { [string]: any } = {
		schema = M.SCHEMA,
		session = greed.session.current(),
		build = greed.session.build(),
		host = M.host(),
		root = greed.project.current().root,
		attention = greed.json.array(needs),
		agents = greed.json.array(agents),
		clients = greed.json.array(clients),
	}
	for name, part in parts do
		local ok, value = pcall(part)
		if ok and value ~= nil then
			status[name] = value
		end
	end
	return status
end

--- Adds `part()` to the status as `name`, like the hub's picture of the
--- other sessions on the machine; nil leaves it out. It goes when the plugin
--- that added it does.
function M.part(name: string, part: () -> any)
	greed.plugin.tie(core.registry.set(parts, name, part))
end

--- How many agents work and wait for you, from their states ("working",
--- "waiting", ...), as the status line and `greed ls` say it: "◆ 1 working ·
--- 1 waiting for you"; nil when none do.
function M.summary(states: { string }): string?
	local working, waiting = 0, 0
	for _, state in states do
		if state == "working" then
			working += 1
		elseif state == "waiting" then
			waiting += 1
		end
	end
	local parts = {}
	if working > 0 then
		table.insert(parts, `{working} working`)
	end
	if waiting > 0 then
		table.insert(parts, `{waiting} waiting for you`)
	end
	return if #parts > 0 then "◆ " .. table.concat(parts, " · ") else nil
end

agent.tool({
	name = "status",
	description = "This Greed session at a glance: what needs the user (an agent waiting for "
		.. "an answer, a command that finished out of sight), oldest first with why and "
		.. "since when, and the agents at work with their state. inspect gives more on one",
	run = function()
		return M.status()
	end,
})

-- Watching the status (`status/watch`, `greed ctl watch`): each watcher gets
-- the whole status at once, again whenever it changes, and at least every
-- `M.RESEND` milliseconds even when it doesn't, so a watcher that hears
-- nothing for a while knows the session or the way to it is gone. Every
-- message is the whole status, so one missed only means a later look.

--- How often watchers get the status even when nothing changed.
M.RESEND = 15000

-- The connections watching, with the status each was sent last, as JSON.
local watchers: { [number]: string } = {}

-- Sends each watcher the status now: those it changed for, or all of them.
local function tell(all: boolean)
	local now = M.status()
	local text = greed.json.encode(now)
	for connection, last in watchers do
		if all or text ~= last then
			watchers[connection] = text
			pcall(greed.control.send, connection, "status/changed", now)
		end
	end
end

-- Whether a look is due soon, and whether the resending runs.
local due, resending = false, false

-- Looks again soon after something changed: changes come in bursts.
local function changed()
	if due or next(watchers) == nil then
		return
	end
	due = true
	greed.spawn(function()
		greed.sleep(50)
		due = false
		-- Whatever changed, sending the status to those who asked for it is
		-- this plugin's own doing, with its own capabilities.
		greed.vouch(tell, false)
	end)
end

--- Says the status may have changed, as a plugin adding a part (`part`)
--- does when its part changes: watchers look again soon, and hear only
--- if it did.
M.changed = changed

agent.method("status/watch", function(request)
	local connection = request.connection
	if connection == nil then
		error("only a connection to the session can watch its status", 0)
	end
	local now = M.status()
	watchers[connection] = greed.json.encode(now)
	if not resending then
		resending = true
		greed.spawn(function()
			while next(watchers) ~= nil do
				greed.sleep(M.RESEND)
				tell(true)
			end
			resending = false
		end)
	end
	return now
end)

greed.on("control.closed", function(event: greed.ControlClosed)
	watchers[event.connection] = nil
end)

core.attention.on_change(changed)
core.objects.on_changed(function(id)
	if string.sub(id, 1, 14) == "agent-session:" or string.sub(id, 1, 9) == "terminal:" then
		changed()
	end
end)

return M
