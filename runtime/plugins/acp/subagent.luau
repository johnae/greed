-- Subagents: an agent hands a task to another agent, which works on it in
-- a session of its own and reports back. The helper starts with an empty
-- context, so a long search or a side task doesn't fill the caller's, and
-- by default in a workspace of its own, so its edits wait for you to bring
-- them in. Its transcript is in `:agents` like any other, and it asks you
-- before doing things, as agents you start do.

local greed = require("@greed")
local core = require("@core")
local agent = require("@agent")
agent.group(
	"subagents",
	"Handing a task to a helper agent with an empty context, and getting its report"
)

local M = {}

-- At most this many subagents work at once, so a subagent that starts
-- subagents can't start an endless chain of them.
M.LIMIT = 3

local running = 0

-- What the helper is told after the task.
local BRIEF = "\n\n(You're a helper another agent started through the Greed editor. Do the task "
	.. "above, then end with a short report of what you found or did: that report is all the "
	.. "other agent sees.)"

-- What `s` said in its last turn, after the task was sent.
local function report(s: any): string
	local said = {}
	for i = #s.entries, 1, -1 do
		local entry = s.entries[i]
		if entry.kind == "user" then
			break
		elseif entry.kind == "agent" and entry.text then
			table.insert(said, 1, entry.text)
		end
	end
	return table.concat(said, "\n")
end

export type Done = { report: string, session: string, workspace: string? }

--- Hands `task` to a new session of `chosen` (an `acp.Agent`), in a
--- workspace of its own unless `here`, waits for it to finish and returns
--- what it reported, with the session.
function M.run(acp: any, chosen: any, task: string, here: boolean?): (Done?, string?)
	if running >= M.LIMIT then
		return nil, `{M.LIMIT} subagents are working already; wait for one to finish`
	end
	running += 1
	local ok, result, err = pcall(function(): (Done?, string?)
		local s, start_err = acp.start(chosen, core.project.root(), not here)
		if s == nil then
			return nil, start_err
		end
		while s.status == "starting" do
			greed.sleep(50)
		end
		if s.status == "exited" then
			return nil, "the agent exited as it started"
		end
		local sent, prompt_err = acp.prompt(s, task .. BRIEF)
		if not sent then
			return nil, prompt_err
		end
		return {
			report = report(s),
			session = s.name,
			workspace = if s.workspace then s.workspace.path else nil,
		}
	end)
	running -= 1
	if not ok then
		return nil, tostring(result)
	end
	return result, err
end

--- Adds the `subagent` tool, starting agents through `acp`.
function M.offer(acp: any, installed: (name: string?) -> any)
	agent.tool({
		name = "subagent",
		kind = "execute",
		group = "subagents",
		description = "Hand a task to a helper agent that starts with an empty context and works "
			.. "on it in a session of its own, then reports back: for a search across the project, "
			.. "a side task, or a second opinion, without filling your own context. By default it "
			.. "works in a workspace of its own, so its edits reach the user's files only when they "
			.. "bring them in. Returns its report",
		input = {
			type = "object",
			properties = {
				task = {
					type = "string",
					description = "What to do, with everything it needs to know",
				},
				agent = {
					type = "string",
					description = 'Which agent, e.g. "claude"; the first installed by default',
				},
				here = { type = "boolean", description = "Work in the project itself instead" },
			},
			required = { "task" },
		},
		run = function(args)
			local chosen = installed(args.agent)
			if chosen == nil then
				error(
					if args.agent then `{args.agent} isn't installed` else "no agent is installed",
					0
				)
			end
			local done, err = M.run(acp, chosen, args.task, args.here)
			if done == nil then
				error(err, 0)
			end
			local note = if done.workspace
				then `Its changes are in its workspace ({done.workspace}); the user brings them in from :agents.`
				else nil
			return { report = done.report, session = done.session, note = note }
		end,
	})
end

return M
