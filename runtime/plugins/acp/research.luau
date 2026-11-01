-- Research: an agent hands a question to a helper that can only search the
-- web and read pages, each a few times, and gets back a short report with
-- its sources. The pages stay with the helper, so they never fill the
-- agent's context or reach the agent that edits and runs things. The
-- helper is Greed's own agent, on its caller's model. `:research QUESTION`
-- starts the same helper for you, with its transcript open, where the
-- report ends up.

local greed = require("@greed")
local core = require("@core")
local agent = require("@agent")
local agents = require("./agents")
local native = require("./native")
local session = require("./session")
local subagent = require("./subagent")

type Session = session.Session

local M = {}

--- How subagents start and prompt sessions, and how a session is shown.
export type Sessions = subagent.Sessions & {
	show: (s: Session, where: ("float" | "pane" | "panel" | "tab")?) -> (),
}

--- How many searches and page reads a helper gets, by how far it goes.
M.DEPTHS = {
	quick = { web_search = 3, web_fetch = 5 },
	thorough = { web_search = 8, web_fetch = 15 },
}

-- What the helper is asked, for `question`.
local function task(question: string): string
	return `Research this on the web: {question}\n\n`
		.. "Search, then read the most promising pages, preferring primary sources (official "
		.. "docs, changelogs, the project's own repository) to posts about them. Give web_fetch "
		.. "a question when you need a fact from a page rather than all of it. Your report "
		.. "gives the answer first, then the sources as links, a line each saying what it backs "
		.. "up. Say where sources disagree, and what you couldn't find out."
end

-- Greed's own agent, which a helper with only some tools has to be.
local function greed_agent(): agents.Agent
	return agents.installed("greed") :: agents.Agent
end

--- Adds the `research` tool and `:research`, starting helpers through
--- `sessions`.
function M.offer(sessions: Sessions)
	agent.tool({
		name = "research",
		kind = "fetch",
		group = "web",
		-- The helper asks you before fetching, as any agent does.
		reviews = true,
		parallel = true,
		description = "Research a question on the web: a helper agent searches and reads pages, "
			.. "and only its short report with sources comes back, keeping the pages out of your "
			.. "context. For anything that takes more than one page",
		input = agent.schema.object({
			question = {
				type = "string",
				description = "What to find out, with what you know already",
			},
			depth = {
				type = "string",
				enum = { "quick", "thorough" },
				description = "quick (the default): a few searches and pages; thorough: more of both",
			},
		}, { "question" }),
		run = function(args)
			local chosen = greed_agent()
			local caller, row = native.calling()
			-- On the caller's model, as a helper of Greed's agent is.
			if caller and caller.model then
				chosen = table.clone(chosen)
				chosen.model = caller.model
			end
			local from: subagent.From? = if caller then { session = caller, row = row } else nil
			local calls = M.DEPTHS[args.depth or "quick"] or M.DEPTHS.quick
			local done, err = subagent.run(sessions, chosen, task(args.question), nil, from, calls)
			if done == nil then
				error(err, 0)
			end
			return agent.untrusted(`research on "{args.question}" by a helper`, done.report)
		end,
	})

	greed.command({
		name = "research",
		doc = "Research a question on the web: a helper agent searches and reads pages, its "
			.. "transcript open, and ends with a report with sources",
		args = { { name = "question", doc = "What to find out", type = "rest" } },
		run = function(ctx)
			local s, err = sessions.start(greed_agent(), core.project.root())
			if s == nil then
				greed.echo(err :: string)
				return
			end
			native.limit(s, M.DEPTHS.thorough)
			sessions.show(s)
			greed.spawn(function()
				sessions.prompt(s, task(ctx.values.question))
			end)
		end,
	})
end

return M
