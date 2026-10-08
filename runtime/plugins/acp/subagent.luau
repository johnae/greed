-- Subagents: an agent hands a task to another agent, which works on it in
-- a session of its own and reports back. The helper starts with an empty
-- context, so a long search or a side task doesn't fill the caller's, and
-- by default in a workspace of its own, so its edits wait for you to bring
-- them in. Its transcript is in the session list like any other, and it
-- asks you before doing things, as agents you start do.

local core = require("@core")
local agent = require("@agent")
local agents = require("./agents")
local session = require("./session")

type Session = session.Session

agent.group(
	"subagents",
	"Handing a task to a helper agent with an empty context, and getting its report"
)

local M = {}

--- How subagents start sessions and prompt them: the acp plugin's own
--- `start` and `prompt`.
export type Sessions = {
	start: (chosen: agents.Agent, root: string, own: boolean?) -> (Session?, string?),
	prompt: (s: Session, text: string) -> (boolean, string?),
}

-- At most this many subagents work at once, so a subagent that starts
-- subagents can't start an endless chain of them.
M.LIMIT = 3

local running = 0

-- What the helper is told after the task.
local BRIEF = "\n\n(You're a helper another agent started through the Greed editor. Do the task "
	.. "above, then end with a short report of what you found or did: that report is all the "
	.. "other agent sees.)"

-- What `s` said in its last turn, after the task was sent.
local function report(s: Session): string
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

export type Done = { report: string, session: string, workspace: string?, note: string? }

--- Hands `task` to a new session of `chosen` started through `sessions`,
--- in a workspace of its own unless `here`, waits for it to finish and
--- returns what it reported, with the session. An agent that can't have
--- a workspace, like Greed's own, works in the project, and `note` says
--- so. A turn that fails is an error, not an empty report.
function M.run(
	sessions: Sessions,
	chosen: agents.Agent,
	task: string,
	here: boolean?
): (Done?, string?)
	if running >= M.LIMIT then
		return nil, `{M.LIMIT} subagents are working already; wait for one to finish`
	end
	local note: string? = nil
	if chosen.native and not here then
		here = true
		note = `{chosen.title or chosen.name} can't have a workspace of its own yet, so it `
			.. "worked in the project itself: its edits are in the user's files, as they allowed them"
	end
	running += 1
	local ok, result, err = pcall(function(): (Done?, string?)
		local s, start_err = sessions.start(chosen, core.project.root(), not here)
		if s == nil then
			return nil, start_err
		end
		if not session.ready(s) then
			return nil, s.failed or "the agent didn't start"
		end
		local sent, prompt_err = sessions.prompt(s, task .. BRIEF)
		if not sent then
			return nil, prompt_err
		elseif s.failed then
			return nil, `{s.name} couldn't do it: {s.failed}`
		end
		local done: Done = {
			report = report(s),
			session = s.name,
			workspace = if s.workspace then s.workspace.path else nil,
			note = note,
		}
		return done, nil
	end)
	running -= 1
	if not ok then
		return nil, tostring(result)
	end
	return result, err
end

--- Adds the `subagent` tool, starting agents through `sessions`.
function M.offer(sessions: Sessions)
	agent.tool({
		name = "subagent",
		kind = "execute",
		group = "subagents",
		description = "Hand a task to a helper agent that starts with an empty context and works "
			.. "on it in a session of its own, then reports back: for a search across the project, "
			.. "a side task, or a second opinion, without filling your own context. By default it "
			.. "works in a workspace of its own, so its edits reach the user's files only when they "
			.. "bring them in. Returns its report",
		input = agent.schema.object({
			task = {
				type = "string",
				description = "What to do, with everything it needs to know",
			},
			agent = {
				type = "string",
				description = 'Which agent, e.g. "claude"; the first installed by default',
			},
			here = { type = "boolean", description = "Work in the project itself instead" },
		}, { "task" }),
		run = function(args)
			local chosen = agents.installed(args.agent)
			if chosen == nil then
				error(
					if args.agent then `{args.agent} isn't installed` else "no agent is installed",
					0
				)
			end
			local done, err = M.run(sessions, chosen, args.task, args.here)
			if done == nil then
				error(err, 0)
			end
			local note = if done.workspace
				then `Its changes are in its workspace ({done.workspace}); the user brings them in from the session list (space i l).`
				else done.note
			return { report = done.report, session = done.session, note = note }
		end,
	})
end

return M
