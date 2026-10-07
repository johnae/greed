-- Agents in Greed over the Agent Client Protocol: Claude Code, Gemini,
-- Codex or any agent that speaks ACP, each in a transcript buffer you write
-- to and read from, working in the project or in a workspace of its own.
--
--   space i n   start an agent: pick which, and where it works
--   space i l   the sessions, running and kept: show, take up, review or bring them in
--   space i m   move this session's transcript to a pane, tab, float or panel
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
local list = require("@self/list")
local panes = require("@panes")
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
	doc = "How many sessions with Greed's own agent are kept per repository to take up again; older ones are deleted",
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
-- When each session last did something, in seconds since 1970.
local active: { [number]: number } = {}

-- Redraws everything that shows `s`, soon: changes come in bursts while an
-- agent streams.
local queued: { [number]: boolean } = {}
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
		if buffer and buffer:valid() then
			pcall(transcript.render, buffer, s)
			-- Its float, if it has one, says it's waiting for you.
			core.floats.attention(buffer, s.status == "waiting")
		end
		list.render()
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
	-- The agent's name, numbered from 2 while sessions have it.
	local named = agent.title or agent.name
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

--- The sessions you can take up again for the repository of `root`, in any
--- of its workspaces, newest first, leaving out the ones running now.
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

--- Where a transcript shows: a panel on the right, a pane of the tab, a
--- tab of its own or a floating view.
export type Placement = "panel" | "pane" | "tab" | "float"

-- The transcript of `s`, made again if it was closed (with :bc, say).
local function buffer_of(s: Session): greed.Buffer
	local buffer = buffers[s.id]
	if buffer and buffer:valid() then
		return buffer
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

local function open_in(buffer: greed.Buffer, s: Session, where: Placement, sizes: Sizes): greed.View
	if where == "panel" then
		return greed.panel(buffer, { side = "right", width = "45%", title = s.name })
	elseif where == "float" then
		return panes.floats.show(buffer, { title = s.name })
	elseif where == "tab" then
		greed.tab.rename(greed.tab.new(buffer), s.name)
		return greed.tab.current().active
	end
	return split(buffer, sizes)
end

-- Shows the transcript of `s` as `where` says, moving it there from
-- wherever else it shows, or where it shows already (a panel if nowhere).
local function place(s: Session, where: Placement?, sizes: Sizes?): greed.View
	local buffer = buffer_of(s)
	local before = buffer:views()
	local found: greed.View? = nil
	for _, old in before do
		if where == nil or shown_as(old, where) then
			found = old
			break
		end
	end
	local view = found or open_in(buffer, s, where or "panel", sizes or {})
	if found == nil then
		-- Closing a view leaves the session running; the project's last
		-- pane can't close, and goes on showing it.
		for _, old in before do
			old:close()
		end
	end
	view:focus()
	transcript.focus_prompt(view)
	return view
end

--- Shows the transcript of `s` with the cursor in its prompt: as `where`
--- says, moving it there from where it showed, or without `where`, where
--- it shows already, or else in a panel on the right. Closing its view
--- leaves the session running.
function M.show(s: Session, where: Placement?)
	place(s, where)
end

--- Shows the transcripts of `several` as `where` says, each moved there:
--- several panes split the biggest pane each time, and several tabs are
--- one tab with a pane each.
function M.show_all(several: { Session }, where: Placement)
	local sizes: Sizes = {}
	for i, s in several do
		place(s, if where == "tab" and i > 1 then "pane" else where, sizes)
	end
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

-- Takes `s` out of the sessions, its transcript going once nothing shows it.
local function drop(s: Session)
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
	for _, s in sessions do
		if repository(s.root) == key then
			if s.session_id then
				running[s.session_id] = true
			end
			table.insert(out, {
				key = string.format("s%08d", s.id),
				session = s,
				agent = s.name,
				title = saved.title(s),
				status = s.status :: string,
				time = active[s.id] or os.time(),
				tokens = s.tokens,
				root = s.root,
				workspace = s.workspace and s.workspace.name,
			})
		end
	end
	for _, entry in entries do
		if not running[entry.session_id] then
			local agent = agents.named(entry.agent)
			table.insert(out, {
				key = `k{entry.session_id}`,
				saved = entry,
				agent = if agent then agent.title or agent.name else entry.agent,
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

--- Opens the list of the sessions of the repository of the project at
--- `root`, running and kept to take up again, in any of its workspaces.
--- Without `root`, it's the project of the transcript or file you're in.
function M.list(root: string?)
	local s = by_buffer[greed.view():buffer():id()]
	kept = nil
	list.open(root or (s and s.root) or core.project.root())
end

-- The session of a row, taken up first when it's kept or it exited, in
-- place of the one that exited (in the views that show it).
local function take_up(row: list.Row): (Session?, string?)
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
	local again, err = M.resume(entry)
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
local function current(ctx: greed.Context): Session?
	local row = list.at_cursor(ctx)
	return by_buffer[ctx.buffer:id()] or (row and row.session)
end

-- The sessions of the rows chosen in the list (marked, or under the
-- cursor), taken up first where they need to be, or the transcript's
-- session; each failure said.
local function chosen(ctx: greed.Context): { Session }
	local out: { Session } = {}
	local s = by_buffer[ctx.buffer:id()]
	if s then
		return { s }
	end
	for _, row in list.chosen(ctx) do
		local taken, err = take_up(row)
		if taken then
			table.insert(out, taken)
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
	doc = "Start an agent over ACP: pick which, and whether it works in a workspace of its own",
	run = function(ctx)
		leave_list(ctx)
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
		local several = chosen(ctx)
		if #several == 0 then
			if not in_list then
				greed.echo("no session here; space i l lists them")
			end
			return
		end
		leave_list(ctx)
		if where == nil and #several == 1 then
			M.show(several[1])
		else
			M.show_all(several, where or "pane")
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

greed.command({
	name = "agents-resume",
	doc = "Take up the sessions marked in the list, or the one under the cursor, without showing them",
	run = function(ctx)
		local taken = 0
		for _, row in list.chosen(ctx) do
			if row.session and row.session.status ~= "exited" then
				continue
			end
			local s, err = take_up(row)
			if s then
				taken += 1
			else
				greed.echo(`can't take up {row.agent}: {err}`)
			end
		end
		if taken > 0 then
			greed.echo(`took up {taken} session{if taken == 1 then "" else "s"}`)
		end
		list.render()
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
			running = running or (row.session ~= nil and row.status ~= "exited")
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
			local s, entry = row.session, row.saved
			if s then
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

--- How many agents work and wait for you, as the status line shows it;
--- nil when none do.
function M.status(): string?
	return participants.status(sessions)
end

statusline.add("right", "agents", function()
	local text = M.status()
	return if text then { text = text, style = "ui.statusline.message" } else nil
end, "position")

greed.keymap.bind({ mode = "helix", kind = "agent-transcript" }, {
	enter = "agent-answer",
	["ctrl-c"] = "agent-stop",
	tab = "agent-fold",
})
greed.keymap.bind({ kind = "agents" }, {
	enter = "agents-show",
	r = "agents-resume",
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
-- These work while typing too, in every style.
local function transcript_keys(mode: string)
	greed.keymap.bind({ mode = mode, kind = "agent-transcript" }, {
		["alt-enter"] = "agent-send",
		["alt-p"] = "agent-answer",
		["alt-m"] = "agent-mode",
		["alt-M"] = "agent-model",
	})
end
transcript_keys("helix")
core.style.each_typing(transcript_keys)
greed.keymap.bind({ layer = "leader" }, {
	["i n"] = "agent-new",
	["i l"] = "agent-list",
	["i m"] = "agent-move",
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
