-- Agents in Greed over the Agent Client Protocol: Claude Code, Gemini,
-- Codex or any agent that speaks ACP, each in a transcript buffer you write
-- to and read from, working in the project or in a workspace of its own.
--
--   space i n   start an agent: pick which, and where it works
--   space i o   the agents: what each is doing, its changes, review or bring them in
--
-- In a transcript, alt-enter sends what's in the box at the bottom and
-- ctrl-c stops the agent's turn. A question the agent asks shows as a row
-- of choices in the box, answered with enter or a choice's letter in any
-- mode (question.luau).
--
-- Agents are registered by name with the commands that run them; the first
-- one installed is used. Add your own in init.luau:
--
--     require("@acp").register({ name = "mine", commands = { { "my-agent", "--acp" } } })

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")
local vcs = require("@vcs")
local agents = require("@self/agents")
local session = require("@self/session")
local native = require("@self/native")
local transcript = require("@self/transcript")
local question = require("@self/question")
local participants = require("@self/participants")
local review = require("@self/review")
local workspaces = require("@self/workspaces")
local saved = require("@self/saved")
local overview = require("@self/overview")
local statusline = require("@statusline")
local agent_context = require("@agent").context

type Session = session.Session

local M = {}

export type Agent = agents.Agent
export type Saved = saved.Saved

--- Adds an agent to pick from, or replaces the one of the same name. It
--- goes when the plugin (or config) that added it does.
M.register = agents.register

--- The agent called `name`, or the first installed one, if it's installed.
M.installed = agents.installed

greed.option.define({
	name = "agent-greed-tools",
	doc = "Give agents Greed's own tools (buffers, diagnostics, syntax queries, proposals) through greed mcp",
	default = true,
})

--- The MCP servers an agent gets: `greed mcp` for the session `name`, run
--- as `program`, when the editor runs as a session and the option is on.
function M.servers(name: string?, program: string?): { any }
	if name == nil or program == nil or greed.option.get("agent-greed-tools") ~= true then
		return {}
	end
	return {
		{
			name = "greed",
			command = program,
			args = { "mcp" },
			env = { { name = "GREED_SESSION", value = name } },
		},
	}
end

greed.option.define({
	name = "agent-editor-context",
	doc = "Send agents the file you're in, the cursor, the selection and the other files on screen with each message",
	default = true,
})

greed.option.define({
	name = "agent-sessions-kept",
	doc = "How many sessions with Greed's own agent are kept per project to take up again; older ones are deleted",
	default = 50,
})

greed.option.define({
	name = "agent-workspace-edits",
	doc = "Let agents in a workspace of their own edit, move and delete files there without asking",
	default = true,
})

--- A rule that answers an agent's question for you: an option's id, or nil
--- to leave it to the next rule, and in the end to you.
export type Policy = (s: Session, permission: session.Permission) -> string?

local policies: { Policy } = {}

--- Adds a rule that answers agents' questions for you. Rules added later
--- are asked first. It goes when the plugin (or config) that added it
--- does, or when what it returns is called.
function M.policy(rule: Policy): () -> ()
	table.insert(policies, 1, rule)
	local remove = core.registry.remover(policies, rule)
	greed.plugin.tie(remove)
	return remove
end

-- The option of `kind` ("allow_once", ...) among a question's, if any.
local function option_of(permission: session.Permission, kind: string): string?
	for _, option in permission.options do
		if option.kind == kind then
			return option.id
		end
	end
	return nil
end

-- What the agent does in a workspace of its own is for you to bring in or
-- not, so its edits there needn't wait for you. Only there: an edit that
-- doesn't say which files it touches, or touches one elsewhere, asks.
local EDITS = { edit = true, delete = true, move = true }
local function workspace_edits(s: Session, permission: session.Permission): string?
	local locations = permission.locations
	if
		s.workspace == nil
		or not EDITS[permission.kind or ""]
		or greed.option.get("agent-workspace-edits") ~= true
		or locations == nil
	then
		return nil
	end
	for _, path in locations do
		if not session.within(s, path) then
			return nil
		end
	end
	return option_of(permission, "allow_once")
end

local function decide(s: Session, permission: session.Permission): string?
	for _, rule in policies do
		local chosen = rule(s, permission)
		if chosen then
			return chosen
		end
	end
	return workspace_edits(s, permission)
end

-- Sessions, oldest first, and each transcript's session by buffer id.
local sessions: { Session } = {}
local by_buffer: { [number]: Session } = {}
-- The agent each session runs, by session id, for forking it.
local agent_of: { [number]: Agent } = {}
local buffers: { [number]: greed.Buffer } = {}

-- Redraws everything that shows `s`, soon: changes come in bursts while an
-- agent streams.
local queued: { [number]: boolean } = {}
local function changed(s: Session)
	if queued[s.id] then
		return
	end
	queued[s.id] = true
	greed.spawn(function()
		greed.sleep(20)
		queued[s.id] = nil
		local buffer = buffers[s.id]
		if buffer then
			pcall(transcript.render, buffer, s)
		end
		overview.render(sessions)
		participants.draw(sessions)
		saved.keep(s)
	end)
end

local function trim(text: string): string
	return string.match(text, "^%s*(.-)%s*$") or ""
end

-- Starts a session of `agent` in `workspace` (or the project at `root`),
-- with `extra` saying what to take up or fork.
local function launch(
	agent: Agent,
	root: string,
	workspace: session.Workspace?,
	extra: { load: string?, fork: string?, entries: { session.Entry }? }?
): (Session?, string?)
	local command = agents.command_of(agent)
	if command == nil then
		return nil,
			`{agent.title or agent.name} isn't installed: {table.concat(agent.commands[1], " ")}`
	end
	local count = 1
	for _, s in sessions do
		if s.agent == agent.name then
			count += 1
		end
	end
	local name = (agent.title or agent.name) .. (if count > 1 then ` {count}` else "")
	local s: Session
	local function decides(permission: session.Permission): string?
		return decide(s, permission)
	end
	local function changes()
		changed(s)
	end
	if agent.native then
		if workspace or (extra and extra.fork) then
			return nil,
				`{name} works in the project itself; it can't have a workspace or be forked yet`
		end
		local started, err = native.start({
			name = name,
			agent = agent.name,
			root = root,
			role = agent.model,
			resume = extra and extra.load,
			decide = decides,
			changed = changes,
		})
		if started == nil then
			return nil, err
		end
		s = started
	else
		s = session.start({
			name = name,
			agent = agent.name,
			command = command,
			root = root,
			cwd = if workspace then workspace.path else root,
			workspace = workspace,
			servers = M.servers(greed.session.current(), greed.session.program()),
			decide = decides,
			load = extra and extra.load,
			fork = extra and extra.fork,
			entries = extra and extra.entries,
			changed = changes,
		})
	end
	table.insert(sessions, s)
	agent_of[s.id] = agent
	local buffer = transcript.create(s)
	buffers[s.id] = buffer
	by_buffer[buffer:id()] = s
	overview.render(sessions)
	local model = if agent.native then nil else agent.model
	if model then
		-- The model asked for, once the agent says which it has.
		greed.spawn(function()
			if session.ready(s) and s.model ~= model then
				local ok, err = session.set_model(s, model)
				if not ok then
					greed.echo(`{s.name} can't use the model {model}: {err}`)
				end
			end
		end)
	end
	return s, nil
end

--- Starts a session of `agent` for the project at `root`, in a workspace
--- of its own if `own` is set.
function M.start(agent: Agent, root: string, own: boolean?): (Session?, string?)
	local workspace = nil
	if own and agent.native then
		return nil,
			`{agent.title or agent.name} works in the project itself; it can't have a workspace yet`
	elseif own then
		local made, err = workspaces.make(root, agent.name)
		if made == nil then
			return nil, err
		end
		workspace = made
	end
	return launch(agent, root, workspace)
end

--- The sessions you can take up again for the project at `root`, newest
--- first, leaving out the ones running now.
function M.saved(root: string): { Saved }
	return saved.list(root, sessions)
end

--- Takes up a session kept from before, in a new transcript: an ACP agent
--- tells the conversation again, Greed's own reads back what it kept.
function M.resume(entry: Saved): (Session?, string?)
	local agent = agents.named(entry.agent)
	if agent == nil then
		return nil, `no agent called {entry.agent} is registered`
	end
	local ws = entry.workspace
	if ws and not greed.fs.stat(ws.path) then
		return nil, `its workspace is gone: {ws.path}`
	end
	return launch(agent, entry.root, ws, { load = entry.session_id })
end

--- Forks `s`: a new session that starts with everything said so far, in a
--- workspace of its own made from `s`'s if it has one.
function M.fork(s: Session): (Session?, string?)
	local agent = agent_of[s.id]
	if agent == nil or s.session_id == nil then
		return nil, "it hasn't started yet"
	end
	local workspace = nil
	if s.workspace then
		local made, err = workspaces.make(s.root, agent.name, s.workspace)
		if made == nil then
			return nil, err
		end
		workspace = made
	end
	local entries: { session.Entry } = {}
	for _, entry in s.entries do
		local copy = table.clone(entry)
		-- Folding one shouldn't fold the other.
		if entry.tool then
			copy.tool = table.clone(entry.tool)
		end
		table.insert(entries, copy)
	end
	table.insert(entries, { kind = "note", text = `forked from {s.name}` })
	return launch(agent, s.root, workspace, { fork = s.session_id, entries = entries })
end

--- Shows the transcript of `s` in a panel on the right, with the cursor in
--- its prompt.
function M.show(s: Session)
	local buffer = buffers[s.id]
	if buffer == nil then
		return
	end
	local view = greed.panel(buffer, { side = "right", width = "45%", title = s.name })
	view:focus()
	transcript.focus_prompt(view)
end

--- Every session, oldest first.
function M.sessions(): { Session }
	return table.clone(sessions)
end

--- The session whose transcript `buffer` is.
function M.of(buffer: greed.Buffer): Session?
	return by_buffer[buffer:id()]
end

--- Sends `text` to `s`, waiting for its turn to end.
function M.prompt(s: Session, text: string): (boolean, string?)
	return session.prompt(s, text)
end

--- Compacts the conversation of `s`, a session of Greed's own agent: the
--- model summarises all but its last few turns, which saves room in its
--- context. It happens by itself near the model's limit.
M.compact = native.compact

--- Switches tool group `group` on for `s`, a session of Greed's own agent,
--- as the agent would with the tools tool, e.g. to start it with the tools
--- a task needs.
M.switch_on = native.switch_on

--- Brings what `s` changed in its workspace into yours: with jj its change
--- is squashed into your working copy, with git its diff is applied.
M.bring = workspaces.bring

--- Stops the agent of `s`, keeping its transcript, its workspace and the
--- session to take up again.
function M.stop(s: Session)
	session.stop(s)
	changed(s)
end

--- Stops `s` and, if it had a workspace, removes it.
function M.close(s: Session)
	saved.remember(s, true)
	session.stop(s)
	workspaces.remove(s)
	local index = table.find(sessions, s)
	if index then
		table.remove(sessions, index)
	end
	local buffer = buffers[s.id]
	buffers[s.id] = nil
	if buffer then
		by_buffer[buffer:id()] = nil
		buffer:set_kept(false)
	end
	overview.render(sessions)
	participants.draw(sessions)
end

--- Shows the agents overview in `view`.
function M.overview(view: greed.View)
	overview.open(view, sessions)
end

-- The session `ctx` is about: the transcript it's in, or the overview line.
local function current(ctx: greed.Context): Session?
	return by_buffer[ctx.buffer:id()] or overview.at_cursor(ctx)
end

-- Commands -------------------------------------------------------------------

greed.command({
	name = "agent-new",
	doc = "Start an agent over ACP: pick which, and whether it works in a workspace of its own",
	run = function(ctx)
		local items = {}
		for _, agent in agents.list do
			local command = agents.command_of(agent)
			local how = if agent.native
				then "in the editor, with the model in :models"
				elseif command then table.concat(command, " ")
				else "not installed"
			table.insert(items, { label = `{agent.title or agent.name}  ({how})`, value = agent })
		end
		local agent = picker.choose("Agent", items)
		if agent == nil then
			return
		end
		-- Greed's own agent works in the project; there's nothing to ask.
		local place = if agent.value.native
			then { value = "here" }
			else picker.choose("Where it works", {
				{ label = "In a workspace of its own", value = "own" },
				{ label = "In the project, with you", value = "here" },
			})
		if place == nil then
			return
		end
		local s, err = M.start(agent.value, core.project.root(), place.value == "own")
		if s == nil then
			greed.echo(err :: string)
			return
		end
		M.show(s)
	end,
})

greed.command({
	name = "agents",
	doc = "Show the agents: what each is doing, its changes, and bring them in",
	run = function(ctx)
		M.overview(ctx.view)
	end,
})

greed.command({
	name = "agent-send",
	doc = "Send what's in the transcript's box to its agent",
	run = function(ctx)
		local s = by_buffer[ctx.buffer:id()]
		if s == nil then
			return
		end
		local text = trim(transcript.prompt(ctx.buffer))
		if text == "" then
			greed.echo("write a message in the box first")
			return
		end
		if s.status == "working" or s.status == "waiting" then
			greed.echo("the agent is still working; ctrl-c stops it")
			return
		end
		transcript.clear_prompt(ctx.buffer)
		local context = if greed.option.get("agent-editor-context") == true
			then agent_context.describe(s.root)
			else nil
		local ok, err = session.prompt(s, text, context)
		if not ok then
			greed.echo(err :: string)
		end
	end,
})

greed.command({
	name = "agent-fold",
	doc = "Show all of the output of the tool call under the cursor, or fold it again",
	run = function(ctx)
		local s = by_buffer[ctx.buffer:id()]
		if s == nil then
			return
		end
		local cursor = ctx.buffer:line_of(ctx.view:cursor())
		local id = transcript.tool_at(ctx.buffer, cursor)
		local tool = id and s.tools[id]
		if tool == nil then
			return
		end
		tool.open = not tool.open
		transcript.render(ctx.buffer, s)
		-- Redrawing moved what followed the tool's line; the cursor stays on it.
		local line = transcript.line_of_tool(ctx.buffer, tool.id)
		if line then
			local pos = ctx.buffer:line_start(line)
			ctx.view:set_cursor(pos)
		end
	end,
})

greed.command({
	name = "agent-mode",
	doc = "Pick the mode the agent works in, like plan or accept edits",
	run = function(ctx)
		local s = current(ctx)
		if s == nil then
			return
		elseif #s.modes == 0 then
			greed.echo(`{s.name} has no modes to pick from`)
			return
		end
		local items = {}
		for _, mode in s.modes do
			local now = if mode.id == s.mode then "  (now)" else ""
			local about = if mode.description then `: {mode.description}` else ""
			table.insert(items, { label = `{mode.name}{about}{now}`, value = mode.id })
		end
		local chosen = picker.choose("Mode", items)
		if chosen then
			local ok, err = session.set_mode(s, chosen.value)
			if not ok then
				greed.echo(`can't: {err}`)
			end
		end
	end,
})

greed.command({
	name = "agent-model",
	doc = "Pick the model the agent uses, from those it offers",
	run = function(ctx)
		local s = current(ctx)
		if s == nil then
			return
		elseif #s.models == 0 then
			greed.echo(`{s.name} has no models to pick from`)
			return
		end
		local items = {}
		for _, model in s.models do
			local now = if model.id == s.model then "  (now)" else ""
			local about = if model.description then `: {model.description}` else ""
			table.insert(items, { label = `{model.name}{about}{now}`, value = model.id })
		end
		local chosen = picker.choose("Model", items)
		if chosen then
			local ok, err = session.set_model(s, chosen.value)
			if not ok then
				greed.echo(`can't: {err}`)
			end
		end
	end,
})

greed.command({
	name = "agent-resume",
	doc = "Take up an earlier session with an agent in this project, where it left off",
	run = function()
		local root = core.project.root()
		local items = {}
		for _, entry in M.saved(root) do
			local where = if entry.workspace then `  (workspace {entry.workspace.name})` else ""
			table.insert(items, { label = `{entry.agent}: {entry.title}{where}`, value = entry })
		end
		if #items == 0 then
			greed.echo("no earlier sessions in this project")
			return
		end
		local chosen = picker.choose("Take up", items)
		if chosen == nil then
			return
		end
		local s, err = M.resume(chosen.value)
		if s == nil then
			greed.echo(err :: string)
			return
		end
		M.show(s)
	end,
})

greed.command({
	name = "agent-fork",
	doc = "Fork the agent: a new session that starts with everything said so far",
	run = function(ctx)
		local s = current(ctx)
		if s == nil then
			return
		end
		local fork, err = M.fork(s)
		if fork == nil then
			greed.echo(`can't fork: {err}`)
			return
		end
		M.show(fork)
	end,
})

greed.command({
	name = "agent-compact",
	doc = "Compact the conversation with Greed's own agent: the model summarises all but the last few turns",
	run = function(ctx)
		local s = current(ctx)
		if s == nil then
			return
		end
		local ok, err = M.compact(s)
		greed.echo(if ok then "compacted the conversation" else `can't compact: {err}`)
	end,
})

greed.command({
	name = "agent-stop",
	doc = "Stop the agent's turn",
	run = function(ctx)
		local s = current(ctx)
		if s then
			session.cancel(s)
		end
	end,
})

greed.command({
	name = "agent-answer",
	doc = "Show the question the agent waits on in the box, to answer it there",
	run = function(ctx)
		local s = current(ctx)
		local buffer = s and buffers[s.id]
		if s == nil or buffer == nil or not question.show(s) then
			greed.echo("no question waiting")
			return
		end
		transcript.render(buffer, s)
	end,
})

greed.command({
	name = "agents-open",
	doc = "Open the transcript of the agent under the cursor",
	run = function(ctx)
		local s = overview.at_cursor(ctx)
		if s then
			M.show(s)
		end
	end,
})

greed.command({
	name = "agents-diff",
	doc = "Show what the agent under the cursor changed in its workspace",
	run = function(ctx)
		local s = current(ctx)
		if s == nil then
			return
		end
		local text, err = workspaces.changes(s)
		if text == nil then
			greed.echo(err :: string)
			return
		end
		local buffer =
			vcs.diffs.buffer("agent-diff", if text == "" then "nothing changed yet\n" else text)
		ctx.view:show(buffer)
	end,
})

greed.command({
	name = "agents-bring",
	doc = "Bring what the agent under the cursor changed into your working copy",
	run = function(ctx)
		local s = current(ctx)
		if s == nil then
			return
		end
		local ok, err = M.bring(s)
		greed.echo(if ok then `brought in what {s.name} changed` else `can't: {err}`)
	end,
})

greed.command({
	name = "agents-review",
	doc = "Review what the agent under the cursor changed as proposals on your files",
	run = function(ctx)
		local s = current(ctx)
		if s == nil then
			return
		end
		local reviewed, err = review.review(s)
		if reviewed == nil then
			greed.echo(`can't: {err}`)
			return
		end
		local left = #reviewed.left
		local note = if left > 0 then `; left out changes to {left} files, d shows them` else ""
		if reviewed.decided == nil then
			greed.echo(`nothing to review{note}`)
		elseif left > 0 then
			greed.echo(`reviewed what {s.name} changed{note}`)
		end
	end,
})

greed.command({
	name = "agents-close",
	doc = "Stop the agent under the cursor and remove its workspace, after asking",
	run = function(ctx)
		local s = overview.at_cursor(ctx)
		if s == nil then
			return
		end
		greed.echo(`stop {s.name}{if s.workspace then " and remove its workspace" else ""}? y/n`)
		local yes = greed.next_key() == "y"
		greed.echo("")
		if yes then
			M.close(s)
		end
	end,
})

-- A file opened while an agent works in it shows where at once.
greed.on("buffer.opened", function()
	participants.draw(sessions)
end)

--- How many agents work and wait for you, as the status line shows it;
--- nil when none do.
function M.status(): string?
	return participants.status(sessions)
end

statusline.add("right", "agents", function()
	local text = M.status()
	return if text then { text = text, style = "ui.statusline.message" } else nil
end, "position")

greed.keymap.bind({ mode = "normal", kind = "agent-transcript" }, {
	enter = "agent-answer",
	["ctrl-c"] = "agent-stop",
	tab = "agent-fold",
})
greed.keymap.bind({ mode = "normal", kind = "agents" }, {
	enter = "agents-open",
	n = "agent-new",
	d = "agents-diff",
	b = "agents-bring",
	r = "agents-review",
	s = "agent-stop",
	x = "agents-close",
	f = "agent-fork",
	q = "buffer-close",
})
-- These work while typing too, in every style.
local function transcript_keys(mode: string)
	greed.keymap.bind({ mode = mode, kind = "agent-transcript" }, {
		["alt-enter"] = "agent-send",
		["alt-p"] = "agent-answer",
		["alt-m"] = "agent-mode",
		["alt-M"] = "agent-model",
	})
end
transcript_keys("normal")
core.style.each_typing(transcript_keys)
greed.keymap.bind("normal", {
	["space i n"] = "agent-new",
	["space i o"] = "agents",
	["space i r"] = "agent-resume",
})

--- Agents handing tasks to other agents (subagent.luau).
M.subagent = require("@self/subagent")
--- An agent's workspace changes as proposals on your files (review.luau).
M.review = review
M.subagent.offer(M)

-- An agent at work keeps the session on :q (core's on-quit).
core.file.running("agents", function()
	local found = {}
	for _, s in sessions do
		if s.status == "working" or s.status == "waiting" then
			table.insert(found, `{s.name} at work`)
		end
	end
	return found
end)

return M
