-- Subagents: an agent hands a task to another agent, which works on it in
-- a session of its own and reports back. The helper starts with an empty
-- context, so a long search or a side task doesn't fill the caller's. An
-- agent program works in a workspace of its own by default, so its edits
-- wait for you to bring them in. Greed's own agent, as a helper, works
-- where its caller does and only reads, unless it's told to work there:
-- most of what it's handed is searching, which a workspace would only
-- slow down. Greed's agent hands tasks to Greed's agent with its own model
-- unless it names another, and its call's row in the transcript shows what
-- the helper does as it works; enter on the row shows the helper's
-- transcript, which is in the session list like any other. Helpers ask you
-- before doing things, as agents you start do.

local greed = require("@greed")
local core = require("@core")
local agent = require("@agent")
local agents = require("./agents")
local session = require("./session")
local native = require("./native")
local transcript = require("./transcript")

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

-- What the helper is told after the task; one that only reads hears so.
local function brief(reads_only: boolean): string
	local only = if reads_only
		then " You can only read and search here: say what should change rather than changing it."
		else ""
	return "\n\n(You're a helper another agent started through the Greed editor. Do the task "
		.. "above, then end with a short report of what you found or did: that report is all the "
		.. `other agent sees.{only})`
end

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

-- The most of what a helper does that its row shows, in characters.
local DOING_WIDTH = 50

-- What `helper` is doing now, how long it has worked and the tokens it
-- has used, as its row in the caller's transcript shows them.
local function doing(helper: Session): { string }
	local now = if helper.status == "waiting"
		then "waiting for you"
		elseif helper.status == "starting" then "starting"
		elseif helper.tool then session.first_line(helper.tool)
		else "thinking"
	local out = { core.text.clip(now, DOING_WIDTH) }
	if helper.since then
		table.insert(out, core.time.duration(greed.now() - helper.since, true))
	end
	if helper.tokens then
		table.insert(out, `{transcript.tokens(helper.tokens)} tokens`)
	end
	return out
end

-- Shows on `row`, the call's row in `caller`'s transcript, what `helper`
-- does while the call runs: each time it changes, and each second for the
-- time. Returns what stops it.
local function watch(caller: Session, row: session.Tool, helper: Session): () -> ()
	local watching = true
	local function show()
		if watching and row.status == "in_progress" then
			row.detail = doing(helper)
			caller.changed()
		end
	end
	local inner = helper.changed
	helper.changed = function()
		inner()
		show()
	end
	greed.spawn(function()
		while watching do
			show()
			greed.sleep(1000)
		end
	end)
	return function()
		watching = false
		helper.changed = inner
	end
end

export type Done = { report: string, session: string, workspace: string?, note: string? }

--- Who hands a task on: the session of Greed's agent whose call it is,
--- and that call's row in its transcript, which shows how it goes.
export type From = { session: Session, row: session.Tool? }

--- Hands `task` to a new session of `chosen` started through `sessions`,
--- waits for it to finish and returns what it reported, with the session.
--- An agent program works in a workspace of its own unless `here`; Greed's
--- own works where its caller does, and only reads unless `here`. With `from`,
--- the helper is one of that session's: stopping its turn stops the
--- helper, and the call's row shows what the helper does. A turn that
--- fails is an error, not an empty report.
function M.run(
	sessions: Sessions,
	chosen: agents.Agent,
	task: string,
	here: boolean?,
	from: From?
): (Done?, string?)
	if running >= M.LIMIT then
		return nil, `{M.LIMIT} subagents are working already; wait for one to finish`
	end
	local reads_only = chosen.native == true and not here
	local caller = if from then from.session else nil
	local note: string? = nil
	if chosen.native and here then
		local named = chosen.title or chosen.name
		note = if caller and caller.workspace
			then `{named} worked in your workspace: its edits are there`
			else `{named} worked in the project itself: its edits are in the user's files, `
				.. "as they allowed them"
	end
	-- Greed's helper sees what its caller does: in the caller's workspace,
	-- when it has one.
	local root = if caller and chosen.native
		then caller.cwd
		elseif caller then caller.root
		else core.project.root()
	running += 1
	local helper: Session? = nil
	local unwatch: (() -> ())? = nil
	local ok, result, err = pcall(function(): (Done?, string?)
		local s, start_err = sessions.start(chosen, root, not here and not chosen.native)
		if s == nil then
			return nil, start_err
		end
		helper = s
		if reads_only then
			native.read_only(s)
		end
		if caller then
			local helpers = caller.helpers or {}
			caller.helpers = helpers
			table.insert(helpers, s)
			caller.changed()
		end
		if not session.ready(s) then
			return nil, s.failed or "the agent didn't start"
		end
		local row = if from then from.row else nil
		if caller and row then
			row.helper = s.session_id
			unwatch = watch(caller, row, s)
		end
		local sent, prompt_err = sessions.prompt(s, task .. brief(reads_only))
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
	if unwatch then
		unwatch()
	end
	if caller and helper and caller.helpers then
		local index = table.find(caller.helpers, helper)
		if index then
			table.remove(caller.helpers, index)
		end
		caller.changed()
	end
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
		-- The helper asks you before doing things itself.
		reviews = true,
		parallel = true,
		description = "Hand a task to a helper agent with an empty context; it works on it in a "
			.. "session of its own and returns its report, without filling your context. A main "
			.. "use: surveying one area of the code (what exists, how it fits) for a design question",
		input = agent.schema.object({
			task = {
				type = "string",
				description = "What to do, with everything it needs to know",
			},
			agent = {
				type = "string",
				description = 'Which agent, e.g. "claude"; by default Greed\'s own agent when '
					.. "you are it, else the first installed",
			},
			here = {
				type = "boolean",
				description = "Work in the project itself; without it a Greed helper only reads, "
					.. "and others get a workspace of their own",
			},
		}, { "task" }),
		run = function(args)
			local caller, row = native.calling()
			local name: string? = args.agent or (if caller then "greed" else nil)
			local chosen = agents.installed(name)
			if chosen == nil then
				error(if name then `{name} isn't installed` else "no agent is installed", 0)
			end
			-- Greed's agent as a helper of Greed's agent uses the same model.
			if chosen.native and caller and caller.model then
				local same = table.clone(chosen)
				same.model = caller.model
				chosen = same
			end
			local from: From? = if caller then { session = caller, row = row } else nil
			local done, err = M.run(sessions, chosen, args.task, args.here, from)
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
