-- The session's status, for `greed ctl status`, agents and later the hub:
-- what needs you (core.attention) and the agents at work (objects of kind
-- "agent-session"), in one table. `schema` says its shape, so a reader can
-- tell an older session's from one it doesn't understand.

local greed = require("@greed")
local core = require("@core")
local agent = require("./registry")

local M = {}

--- The shape of the table `status` gives; it goes up when a field changes
--- meaning or goes, not when one is added.
M.SCHEMA = 1

--- This session's status: its name, build and project, what needs you
--- (oldest first) and its agents with their state.
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
	local agents = {}
	for _, found in core.objects.list("agent-session") do
		local state = core.objects.inspect(found)
		state.id = found.id
		state.label = found.label
		table.insert(agents, state)
	end
	return {
		schema = M.SCHEMA,
		session = greed.session.current(),
		build = greed.session.build(),
		root = greed.project.current().root,
		attention = greed.json.array(needs),
		agents = greed.json.array(agents),
	}
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

return M
