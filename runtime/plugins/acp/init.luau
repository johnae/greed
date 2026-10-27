-- Agents in Greed over the Agent Client Protocol: Claude Code, Gemini,
-- Codex or any agent that speaks ACP, each in a transcript buffer you write
-- to and read from, working in the project or in a workspace of its own.
--
--   space i n   start an agent: pick which, and where it works
--   space i l   the sessions, running and kept: show, take up, review or bring them in
--   space i m   move this session's transcript to a pane, tab, float or panel
--
-- In a transcript, alt-enter sends what's in the box at the bottom (queued
-- while the agent works) and ctrl-c stops the agent's turn. A question the
-- agent asks shows as a row of choices in the box, answered with enter or
-- a choice's letter in any mode, or rejected with esc (question.luau).
-- Enter or a click on a row opens it (a helper's transcript, a tool's
-- output, a thought), and alt-up and alt-down highlight rows to open from
-- the box (transcript.luau's `pick`).
-- A message like /model or /effort high runs one of Greed's chat commands
-- instead of going to the agent, and tab after / completes them
-- (slash.luau).
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
local code = require("@self/code")
local question = require("@self/question")
local participants = require("@self/participants")
local review = require("@self/review")
local workspaces = require("@self/workspaces")
local saved = require("@self/saved")
local list = require("@self/list")
local auto = require("@self/auto")
require("@self/decision_check")
local panes = require("@panes")
local statusline = require("@statusline")
local models = require("@models")
local agent_api = require("@agent")
local agent_context = agent_api.context
local terminal = require("@terminal")
local slash = require("@self/slash")
local overlap = require("@self/overlap")

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
	needs = "eval",
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
	doc = "How many sessions with Greed's own agent are kept per repository to take up again; older ones are deleted",
	default = 50,
})

greed.option.define({
	name = "agent-compact-at",
	doc = "Compact conversations with Greed's own agent once they reach this many tokens; 0 waits until they near the model's limit",
	default = 0,
})

greed.option.define({
	name = "agent-max-turns",
	doc = "Stop Greed's own agent after this many steps in one prompt, for runs nobody watches; 0 lets it work until it's done",
	default = 0,
})

greed.option.define({
	name = "agent-max-tokens",
	doc = "Stop Greed's own agent once a session has read and written this many tokens, every request counted; 0 sets no limit",
	default = 0,
})

greed.option.define({
	name = "agent-max-thought",
	doc = "Stop a thought of Greed's own agent once it passes this many tokens, before it acts, and ask for smaller steps; 0 lets thoughts run on",
	default = 8000,
})

greed.option.define({
	name = "agent-care",
	doc = 'How Greed\'s own agent gathers context: "thorough" maps what exists with helpers before '
		.. 'design questions and says what it checked; "quick" only reads what an answer depends on',
	default = "thorough",
	choices = { "thorough", "quick" },
})

greed.option.define({
	name = "agent-thoughts",
	doc = "Show what agents think in their transcripts, each thought folded to its first line (tab unfolds it); /thoughts switches it",
	default = true,
})

greed.option.define({
	name = "agent-workspace-edits",
	needs = "eval",
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
	greed.plugin.cleanup(remove)
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
		or session.outside(s, locations)
	then
		return nil
	end
	return option_of(permission, "allow_once")
end

-- The option a rule picks for `permission`, and why, the rules you added
-- first, then auto mode's.
local function decide(s: Session, permission: session.Permission): (string?, string?)
	for _, rule in policies do
		local chosen = rule(s, permission)
		if chosen then
			return chosen, nil
		end
	end
	local verdict, why = auto.decide(s, permission)
	local option = if verdict == "allow"
		then option_of(permission, "allow_once")
		elseif verdict == "block" then option_of(permission, "reject_once")
		else nil
	if option then
		if verdict == "block" and why and s.driver == nil then
			-- An ACP agent's answer can only be an option: why goes to it
			-- as the next message, once its turn ends, to find another way.
			session.queue(s, `{permission.title}: {auto.refusal(why)}`, true)
		end
		return option, why
	end
	return workspace_edits(s, permission), nil
end

-- Sessions, oldest first, and each transcript's session by buffer id.
local sessions: { Session } = {}
local by_buffer: { [number]: Session } = {}
-- The agent each session runs, by session id, for forking it.
local agent_of: { [number]: Agent } = {}
local buffers: { [number]: greed.Buffer } = {}
-- When each session last did something, in seconds since 1970.
local active: { [number]: number } = {}

-- The terminal of each session of Claude Code in a terminal, by session id
-- (see `in_terminal`): its buffer shows it instead of a transcript.
local terms: { [number]: terminal.Term } = {}

-- Redraws everything that shows `s`, soon: changes come in bursts while an
-- agent streams.
local queued: { [number]: boolean } = {}
-- Each session's status when last redrawn, to tell when a turn ends.
local last_status: { [number]: string } = {}
local function changed(s: Session)
	active[s.id] = os.time()
	if queued[s.id] then
		return
	end
	queued[s.id] = true
	greed.spawn(function()
		greed.sleep(20)
		queued[s.id] = nil
		local buffer = buffers[s.id]
		local shown = buffer and buffer:valid() and terms[s.id] == nil
		if shown then
			pcall(transcript.render, buffer, s)
		end
		-- Waiting for you: the status says so, and its float, if it has one.
		core.attention.set(
			`agent-session:{s.id}`,
			if s.status == "waiting"
				then {
					label = saved.title(s),
					reason = "waits for your answer",
					buffer = if shown then buffer else nil,
				}
				else nil
		)
		list.render()
		participants.draw(sessions)
		saved.keep(s)
		-- A turn just ended in a workspace of its own: did another agent
		-- change the same files?
		local was = last_status[s.id]
		last_status[s.id] = s.status
		if was ~= s.status then
			core.objects.changed(`agent-session:{s.id}`)
		end
		if was == "working" and s.status == "idle" and s.workspace then
			overlap.check(s, sessions)
		end
	end)
end

-- `named`, numbered from 2 while sessions have it, to name a new one.
local function fresh_name(named: string): string
	local name, count = named, 1
	local function taken(): boolean
		for _, other in sessions do
			if other.name == name then
				return true
			end
		end
		return false
	end
	while taken() do
		count += 1
		name = `{named} {count}`
	end
	return name
end

-- Starts a session of `agent` in `workspace` (or the project at `root`),
-- with `extra` saying what to take up or fork: the agent's session id to
-- fork, or for Greed's own agent the session itself (`from`).
local function launch(
	agent: Agent,
	root: string,
	workspace: session.Workspace?,
	extra: {
		load: string?,
		fork: string?,
		from: Session?,
		entries: { session.Entry }?,
	}?
): (Session?, string?)
	local command = agents.command_of(agent)
	if command == nil then
		return nil, agents.missing(agent)
	end
	local name = fresh_name(agent.title or agent.name)
	local s: Session
	local function decides(permission: session.Permission): (string?, string?)
		return decide(s, permission)
	end
	-- An agent that exits as it starts changes before it's listed; listing it
	-- shows that.
	local function changes()
		if s ~= nil then
			changed(s)
		end
	end
	if agent.native then
		local started, err = native.start({
			name = name,
			agent = agent.name,
			root = root,
			workspace = workspace,
			role = agent.model,
			resume = extra and extra.load,
			from = extra and extra.from,
			entries = extra and extra.entries,
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
	active[s.id] = os.time()
	local buffer = transcript.create(s)
	buffers[s.id] = buffer
	by_buffer[buffer:id()] = s
	list.render()
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
	if own then
		local made, err = workspaces.make(root, agent.name)
		if made == nil then
			return nil, err
		end
		workspace = made
	end
	return launch(agent, root, workspace)
end

-- Claude Code run in a terminal, in a workspace of its own (`space i W`):
-- listed with the other sessions so its work comes back the same way (d,
-- R, b, x). You talk to it in its terminal; taken up again, it runs
-- `claude --continue` there.
local IN_TERMINAL = "claude-terminal"

local TERMINAL: session.Driver = {
	prompt = function()
		return false, "it runs in its terminal; type there"
	end,
	cancel = function() end,
	set_model = function()
		return false, "pick its model in Claude Code"
	end,
	stop = function(s)
		local term = terms[s.id]
		terms[s.id] = nil
		if term and terminal.is_open(term) then
			terminal.close(term)
		end
		agent_api.claude.forget_folder(s.cwd)
	end,
}

-- Starts Claude Code in a terminal in `ws`, a workspace of the project at
-- `root`, with `extra` arguments, as a session titled `title`.
local function in_terminal(
	root: string,
	ws: session.Workspace,
	extra: { string }?,
	title: string?
): (Session?, string?)
	local ok, term = pcall(agent_api.claude.open, ws.path, extra)
	if not ok then
		return nil, `can't start Claude Code: {term}`
	end
	local s: Session
	s = session.start_driven({
		name = fresh_name("Claude Code"),
		agent = IN_TERMINAL,
		root = root,
		cwd = ws.path,
		workspace = ws,
		changed = function()
			changed(s)
		end,
		driver = TERMINAL,
	})
	-- What it's kept by: Claude Code keeps its own by folder.
	s.session_id = ws.name
	if title then
		table.insert(s.entries, { kind = "user", text = title })
	end
	terms[s.id] = term
	table.insert(sessions, s)
	active[s.id] = os.time()
	buffers[s.id] = term.buffer
	by_buffer[term.buffer:id()] = s
	changed(s)
	return s, nil
end

-- A session's terminal ended: it's exited, to take up again from the list.
greed.on("terminal.exited", function(event)
	for id, term in terms do
		if term.terminal == event.terminal then
			terms[id] = nil
			for _, s in sessions do
				if s.id == id then
					s.status = "exited"
					changed(s)
				end
			end
		end
	end
end)

--- Starts Claude Code in a terminal, in a workspace of its own for the
--- project at `root`, on `prompt` if given. It's listed with the other
--- sessions, and its work comes back the same way.
function M.claude_in_workspace(root: string, prompt: string?): (Session?, string?)
	local ws, err = workspaces.make(root, "claude")
	if ws == nil then
		return nil, err
	end
	-- Told where it works and how its work gets back, as Greed's own agent is.
	local args = { "--append-system-prompt", workspaces.note(ws, root) }
	if prompt then
		table.insert(args, prompt)
	end
	local s, start_err = in_terminal(root, ws, args, prompt)
	if s == nil then
		workspaces.remove({ root = root, workspace = ws })
	end
	return s, start_err
end

--- The sessions you can take up again for the repository of `root`, in any
--- of its workspaces, newest first, leaving out the ones running now.
function M.saved(root: string): { Saved }
	return saved.list(root, sessions)
end

--- Takes up a session kept from before, in a new transcript: an ACP agent
--- tells the conversation again, Greed's own reads back what it kept. It
--- works where it did, or in `here`, another workspace of its repository:
--- only Greed's own sessions can move, since other agents keep theirs by
--- folder.
function M.resume(entry: Saved, here: string?): (Session?, string?)
	if entry.agent == IN_TERMINAL then
		local ws = entry.workspace
		if ws == nil or not greed.fs.stat(ws.path) then
			return nil, `its workspace is gone{if ws then ": " .. ws.path else ""}`
		end
		local title = if entry.title ~= saved.UNTITLED then entry.title else nil
		return in_terminal(entry.root, ws, { "--continue" }, title)
	end
	local agent = agents.named(entry.agent)
	if agent == nil then
		return nil, `no agent called {entry.agent} is registered`
	end
	local ws = entry.workspace
	local root = entry.root
	if here and here ~= root then
		if not agent.native then
			return nil, `{agent.title or agent.name} keeps its sessions by folder`
		elseif ws then
			return nil, "it works in a workspace of its own"
		elseif vcs.repo.identity(here) ~= vcs.repo.identity(root) then
			return nil, "that isn't a workspace of its repository"
		end
		root = here
	end
	if ws and not greed.fs.stat(ws.path) then
		return nil, `its workspace is gone: {ws.path}`
	end
	return launch(agent, root, ws, { load = entry.session_id })
end

--- Forks `s`: a new session that starts with everything said so far, in a
--- workspace of its own made from `s`'s if it has one.
function M.fork(s: Session): (Session?, string?)
	local agent = agent_of[s.id]
	if s.agent == IN_TERMINAL then
		return nil, "Claude Code in a terminal can't be forked here"
	elseif agent == nil or s.session_id == nil then
		return nil, "it hasn't started yet"
	elseif agent.native and (s.status == "working" or s.status == "waiting") then
		-- Its conversation is half way through a turn.
		return nil, "it's working; wait for it or stop it first"
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
	-- Greed's own agent goes on from the session itself; others fork theirs.
	if agent.native then
		return launch(agent, s.root, workspace, { from = s, entries = entries })
	end
	return launch(agent, s.root, workspace, { fork = s.session_id, entries = entries })
end

--- Where a transcript shows: a panel on the right, a pane of the tab, a
--- tab of its own or a floating view.
export type Placement = "panel" | "pane" | "tab" | "float"

-- The transcript of `s`, made again if it was closed (with :bc, say).
local function buffer_of(s: Session): greed.Buffer
	local buffer = buffers[s.id]
	if buffer and buffer:valid() then
		return buffer
	elseif s.agent == IN_TERMINAL then
		error("its terminal has ended; take it up again from the list (space i l)", 0)
	elseif buffer then
		by_buffer[buffer:id()] = nil
	end
	local made = transcript.create(s)
	buffers[s.id] = made
	by_buffer[made:id()] = s
	return made
end

-- Whether `view` is shown the way `where` says.
local function shown_as(view: greed.View, where: Placement): boolean
	local floating = view:float_spec() ~= nil
	if where == "float" or where == "panel" then
		return floating == (where == "float") and not view:is_pane()
	elseif not view:is_pane() then
		return false
	elseif where == "pane" then
		return true
	end
	for _, tab in greed.tab.list() do
		if #tab.panes == 1 and tab.panes[1] == view then
			return true
		end
	end
	return false
end

-- The panes' sizes as they're split, by view id, for those split since
-- they were last drawn.
type Sizes = { [number]: { rows: number, cols: number } }

-- A new pane showing `buffer`, split from the tab's biggest along its
-- longer side.
local function split(buffer: greed.Buffer, sizes: Sizes): greed.View
	local tab = greed.tab.current()
	local best, most = tab.active, { rows = 0, cols = 0 }
	for _, pane in tab.panes do
		local rows, cols = pane:size()
		local size = sizes[pane:id()] or { rows = rows or 24, cols = cols or 80 }
		if size.rows * size.cols > most.rows * most.cols then
			best, most = pane, size
		end
	end
	local side: panes.Direction = panes.split_side(most.rows, most.cols)
	local view = best:split(side, buffer)
	local half = if side == "right"
		then { rows = most.rows, cols = most.cols // 2 }
		else { rows = most.rows // 2, cols = most.cols }
	sizes[best:id()] = half
	sizes[view:id()] = half
	return view
end

local function open_in(
	buffer: greed.Buffer,
	name: string,
	where: Placement,
	sizes: Sizes
): greed.View
	if where == "panel" then
		return greed.panel(buffer, { side = "right", width = "45%", title = name })
	elseif where == "float" then
		return panes.floats.show(buffer, { title = name })
	elseif where == "tab" then
		greed.tab.rename(greed.tab.new(buffer), name)
		return greed.tab.current().active
	end
	return split(buffer, sizes)
end

-- What a row of the list shows: a session's transcript, or the terminal an
-- agent runs in, called `name`.
type Shown = { buffer: greed.Buffer, name: string, terminal: boolean }

local function shown_of(s: Session): Shown
	return { buffer = buffer_of(s), name = s.name, terminal = terms[s.id] ~= nil }
end

-- Shows `shown` as `where` says, moving it there from wherever else it
-- shows, or where it shows already (a terminal in a pane if nowhere, a
-- transcript in a panel).
local function place(shown: Shown, where: Placement?, sizes: Sizes?): greed.View
	local buffer = shown.buffer
	local before = buffer:views()
	local found: greed.View? = nil
	for _, old in before do
		if where == nil or shown_as(old, where) then
			found = old
			break
		end
	end
	-- A terminal goes in a pane, as it started.
	local fallback: Placement = if shown.terminal then "pane" else "panel"
	local view = found or open_in(buffer, shown.name, where or fallback, sizes or {})
	if found == nil then
		-- Closing a view leaves the session running; the project's last
		-- pane can't close, and goes on showing it.
		for _, old in before do
			old:close()
		end
	end
	view:focus()
	if shown.terminal then
		terminal.enter(view)
	else
		transcript.focus_prompt(view)
	end
	return view
end

-- Shows each of `several` as `where` says: several panes split the
-- biggest pane each time, and several tabs are one tab with a pane each.
local function place_all(several: { Shown }, where: Placement)
	local sizes: Sizes = {}
	for i, shown in several do
		place(shown, if where == "tab" and i > 1 then "pane" else where, sizes)
	end
end

--- Shows the transcript of `s` with the cursor in its prompt: as `where`
--- says, moving it there from where it showed, or without `where`, where
--- it shows already, or else in a panel on the right. Closing its view
--- leaves the session running.
function M.show(s: Session, where: Placement?)
	place(shown_of(s), where)
end

--- Shows the transcripts of `several` as `where` says, each moved there:
--- several panes split the biggest pane each time, and several tabs are
--- one tab with a pane each.
function M.show_all(several: { Session }, where: Placement)
	local all: { Shown } = {}
	for _, s in several do
		table.insert(all, shown_of(s))
	end
	place_all(all, where)
end

--- Every session, oldest first.
function M.sessions(): { Session }
	return table.clone(sessions)
end

--- The session whose transcript `buffer` is.
function M.of(buffer: greed.Buffer): Session?
	return by_buffer[buffer:id()]
end

--- Sends `text` to `s`, waiting for its turn to end. The transcript shows
--- `shown` in its place when given, like the question for instructions
--- built around it.
function M.prompt(s: Session, text: string, shown: string?): (boolean, string?)
	return session.prompt(s, text, nil, shown)
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

-- Takes `s` out of the sessions, its transcript going once nothing shows it.
local function drop(s: Session)
	local index = table.find(sessions, s)
	if index then
		table.remove(sessions, index)
	end
	core.attention.set(`agent-session:{s.id}`, nil)
	overlap.forget(s)
	last_status[s.id] = nil
	local buffer = buffers[s.id]
	buffers[s.id] = nil
	if buffer then
		by_buffer[buffer:id()] = nil
		-- A terminal's closes with it.
		if buffer:valid() then
			buffer:set_kept(false)
		end
	end
end

-- The sessions kept for the project shown, as the list last read them.
local kept: { root: string, entries: { Saved } }? = nil

--- Stops `s` and, if it had a workspace, removes it.
function M.close(s: Session)
	saved.remember(s, true)
	session.stop(s)
	workspaces.remove(s)
	drop(s)
	kept = nil
	list.render()
	participants.draw(sessions)
end

-- The repository of each folder, as sessions are listed by it.
local repositories: { [string]: string } = {}
local function repository(root: string): string
	local key = repositories[root]
	if key == nil then
		key = vcs.repo.identity(root)
		repositories[root] = key
	end
	return key
end

-- The list's rows: the sessions of the repository of the project at
-- `root`, running and kept, that project's first, then the newest.
local function rows(root: string): { list.Row }
	local entries: { Saved }
	if kept and kept.root == root then
		entries = kept.entries
	else
		entries = saved.list(root, {})
		kept = { root = root, entries = entries }
	end
	local key = repository(root)
	local out: { list.Row } = {}
	local running: { [string]: boolean } = {}
	-- The terminals sessions run in, which show as those sessions.
	local of_sessions: { [terminal.Term]: boolean } = {}
	for _, s in sessions do
		if repository(s.root) == key then
			if s.session_id then
				running[s.session_id] = true
			end
			local term = terms[s.id]
			if term then
				of_sessions[term] = true
			end
			-- Claude Code in a terminal says how it's doing through its hooks.
			local status: string = if term
					and term.agent
					and s.status == "idle"
				then term.agent.state
				else s.status
			table.insert(out, {
				key = string.format("s%08d", s.id),
				session = s,
				agent = s.name,
				title = saved.title(s),
				-- A turn that failed shows as failed, with why, until the next.
				status = if s.failed and s.status == "idle" then "failed" else status,
				reason = if s.status == "idle" or s.status == "exited" then s.failed else nil,
				time = active[s.id] or os.time(),
				tokens = s.tokens,
				root = s.root,
				workspace = s.workspace and s.workspace.name,
			})
		end
	end
	-- Agents in other terminals, like the Claude Code pane or one you
	-- started yourself, in a folder of this repository.
	for _, term in terminal.agents() do
		local agent = term.agent
		local folder = term.terminal:cwd()
		local at = if folder then core.project.root(folder) else nil
		if agent and at and not of_sessions[term] and repository(at) == key then
			table.insert(out, {
				key = `t{term.buffer:id()}`,
				terminal = term,
				agent = agent.name,
				title = term.terminal:title() or term.command,
				status = agent.state :: string,
				time = agent.since,
				root = at,
			})
		end
	end
	for _, entry in entries do
		if not running[entry.session_id] then
			local agent = agents.named(entry.agent)
			table.insert(out, {
				key = `k{entry.session_id}`,
				saved = entry,
				agent = if agent
					then agent.title or agent.name
					elseif entry.agent == IN_TERMINAL then "Claude Code"
					else entry.agent,
				title = entry.title,
				status = "saved",
				time = entry.time,
				tokens = entry.tokens,
				root = entry.root,
				workspace = entry.workspace and entry.workspace.name,
			})
		end
	end
	table.sort(out, function(a: list.Row, b: list.Row)
		local here_a, here_b = a.root == root, b.root == root
		if here_a ~= here_b then
			return here_a
		elseif a.time ~= b.time then
			return a.time > b.time
		end
		return a.key > b.key
	end)
	return out
end
list.source(rows)

-- An agent in a terminal changed how it's doing: its row shows it.
core.objects.on_changed(function(id)
	if string.sub(id, 1, 9) == "terminal:" then
		list.render()
	end
end)

--- Opens the list of the sessions of the repository of the project at
--- `root`, running and kept to take up again, in any of its workspaces.
--- Without `root`, it's the project of the transcript or file you're in.
function M.list(root: string?)
	local s = by_buffer[greed.view():buffer():id()]
	kept = nil
	list.open(root or (s and s.root) or core.project.root())
end

-- The session of a row, taken up first when it's kept or it exited, in
-- place of the one that exited (in the views that show it); in `here` if
-- given, as `M.resume` does.
local function take_up(row: list.Row, here: string?): (Session?, string?)
	local s = row.session
	if s and s.status ~= "exited" then
		return s, nil
	end
	local entry: Saved? = row.saved
	if entry == nil and s and s.session_id then
		local exited: Saved = {
			agent = s.agent,
			root = s.root,
			workspace = s.workspace,
			session_id = s.session_id,
			title = row.title,
			time = row.time,
		}
		entry = exited
	end
	if entry == nil then
		-- It exited before it started: there's only its transcript to show.
		return s, nil
	end
	-- Out of the sessions first, so the one taken up has its name.
	local index = if s then table.find(sessions, s) else nil
	if s and index then
		table.remove(sessions, index)
	end
	local again, err = M.resume(entry, here)
	if again == nil then
		if s and index then
			table.insert(sessions, index, s)
		end
		return nil, err
	end
	local old = s and buffers[s.id]
	if s and old and old:valid() then
		local new = buffer_of(again)
		for _, view in old:views() do
			view:show(new)
		end
	end
	if s then
		drop(s)
	end
	kept = nil
	return again, nil
end

-- The session `ctx` is about: the transcript it's in, or the list's line.
-- A line of an agent in a terminal has none, and says what it takes.
local function current(ctx: greed.Context): Session?
	local s = by_buffer[ctx.buffer:id()]
	if s then
		return s
	end
	local row = list.at_cursor(ctx)
	if row and row.terminal then
		greed.echo(`{row.agent} runs in a terminal: enter and p t w s show it, x closes it`)
	end
	return row and row.session
end

-- What to show of the rows chosen in the list, or of the transcript `ctx`
-- is in: sessions' transcripts, taken up first where they need to be, and
-- the terminals agents run in.
local function chosen_shown(ctx: greed.Context): { Shown }
	local out: { Shown } = {}
	local s = by_buffer[ctx.buffer:id()]
	if s then
		return { shown_of(s) }
	end
	for _, row in list.chosen(ctx) do
		local term = row.terminal
		if term then
			table.insert(out, { buffer = term.buffer, name = row.agent, terminal = true })
			continue
		end
		local taken, err = take_up(row)
		if taken then
			table.insert(out, shown_of(taken))
		else
			greed.echo(`can't take up {row.agent}: {err}`)
		end
	end
	return out
end

-- Closes the list when `ctx` is in it, for a command that shows something
-- else.
local function leave_list(ctx: greed.Context)
	if list.is(ctx.buffer) then
		list.close()
	end
end

-- Commands -------------------------------------------------------------------

greed.command({
	name = "agent-new",
	doc = "Start an agent: Greed's own, or Claude Code, Gemini or Codex over ACP; pick which, and where it works",
	args = {
		{
			name = "agent",
			doc = "Which agent, by name (greed, claude, gemini, codex, opencode); picked when left out. Named, it works in the project",
			type = "string",
			optional = true,
		},
		{
			name = "prompt",
			doc = "A first message to send it",
			type = "rest",
			optional = true,
		},
	},
	run = function(ctx)
		leave_list(ctx)
		local chosen: Agent? = nil
		local name = ctx.values.agent
		if name then
			chosen = agents.named(name)
			if chosen == nil then
				greed.echo(`no agent called {name}`)
				return
			end
		else
			local items = {}
			for _, agent in agents.list do
				local command = agents.command_of(agent)
				local how = if agent.native
					then "in the editor, with the model in :models"
					elseif command then table.concat(command, " ")
					elseif agent.install then `not installed: {agent.install}`
					else "not installed"
				table.insert(
					items,
					{ label = agent.title or agent.name, detail = how, value = agent }
				)
			end
			local picked = picker.choose("Agent", items)
			if picked == nil then
				return
			end
			chosen = picked.value
		end
		local agent = chosen :: Agent
		if agents.command_of(agent) == nil then
			greed.echo(agents.missing(agent))
			return
		end
		-- One named outright works in the project, and outside a repository
		-- there's nowhere else; there's nothing to ask.
		local own = false
		if name == nil and vcs.repo.repo_of(core.project.root() .. "/.") then
			local place = picker.choose("Where it works", {
				{ label = "In a workspace of its own", value = "own" },
				{ label = "In the project, with you", value = "here" },
			})
			if place == nil then
				return
			end
			own = place.value == "own"
		end
		local s, err = M.start(agent, core.project.root(), own)
		if s == nil then
			greed.echo(err :: string)
			return
		end
		M.show(s)
		local prompt = ctx.values.prompt
		if prompt then
			greed.spawn(function()
				M.prompt(s, prompt)
			end)
		else
			-- Ready for the first message, so the first key types it.
			greed.mode.set(core.style.typing_mode())
		end
	end,
})

greed.command({
	name = "claude-workspace",
	doc = "Start Claude Code in a terminal, in a workspace of its own; it's in the session list, where its work is reviewed and brought in",
	args = {
		{ name = "prompt", doc = "What to ask it first", type = "rest", optional = true },
	},
	run = function(ctx)
		leave_list(ctx)
		local s, err = M.claude_in_workspace(core.project.root(), ctx.values.prompt)
		if s == nil then
			greed.echo(err :: string)
		end
	end,
})

greed.command({
	name = "agent",
	doc = "Show the latest agent session, or start one when none runs",
	run = function(ctx)
		local latest = sessions[#sessions]
		if latest then
			leave_list(ctx)
			M.show(latest)
		else
			greed.run("agent-new")
		end
	end,
})

-- Opens the list, or closes it from inside.
local function toggle_list(ctx: greed.Context)
	if list.is(ctx.buffer) then
		list.close()
	else
		M.list()
	end
end

greed.command({
	name = "agent-list",
	doc = "List the agent sessions, running and kept, to show, take up, move, review or close them",
	run = toggle_list,
})
-- The names the list had when it was two.
greed.command({ name = "agents", doc = "The same as agent-list", run = toggle_list })
greed.command({ name = "agent-resume", doc = "The same as agent-list", run = toggle_list })

-- Shows the sessions chosen in the list, or the transcript's, as `where`
-- says.
local function show_in(where: Placement?): (ctx: greed.Context) -> ()
	return function(ctx)
		local in_list = list.is(ctx.buffer)
		local several = chosen_shown(ctx)
		if #several == 0 then
			if not in_list then
				greed.echo("no session here; space i l lists them")
			end
			return
		end
		leave_list(ctx)
		if where == nil and #several == 1 then
			place(several[1], nil)
		else
			place_all(several, where or "pane")
		end
	end
end

greed.command({
	name = "agents-show",
	doc = "Show the sessions marked in the list, or the one under the cursor, taking them up if they're kept",
	run = show_in(nil),
})
greed.command({
	name = "agent-show-panel",
	doc = "Show the session (the transcript's, or those chosen in the list) in a panel on the right",
	run = show_in("panel"),
})
greed.command({
	name = "agent-show-pane",
	doc = "Show the session (the transcript's, or those chosen in the list) in a pane of the tab",
	run = show_in("pane"),
})
greed.command({
	name = "agent-show-tab",
	doc = "Show the session (the transcript's, or those chosen in the list) in a tab of its own",
	run = show_in("tab"),
})
greed.command({
	name = "agent-show-float",
	doc = "Show the session (the transcript's, or those chosen in the list) in a floating view",
	run = show_in("float"),
})

local MOVES: { [string]: string } = {
	p = "agent-show-pane",
	t = "agent-show-tab",
	w = "agent-show-float",
	s = "agent-show-panel",
}

greed.command({
	name = "agent-move",
	doc = "Move the session's transcript to a pane, a tab, a float or a panel: the next key says which",
	run = function(ctx)
		if current(ctx) == nil and not list.is(ctx.buffer) then
			greed.echo("no session here; space i l lists them")
			return
		end
		greed.echo("move to: p pane · t tab · w float · s side panel")
		local command = MOVES[greed.next_key()]
		greed.echo("")
		if command then
			greed.run(command)
		end
	end,
})

-- Takes up the sessions chosen in the list that aren't running, in `here`
-- if given, saying what failed.
local function resume_chosen(ctx: greed.Context, here: string?)
	local taken = 0
	for _, row in list.chosen(ctx) do
		if row.terminal or (row.session and row.session.status ~= "exited") then
			continue
		end
		local s, err = take_up(row, here)
		if s then
			taken += 1
		else
			greed.echo(`can't take up {row.agent}{if here then " here" else ""}: {err}`)
		end
	end
	if taken > 0 then
		greed.echo(`took up {taken} session{if taken == 1 then "" else "s"}`)
	end
	list.render()
end

greed.command({
	name = "agents-resume",
	doc = "Take up the sessions marked in the list, or the one under the cursor, without showing them",
	run = function(ctx)
		resume_chosen(ctx)
	end,
})

greed.command({
	name = "agents-resume-here",
	doc = "Take up Greed's own sessions marked in the list, or the one under the cursor, in this workspace",
	run = function(ctx)
		resume_chosen(ctx, list.root())
	end,
})

greed.command({
	name = "agents-mark",
	doc = "Mark the session under the cursor in the list, or unmark it, to act on several",
	run = list.mark,
})

greed.command({
	name = "agents-filter",
	doc = "Narrow the list to the sessions with the text typed",
	run = list.filter,
})

-- An image pasted in a transcript goes with your next message.
core.images.taker("agent-transcript", function(png, ctx)
	local s = by_buffer[ctx.buffer:id()]
	if s == nil then
		return
	end
	local ok, err = session.attach(s, png)
	if ok then
		local count = #(s.attached or {})
		greed.echo(`image {count} goes with your next message; alt-x drops them`)
	else
		greed.echo(err or "couldn't attach the image")
	end
end)

greed.command({
	name = "agent-drop-images",
	doc = "Drop the images pasted for your next message to the agent",
	run = function(ctx)
		local s = by_buffer[ctx.buffer:id()]
		if s == nil or s.attached == nil then
			greed.echo("no images to drop")
			return
		end
		session.drop_images(s)
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
		local text = core.text.trim(transcript.prompt(ctx.buffer))
		if text == "" and s.attached == nil and s.queued == nil then
			greed.echo("write a message in the box first")
			return
		end
		-- One of Greed's chat commands runs here; any other /word goes on.
		local command, arg = slash.find(s, text)
		if command then
			transcript.clear_prompt(ctx.buffer)
			slash.run(command, arg)
			return
		end
		-- Sent while it asks something, it rejects that, saying what to do
		-- instead.
		if text ~= "" and question.reject(ctx.buffer, s, text) then
			transcript.clear_prompt(ctx.buffer)
			return
		end
		-- Sent while it works, it waits its turn.
		if s.status == "working" or s.status == "waiting" then
			if text ~= "" or s.attached then
				transcript.clear_prompt(ctx.buffer)
				session.queue(s, text)
			end
			return
		end
		-- A message it can't answer, like one to a model without a key,
		-- stays in the box.
		local problem = session.check(s)
		changed(s)
		if problem then
			greed.echo(problem)
			return
		end
		transcript.clear_prompt(ctx.buffer)
		local context = if greed.option.get("agent-editor-context") == true
			then agent_context.describe(s.root)
			else nil
		s.pinned = agent_context.pinned_text()
		local ok, err = session.prompt(s, text, context)
		if not ok then
			greed.echo(err :: string)
		end
	end,
})

greed.command({
	name = "agent-fold",
	doc = "Show all of the output of the tool call or the thought under the cursor, or fold it again",
	run = function(ctx)
		local s = by_buffer[ctx.buffer:id()]
		if s == nil then
			return
		end
		local cursor = ctx.buffer:line_of(ctx.view:cursor())
		local id = transcript.tool_at(ctx.buffer, cursor)
		local thought = id and transcript.thought_of(id)
		local folded: any = if thought then s.entries[thought] elseif id then s.tools[id] else nil
		if id == nil or folded == nil then
			return
		end
		folded.open = not folded.open
		transcript.render(ctx.buffer, s)
		-- Redrawing moved what followed the line; the cursor stays on it.
		local line = transcript.line_of_tool(ctx.buffer, id)
		if line then
			local pos = ctx.buffer:line_start(line)
			ctx.view:set_cursor(pos)
		end
	end,
})

local NO_SESSION = "no agent session here; use it in a transcript, or space i l lists them"

-- Asks for one of the `choices` of the chat command `name` in `s` in a
-- picker titled `title`, as tab after `/name ` lists them. Returns its
-- value, or nil when you picked none.
local function pick(s: Session, name: string, title: string): string?
	local command = slash.find(s, `/{name}`)
	local listing = command and command.choices
	local choices: { slash.Choice } = if listing then listing(s) else {}
	local items = {}
	for _, choice in choices do
		local about = if choice.doc then `: {choice.doc}` else ""
		local now = if choice.now then "  (now)" else ""
		table.insert(items, { label = `{choice.label}{about}{now}`, value = choice.value })
	end
	local chosen = picker.choose(title, items)
	return chosen and chosen.value
end

-- The mode or model among `list` that `named` names, by its id or name,
-- whatever the case; or says there's none.
local function named_in(list: { session.Mode }, named: string, what: string): session.Mode?
	local wanted = string.lower(named)
	for _, item in list do
		if string.lower(item.id) == wanted or string.lower(item.name) == wanted then
			return item
		end
	end
	local names = {}
	for _, item in list do
		table.insert(names, item.name)
	end
	greed.echo(`there's no {what} called {named}; there's {table.concat(names, ", ")}`)
	return nil
end

-- Switches `s` to the mode or model `id` with `set`, saying so if it can't.
local function switch(s: Session, set: (Session, string) -> (boolean, string?), id: string)
	local ok, err = set(s, id)
	if not ok then
		greed.echo(`can't: {err}`)
	end
end

greed.command({
	name = "agent-auto",
	doc = "Switch the agent between auto mode, where Greed answers its questions where it safely "
		.. "can, and asking you every time",
	run = function(ctx)
		local s = current(ctx)
		if s == nil then
			greed.echo(NO_SESSION)
			return
		end
		greed.echo(
			if auto.switch(s)
				then `{s.name}: auto, asking you only what Greed can't tell is safe; new sessions too`
				else `{s.name}: manual, asking you every time; new sessions too`
		)
		s.changed()
	end,
})

greed.command({
	name = "agent-mode",
	doc = "Pick the mode the agent works in, like plan or accept edits, or switch to the one named",
	args = { { name = "mode", doc = "its name or id; without one, pick it" } },
	run = function(ctx)
		local s = current(ctx)
		if s == nil then
			greed.echo(NO_SESSION)
			return
		elseif #s.modes == 0 then
			greed.echo(`{s.name} has no modes to pick from`)
			return
		end
		local named = ctx.args[1] or pick(s, "mode", "Mode")
		local mode = named and named_in(s.modes, named, "mode")
		if mode then
			switch(s, session.set_mode, mode.id)
		end
	end,
})

greed.command({
	name = "agent-model",
	doc = "Pick the model the agent uses, from those it offers, or switch to the one named; Greed's own agent can also use any model a provider lists",
	args = {
		{
			name = "model",
			doc = "its name or id (a role, for Greed's own agent); without one, pick it",
		},
	},
	run = function(ctx)
		local s = current(ctx)
		if s == nil then
			greed.echo(NO_SESSION)
			return
		end
		local own = native.drives(s)
		if #s.models == 0 and not own then
			greed.echo(`{s.name} has no models to pick from`)
			return
		end
		local named = ctx.args[1] or pick(s, "model", "Model")
		if named == nil then
			return
		elseif own and named == slash.ANOTHER_MODEL then
			local said = native.pick_model(s)
			if said then
				greed.echo(said)
			end
			return
		end
		local model = named_in(s.models, named, "model")
		if model then
			switch(s, session.set_model, model.id)
		end
	end,
})

greed.command({
	name = "agent-effort",
	doc = "How hard the model of Greed's own agent thinks in this session: none, low, medium, high or max; without one, pick it",
	args = { { name = "effort", doc = "none, low, medium, high or max, or unset for the role's" } },
	run = function(ctx)
		local s = current(ctx)
		if s == nil then
			greed.echo(NO_SESSION)
			return
		elseif not native.drives(s) then
			greed.echo(`{s.name} sets its own effort; only Greed's own agent's is set here`)
			return
		end
		local wanted = ctx.args[1] or pick(s, "effort", "Effort for this session")
		if wanted == nil then
			return
		end
		-- Another plugin's tables are read through, not as lists.
		local efforts: { string } = {}
		for _, known in models.EFFORTS do
			table.insert(efforts, known)
		end
		if wanted ~= "unset" and not table.find(efforts, wanted) then
			greed.echo(`{wanted} isn't an effort: {table.concat(efforts, ", ")} or unset`)
			return
		end
		s.effort = if wanted == "unset" then nil else wanted
		local set, sent = native.effort(s)
		local as = if sent and sent ~= set then ` (sent as {sent})` else ""
		greed.echo(`effort {set or "unset"}{as} for this session; :models e sets the role's`)
		changed(s)
	end,
})

greed.command({
	name = "agent-toggle-thoughts",
	doc = "Show or hide what agents think in their transcripts (the agent-thoughts option)",
	run = function()
		local shown = greed.option.get("agent-thoughts") ~= false
		greed.option.set("agent-thoughts", not shown)
		greed.echo(if shown then "thoughts hidden" else "thoughts shown, folded: tab unfolds one")
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
		leave_list(ctx)
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
	name = "agent-copy-or-stop",
	doc = "Copy the selection, or with nothing selected stop the agent's turn",
	run = function(ctx)
		if core.text.anything_selected(ctx.view:selection()) then
			greed.run("copy-or-line")
			return
		end
		greed.run("agent-stop")
	end,
})

-- The helper whose call's row the cursor is on in the transcript of `s`,
-- and whether it's on a helper's row at all: that helper's session may
-- not run any more.
local function helper_at(ctx: greed.Context, s: Session): (Session?, boolean)
	local id = transcript.tool_at(ctx.buffer, ctx.buffer:line_of(ctx.view:cursor()))
	local tool = if id then s.tools[id] else nil
	local wanted = if tool then tool.helper else nil
	if wanted == nil then
		return nil, false
	end
	for _, other in sessions do
		if other.session_id == wanted then
			return other, true
		end
	end
	return nil, true
end

-- The floats showing a transcript opened from a row of another, by view
-- id: the view it was opened from and the row's key, to go back to when
-- it closes.
local opened_from: { [number]: { view: greed.View, key: string } } = {}

greed.on("view.closed", function(event: greed.ViewClosed)
	opened_from[event.view] = nil
end)

-- Opens or folds the row the cursor is on in the transcript of `s`: a
-- helper's transcript in a float, a tool's output or a thought. Returns
-- whether the cursor was on such a row.
local function open_row(ctx: greed.Context, s: Session): boolean
	local helper, named = helper_at(ctx, s)
	if helper then
		local from = ctx.view
		local key = transcript.tool_at(ctx.buffer, ctx.buffer:line_of(from:cursor())) :: string
		local float = place(shown_of(helper), "float")
		if float ~= from then
			opened_from[float:id()] = { view = from, key = key }
		end
		return true
	elseif named then
		greed.echo("that helper's session isn't running any more; space i l lists the kept ones")
		return true
	end
	local row = transcript.row_at(ctx.buffer, ctx.buffer:line_of(ctx.view:cursor()))
	if row and (s.tools[row.key] or transcript.thought_of(row.key)) then
		greed.run("agent-fold")
		return true
	end
	return false
end

greed.command({
	name = "agent-answer",
	doc = "On a row of a transcript, open it: a helper's transcript in a float, a tool's output or a thought; on a button, like a code block's run, press it; else draw the question the agent waits on in the box again, to answer it there",
	run = function(ctx)
		local s = current(ctx)
		if s and by_buffer[ctx.buffer:id()] == s and open_row(ctx, s) then
			return
		end
		local buffer = s and buffers[s.id]
		if s == nil or buffer == nil or not question.waits(s) then
			if #core.buttons.at(ctx.buffer, ctx.view:cursor()) > 0 then
				greed.run("press-button")
			else
				greed.echo("no question waiting")
			end
			return
		end
		-- From the question's row, to the box, where enter answers.
		local row = transcript.row_at(ctx.buffer, ctx.buffer:line_of(ctx.view:cursor()))
		if row and string.find(row.key, "^question:") then
			if transcript.picked(ctx.buffer) then
				transcript.unpick(ctx.view, true)
			else
				transcript.focus_prompt(ctx.view)
			end
		end
		transcript.render(buffer, s)
	end,
})

greed.command({
	name = "agent-row-up",
	doc = "In a transcript, highlight the row above to open with enter or fold with tab: from the box, the newest",
	run = function(ctx)
		if by_buffer[ctx.buffer:id()] and not transcript.pick(ctx.view, -1) then
			greed.echo("no row here to open")
		end
	end,
})

greed.command({
	name = "agent-row-down",
	doc = "In a transcript, highlight the row below; from the newest, back to the box",
	run = function(ctx)
		if by_buffer[ctx.buffer:id()] then
			transcript.pick(ctx.view, 1)
		end
	end,
})

greed.command({
	name = "agent-row-drop",
	doc = "Drop the highlight from a transcript's row, back to the box",
	run = function(ctx)
		transcript.unpick(ctx.view, true)
	end,
})

greed.command({
	name = "agent-float-close",
	doc = "Close a transcript's float opened from a row of another, back to that row; elsewhere, what the key does otherwise",
	run = function(ctx)
		local from = opened_from[ctx.view:id()]
		if from == nil then
			core.keys.otherwise(ctx.keys or "", "agent-float-close")
			return
		end
		opened_from[ctx.view:id()] = nil
		ctx.view:close()
		local view = from.view
		if view:valid() then
			view:focus()
			local buffer = view:buffer()
			local line = transcript.line_of_tool(buffer, from.key)
			if line then
				view:set_cursor(buffer:line_start(line))
			end
		end
	end,
})

-- A click on a row opens or folds it, as enter does. A shell block's fence
-- isn't one: its buttons are.
core.mouse.claim("agent-transcript", function(event: greed.MouseEvent): boolean
	local view, pos = event.view, event.pos
	if
		view == nil
		or pos == nil
		or event.kind ~= "press"
		or event.button ~= "left"
		or event.shift
		or event.alt
		or event.ctrl
	then
		return false
	end
	local buffer = view:buffer()
	local row = transcript.row_at(buffer, buffer:line_of(pos))
	if row == nil or string.find(row.key, "^code:") then
		return false
	end
	view:focus()
	view:set_cursor(buffer:line_start(row.line))
	greed.run("agent-answer")
	return true
end)

-- The shell code block at the cursor in a transcript, or nil having said
-- there's none.
local function code_here(ctx: greed.Context): code.Code?
	local found = if by_buffer[ctx.buffer:id()]
		then transcript.code_at(ctx.buffer, ctx.view:cursor())
		else nil
	if found == nil then
		greed.echo("there's no shell code here")
	end
	return found
end

greed.command({
	name = "agent-code-run",
	doc = "Run the shell code block at the cursor in this project's shell, as a block there; one that destroys something asks first",
	run = function(ctx)
		local found = code_here(ctx)
		if found then
			code.run(found, by_buffer[ctx.buffer:id()].cwd)
		end
	end,
})

greed.command({
	name = "agent-code-prompt",
	doc = "Put the shell code block at the cursor at this project's shell's prompt, to look over before running it",
	run = function(ctx)
		local found = code_here(ctx)
		if found then
			code.to_prompt(found, ctx.view)
		end
	end,
})

greed.command({
	name = "agent-code-copy",
	doc = "Copy the shell code block at the cursor",
	run = function(ctx)
		local found = code_here(ctx)
		if found then
			code.copy(found)
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
		leave_list(ctx)
		greed.view():show(buffer)
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
	doc = "Close the sessions marked in the list, or the one under the cursor: stop and forget them and remove their workspaces, asking first for those running or with a workspace",
	run = function(ctx)
		local picked = list.chosen(ctx)
		local names: { string } = {}
		local running, workspace = false, false
		for _, row in picked do
			table.insert(names, row.agent)
			running = running
				or row.terminal ~= nil
				or (row.session ~= nil and row.status ~= "exited")
			workspace = workspace or row.workspace ~= nil
		end
		if #picked == 0 then
			return
		elseif running or workspace then
			local also = if workspace then " and remove their workspaces" else ""
			greed.echo(`close {table.concat(names, ", ")}{also}? y/n`)
			local yes = greed.next_key() == "y"
			greed.echo("")
			if not yes then
				return
			end
		end
		for _, row in picked do
			local s, entry, term = row.session, row.saved, row.terminal
			if term then
				-- Its program ends with it.
				terminal.close(term)
			elseif s then
				M.close(s)
			elseif entry then
				saved.forget(entry)
				workspaces.remove(entry)
			end
		end
		kept = nil
		list.render()
	end,
})

-- A file opened while an agent works in it shows where at once.
greed.on("buffer.opened", function()
	participants.draw(sessions)
end)

--- How many agents work and wait for you, in sessions and in terminals, as
--- the status line shows it; nil when none do.
function M.status(): string?
	return participants.status(sessions, terminal.agents())
end

statusline.add("right", "agents", function()
	local text = M.status()
	return if text then { text = text, style = "ui.statusline.message" } else nil
end, "position")

greed.keymap.bind({ role = "command", kind = "agent-transcript" }, {
	enter = "agent-answer",
	tab = "agent-fold",
	esc = "agent-float-close",
	q = "agent-float-close",
})
greed.keymap.bind({ kind = "agents" }, {
	enter = "agents-show",
	r = "agents-resume",
	h = "agents-resume-here",
	m = "agents-mark",
	["/"] = "agents-filter",
	p = "agent-show-pane",
	t = "agent-show-tab",
	w = "agent-show-float",
	s = "agent-show-panel",
	n = "agent-new",
	f = "agent-fork",
	x = "agents-close",
	d = "agents-diff",
	b = "agents-bring",
	R = "agents-review",
	["ctrl-c"] = "agent-stop",
	q = "agent-list",
	esc = "agent-list",
})
-- These work in every mode, while typing too.
greed.keymap.bind({ kind = "agent-transcript" }, {
	["alt-enter"] = "agent-send",
	["ctrl-c"] = "agent-stop",
	["alt-q"] = "agent-answer",
	["alt-m"] = "agent-mode",
	["alt-a"] = "agent-auto",
	["alt-M"] = "agent-model",
	["alt-v"] = "paste-image",
	["alt-x"] = "agent-drop-images",
	-- Over moving between panes, which alt-h/j/k/l still do here.
	["alt-up"] = "agent-row-up",
	["alt-down"] = "agent-row-down",
})
greed.keymap.bind({ role = "typing", kind = "agent-transcript" }, {
	tab = "agent-complete",
	up = "agent-history-back",
	down = "agent-history-forward",
})

-- Each transcript's walk back through what you sent, by buffer id, while
-- what's in its box is what the walk put there.
local recalls: { [number]: core.RecallWalk } = {}

-- What you sent `s`, newest first.
local function sent(s: Session): { string }
	local out: { string } = {}
	for i = #s.entries, 1, -1 do
		local e = s.entries[i]
		if e.kind == "user" and e.text and e.text ~= "" then
			table.insert(out, e.text)
		end
	end
	return out
end

-- Puts in the box the message you sent `step` (1 older, -1 newer) from the
-- one there, among those starting with what was typed. Away from the box,
-- or on a line of it other than the first (going back) or the last, the
-- arrow moves the cursor as usual.
local function recall(ctx: greed.Context, step: number)
	local buffer, view = ctx.buffer, ctx.view
	local s = by_buffer[buffer:id()]
	local start = transcript.prompt_start(buffer)
	local pos = view:cursor()
	local edge = if step > 0 then start and buffer:line_of(start) else buffer:line_count() - 1
	if s == nil or start == nil or pos < start or buffer:line_of(pos) ~= edge then
		greed.run(if step > 0 then "move-up" else "move-down")
		return
	end
	local typed = transcript.prompt(buffer)
	local walk = recalls[buffer:id()]
	if walk == nil or walk.shown ~= typed then
		walk = core.recall.walk(typed, sent(s))
		recalls[buffer:id()] = walk
	end
	local found = core.recall.step(walk, step)
	if found == nil then
		greed.echo(
			if typed == "" then "no earlier message" else `no earlier message starting {typed}`
		)
		return
	end
	transcript.set_prompt(buffer, found, view)
end

greed.command({
	name = "agent-history-back",
	doc = "In a transcript's box, put the message you sent before it there, one starting with "
		.. "what's typed; elsewhere move up",
	run = function(ctx)
		recall(ctx, 1)
	end,
})

greed.command({
	name = "agent-history-forward",
	doc = "In a transcript's box, put the message you sent after it there, or back to what was "
		.. "typed; elsewhere move down",
	run = function(ctx)
		recall(ctx, -1)
	end,
})

greed.command({
	name = "agent-complete",
	doc = "In a transcript's box, complete the slash command being typed; elsewhere, type a tab",
	run = function(ctx)
		greed.run(if slash.completing(ctx.view) then "completion-ask" else "insert-tab")
	end,
})

slash.complete(M.of)

-- Thoughts show or hide in every transcript as the option says.
greed.on("option.changed", function(event: greed.OptionChanged)
	if event.name == "agent-thoughts" then
		for _, s in sessions do
			changed(s)
		end
	end
end)

-- In the vscode style ctrl-c copies a selection.
greed.keymap.bind({ style = "vscode", role = "typing", kind = "agent-transcript" }, {
	["ctrl-c"] = "agent-copy-or-stop",
})
greed.keymap.bind({ layer = "leader" }, {
	["i n"] = "agent-new",
	["i l"] = "agent-list",
	["i m"] = "agent-move",
	["i W"] = "claude-workspace",
})

--- Shell code in transcripts and its buttons (code.luau).
M.code = code

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

-- Sessions as objects, for the inspector and agents: what each runs, how
-- it's doing, its transcript, and showing, stopping and closing it.
local function session_object(s: Session): core.Object
	return { kind = "agent-session", id = `agent-session:{s.id}`, label = s.name, value = s }
end

core.objects.kind({
	name = "agent-session",
	doc = "An agent session: the agent it runs, how it's doing and its transcript",
	list = function()
		local out = {}
		for _, s in sessions do
			table.insert(out, session_object(s))
		end
		return out
	end,
	get = function(key)
		for _, s in sessions do
			if tostring(s.id) == key then
				return session_object(s)
			end
		end
		return nil
	end,
	inspect = function(s: Session)
		local pending = session.pending(s)
		local newest = pending[#pending]
		return {
			name = s.name,
			agent = s.agent,
			status = s.status,
			doing = s.doing,
			question = if newest then newest.title else nil,
			folder = s.cwd,
			workspace = if s.workspace then s.workspace.path else nil,
			tool = s.tool,
			failed = s.failed,
			tokens = s.tokens,
			window = s.window,
			spent = s.spent,
		}
	end,
	relations = function(s: Session)
		local buffer = buffers[s.id]
		local transcript = if buffer then core.objects.get(`buffer:{buffer:id()}`) else nil
		return { transcript = if transcript then { transcript } else {} }
	end,
})

core.actions.action({
	kind = "agent-session",
	name = "show",
	doc = "Show its transcript",
	run = function(target)
		M.show(target.value)
	end,
})
core.actions.set_default("agent-session", "show")
-- Answering the question an agent waits on, as its options say (the kinds
-- ACP names them by), from wherever the session is shown: only you, never
-- another agent.
for _, answer in
	{
		{ name = "allow", kinds = { "allow_once" }, doc = "Allow what it asks, this once" },
		{
			name = "allow-always",
			kinds = { "allow_always" },
			doc = "Allow what it asks, and the like from now on",
		},
		{
			name = "reject",
			kinds = { "reject_once", "reject_always" },
			doc = "Reject what it asks",
		},
	}
do
	-- The option of the question `s` shows that answers so, if it waits.
	local function option(s: Session): (session.Permission?, string?)
		local pending = session.pending(s)
		local asked = pending[#pending]
		if asked then
			for _, kind in answer.kinds do
				local id = option_of(asked, kind)
				if id then
					return asked, id
				end
			end
		end
		return nil, nil
	end
	core.actions.action({
		kind = "agent-session",
		name = answer.name,
		doc = answer.doc,
		yours = true,
		offers = function(target)
			local _, id = option(target.value)
			return id ~= nil
		end,
		run = function(target)
			local asked, id = option(target.value)
			if asked and id then
				asked.answer:send(id)
			end
		end,
	})
end
core.actions.action({
	kind = "agent-session",
	name = "stop",
	doc = "Stop what its agent is doing, keeping the session",
	danger = true,
	run = function(target)
		M.stop(target.value)
	end,
})
core.actions.action({
	kind = "agent-session",
	name = "close",
	doc = "Stop it and close it, its workspace removed",
	danger = true,
	run = function(target)
		M.close(target.value)
	end,
})

return M
