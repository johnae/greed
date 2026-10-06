-- Agents in Greed over the Agent Client Protocol: Claude Code, Gemini,
-- Codex or any agent that speaks ACP, each in a transcript buffer you write
-- to and read from, working in the project or in a workspace of its own.
--
--   space i n   start an agent: pick which, and where it works
--   space i o   the agents: what each is doing, its changes, review or bring them in
--
-- In a transcript, alt-enter sends what's in the box at the bottom, ctrl-c
-- stops the agent's turn and enter on a question answers it.
--
-- Agents are registered by name with the commands that run them; the first
-- one installed is used. Add your own in init.luau:
--
--     require("@acp").register({ name = "mine", commands = { { "my-agent", "--acp" } } })

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")
local vcs = require("@vcs")
local session = require("@self/session")
local native = require("@self/native")
local transcript = require("@self/transcript")
local participants = require("@self/participants")
local review = require("@self/review")
local statusline = require("@statusline")
local agent_context = require("@agent").context

type Session = session.Session

local M = {}

--- An agent to start: `commands` are tried in order, the first installed
--- runs, and `model` is the model to have it use, when it offers models.
--- A `native` agent is Greed's own, run in the editor; its `model` is the
--- role of the model it uses (see the models plugin).
export type Agent = {
	name: string,
	title: string?,
	commands: { { string } },
	model: string?,
	native: boolean?,
}

local agents: { Agent } = {}

--- Adds an agent to pick from, or replaces the one of the same name. It
--- goes when the plugin (or config) that added it does.
function M.register(agent: Agent)
	greed.plugin.tie(core.registry.put(agents, agent, function(known: Agent)
		return known.name == agent.name
	end))
end

M.register({
	name = "claude",
	title = "Claude Code",
	commands = {
		{ "claude-agent-acp" },
		{ "claude-code-acp" },
		{ "npx", "-y", "@agentclientprotocol/claude-agent-acp" },
	},
})
M.register({
	name = "gemini",
	title = "Gemini CLI",
	commands = { { "gemini", "--experimental-acp" } },
})
M.register({ name = "codex", title = "Codex", commands = { { "codex-acp" } } })
M.register({ name = "greed", title = "Greed", commands = {}, native = true })

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

--- The command that runs `agent`: the first one installed. Greed's own
--- agent needs none.
local function command_of(agent: Agent): { string }?
	if agent.native then
		return {}
	end
	for _, command in agent.commands do
		if greed.which(command[1]) then
			return command
		end
	end
	return nil
end

-- Sessions, oldest first, and each transcript's session by buffer id.
local sessions: { Session } = {}
local by_buffer: { [number]: Session } = {}
-- The agent each session runs, by session id, for forking it.
local agent_of: { [number]: Agent } = {}
local buffers: { [number]: greed.Buffer } = {}

-- The overview buffers open, to redraw when a session changes.
local overviews: { [number]: { buffer: greed.Buffer, rows: { [number]: Session } } } = {}

local render_overviews: () -> ()
local keep: (s: Session) -> ()

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
		render_overviews()
		participants.draw(sessions)
		keep(s)
	end)
end

local function trim(text: string): string
	return string.match(text, "^%s*(.-)%s*$") or ""
end

-- Runs `args` in `cwd`; its output, or nil and why.
local function run(args: { string }, cwd: string): (string?, string?)
	local done, err = greed.process.run(args, { cwd = cwd })
	if done == nil or done.code ~= 0 then
		return nil, trim(if done then done.stderr else err or "")
	end
	return done.stdout, nil
end

-- The repository `root` is in: "jj", "git" or nil.
local function repo_kind(root: string): ("jj" | "git")?
	if greed.fs.stat(root .. "/.jj") then
		return "jj"
	elseif greed.fs.stat(root .. "/.git") then
		return "git"
	end
	return nil
end

-- A workspace of its own for an agent `agent` runs, outside the project:
-- from your working copy's parent, or from `from`'s working copy, edits
-- and all, for a fork.
local function make_workspace(
	root: string,
	agent: string,
	from: session.Workspace?
): (session.Workspace?, string?)
	local kind = repo_kind(root)
	if kind == nil then
		return nil, "the project isn't in a jj or git repository"
	end
	local base = greed.fs.dirs().cache or (root .. "/..")
	local project = string.match(root, "([^/]+)/*$") or "project"
	greed.process.run({ "mkdir", "-p", `{base}/workspaces` })
	-- Earlier sessions' workspaces may still be there to take up again.
	local n, name, path = 0, "", ""
	repeat
		n += 1
		name = `greed-{agent}-{n}`
		path = `{base}/workspaces/{project}-{name}`
	until not greed.fs.stat(path)
	if kind == "jj" then
		local args = { "jj", "workspace", "add", "--name", name, path }
		if from then
			-- Any jj command there takes in what the agent wrote since.
			run({ "jj", "status" }, from.path)
			table.insert(args, "-r")
			table.insert(args, `{from.name}@`)
		end
		local _, err = run(args, root)
		if err then
			return nil, err
		end
		return { kind = "jj", name = name, path = path }, nil
	end
	local start = if from then `greed/{from.name}` else "HEAD"
	local head = run({ "git", "rev-parse", "HEAD" }, root)
	local _, err = run({ "git", "worktree", "add", "-q", "-b", `greed/{name}`, path, start }, root)
	if err then
		return nil, err
	end
	local based = if from then from.base else head and string.match(head, "%x+")
	return { kind = "git", name = name, path = path, base = based }, nil
end

-- Sessions you can take up again, kept in the cache folder: which agent,
-- where it worked, its ACP session and what you asked it first.
export type Saved = {
	agent: string,
	root: string,
	workspace: session.Workspace?,
	session_id: string,
	title: string,
	time: number,
}

local function saved_file(): string?
	local cache = greed.fs.dirs().cache
	return if cache then `{cache}/agents.json` else nil
end

local function read_saved(file: string?): { any }
	local text = if file then greed.fs.read(file) else nil
	local all = if text then greed.json.decode(text) else nil
	return if type(all) == "table" then all else {}
end

--- The sessions you can take up again for the project at `root`, newest
--- first, leaving out the ones running now.
function M.saved(root: string): { Saved }
	local out: { Saved } = {}
	for _, entry in read_saved(saved_file()) do
		local running = false
		for _, s in sessions do
			running = running or (s.session_id == entry.session_id and s.status ~= "exited")
		end
		if entry.root == root and not running then
			table.insert(out, entry)
		end
	end
	table.sort(out, function(a: Saved, b: Saved)
		return a.time > b.time
	end)
	return out
end

-- Keeps `s` to take up again, or with `forget`, stops keeping it.
local function remember(s: Session, forget: boolean?)
	local file = saved_file()
	if file == nil or s.session_id == nil then
		return
	end
	local kept: { any } = {}
	for _, entry in read_saved(file) do
		if entry.session_id ~= s.session_id then
			table.insert(kept, entry)
		end
	end
	if not forget then
		local title = "(nothing asked yet)"
		for _, entry in s.entries do
			if entry.kind == "user" and entry.text then
				title = string.match(entry.text, "^%s*([^\n]*)") or title
				break
			end
		end
		table.insert(kept, {
			agent = s.agent,
			root = s.root,
			workspace = s.workspace,
			session_id = s.session_id,
			title = title,
			time = os.time(),
		})
	end
	greed.fs.write(file, greed.json.encode(greed.json.array(kept)))
end

-- What each session was last kept as, so it's written only when that changes.
local kept_as: { [number]: string } = {}

function keep(s: Session)
	local first = ""
	for _, entry in s.entries do
		if entry.kind == "user" then
			first = entry.text or ""
			break
		end
	end
	local key = `{s.session_id}\0{first}`
	if s.session_id and kept_as[s.id] ~= key then
		kept_as[s.id] = key
		remember(s)
	end
end

-- Starts a session of `agent` in `workspace` (or the project at `root`),
-- with `extra` saying what to take up or fork.
local function launch(
	agent: Agent,
	root: string,
	workspace: session.Workspace?,
	extra: { load: string?, fork: string?, entries: { session.Entry }? }?
): (Session?, string?)
	local command = command_of(agent)
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
		if workspace or extra then
			return nil,
				`{name} works in the project itself; it can't have a workspace, be taken up or forked yet`
		end
		s = native.start({
			name = name,
			agent = agent.name,
			root = root,
			role = agent.model,
			decide = decides,
			changed = changes,
		})
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
	render_overviews()
	local model = if agent.native then nil else agent.model
	if model then
		-- The model asked for, once the agent says which it has.
		greed.spawn(function()
			while s.status == "starting" do
				greed.sleep(50)
			end
			if s.status ~= "exited" and s.model ~= model then
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
		local made, err = make_workspace(root, agent.name)
		if made == nil then
			return nil, err
		end
		workspace = made
	end
	return launch(agent, root, workspace)
end

--- Takes up a session kept from before: the agent tells the conversation
--- again, into a new transcript.
function M.resume(entry: Saved): (Session?, string?)
	local agent = nil
	for _, known in agents do
		if known.name == entry.agent then
			agent = known
		end
	end
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
		local made, err = make_workspace(s.root, agent.name, s.workspace)
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

local IN_PROJECT = "it works in the project itself; its changes are already there"

-- What `s` changed in its workspace, as a diff.
local function changes(s: Session): (string?, string?)
	local ws = s.workspace
	if ws == nil then
		return nil, IN_PROJECT
	elseif ws.kind == "jj" then
		-- Run in the workspace, so jj sees what the agent wrote since.
		return run({ "jj", "diff", "--git", "--color", "never" }, ws.path)
	end
	-- Untracked files count too.
	run({ "git", "add", "-A", "-N" }, ws.path)
	return run({ "git", "diff", ws.base or "HEAD" }, ws.path)
end

--- Brings what `s` changed in its workspace into yours: with jj its change
--- is squashed into your working copy, with git its diff is applied.
function M.bring(s: Session): (boolean, string?)
	local ws = s.workspace
	if ws == nil then
		return false, IN_PROJECT
	elseif ws.kind == "jj" then
		-- Any jj command in the workspace takes in what the agent wrote.
		run({ "jj", "status" }, ws.path)
		local _, err = run({ "jj", "squash", "--from", `{ws.name}@`, "--into", "@" }, s.root)
		if err then
			return false, err
		end
		-- Its change is empty now; its files follow.
		run({ "jj", "workspace", "update-stale" }, ws.path)
		return true, nil
	end
	local patch, err = changes(s)
	if patch == nil then
		return false, err
	elseif patch == "" then
		return false, "nothing changed"
	end
	local done = greed.process.run(
		{ "git", "apply", "--3way", "-" },
		{ cwd = s.root, stdin = patch }
	)
	if done == nil or done.code ~= 0 then
		return false, done and trim(done.stderr)
	end
	return true, nil
end

--- Stops the agent of `s`, keeping its transcript, its workspace and the
--- session to take up again.
function M.stop(s: Session)
	session.stop(s)
	changed(s)
end

--- Stops `s` and, if it had a workspace, removes it.
function M.close(s: Session)
	remember(s, true)
	session.stop(s)
	local ws = s.workspace
	if ws then
		if ws.kind == "jj" then
			run({ "jj", "workspace", "forget", ws.name }, s.root)
			greed.process.run({ "rm", "-rf", ws.path })
		else
			run({ "git", "worktree", "remove", "--force", ws.path }, s.root)
			run({ "git", "branch", "-D", `greed/{ws.name}` }, s.root)
		end
	end
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
	render_overviews()
	participants.draw(sessions)
end

-- The overview ---------------------------------------------------------------

local STATUS: { [string]: string } = {
	starting = "starting",
	idle = "ready",
	working = "working",
	waiting = "waiting for you",
	exited = "exited",
}

local function overview_lines(): ({ string }, { greed.Mark }, { [number]: Session })
	local lines = {
		"Agents    enter opens · n new · d diff · r review · b bring in · s stop · x close",
		"",
	}
	local marks: { greed.Mark } = {
		{ from = 0, to = 6, style = "markup.heading" },
		{ from = 6, to = #lines[1], style = "comment" },
	}
	local rows: { [number]: Session } = {}
	local at = #lines[1] + 2
	if #sessions == 0 then
		table.insert(lines, "No agents yet: n starts one.")
	end
	for _, s in sessions do
		local status = STATUS[s.status]
		local waiting = #session.pending(s)
		local parts = { `{s.name}  {status}` }
		if s.tool then
			table.insert(parts, `▸ {s.tool}`)
		end
		if waiting > 0 then
			table.insert(parts, `{waiting} question{if waiting == 1 then "" else "s"}`)
		end
		table.insert(
			parts,
			if s.workspace then `workspace {s.workspace.name}` else "in the project"
		)
		local line = table.concat(parts, "   ")
		local style = if s.status == "waiting"
			then "diagnostic.warning"
			elseif s.status == "working" then "diff.plus"
			elseif s.status == "exited" then "comment"
			else nil
		if style then
			table.insert(
				marks,
				{ from = at + #s.name + 2, to = at + #s.name + 2 + #status, style = style }
			)
		end
		table.insert(marks, { from = at, to = at + #s.name, style = "keyword" })
		rows[#lines] = s
		table.insert(lines, line)
		at += #line + 1
	end
	return lines, marks, rows
end

function render_overviews()
	for id, overview in overviews do
		local ok = pcall(function()
			local lines, marks, rows = overview_lines()
			local buffer = overview.buffer
			buffer:set_readonly(false)
			buffer:edit(function(e)
				e:replace(0, buffer:len(), table.concat(lines, "\n"))
			end)
			buffer:set_readonly(true)
			buffer:decorate("agents", marks)
			overview.rows = rows
		end)
		if not ok then
			overviews[id] = nil
		end
	end
end

--- Shows the agents overview in `view`.
function M.overview(view: greed.View)
	local buffer = greed.create_buffer("agents", "", { readonly = true })
	buffer:set_line_numbers(false)
	overviews[buffer:id()] = { buffer = buffer, rows = {} }
	render_overviews()
	view:show(buffer)
	local pos = buffer:line_start(math.min(2, buffer:line_count() - 1))
	view:set_selection({ ranges = { { anchor = pos, head = pos } }, primary = 1 })
end

-- The session on the overview line under the cursor.
local function overview_session(ctx: greed.Context): Session?
	local overview = overviews[ctx.buffer:id()]
	if overview == nil then
		return nil
	end
	return overview.rows[ctx.buffer:line_of(ctx.view:selection().ranges[1].head)]
end

-- The session `ctx` is about: the transcript it's in, or the overview line.
local function current(ctx: greed.Context): Session?
	return by_buffer[ctx.buffer:id()] or overview_session(ctx)
end

-- Commands -------------------------------------------------------------------

greed.command({
	name = "agent-new",
	doc = "Start an agent over ACP: pick which, and whether it works in a workspace of its own",
	run = function(ctx)
		local items = {}
		for _, agent in agents do
			local command = command_of(agent)
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
		local cursor = ctx.buffer:line_of(ctx.view:selection().ranges[1].head)
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
			ctx.view:set_selection({ ranges = { { anchor = pos, head = pos } }, primary = 1 })
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
	name = "agent-stop",
	doc = "Stop the agent's turn",
	run = function(ctx)
		local s = current(ctx)
		if s then
			session.cancel(s)
		end
	end,
})

-- The keys for each kind of answer, in the order they're offered.
local ANSWER_KEYS = { allow_once = "y", allow_always = "a", reject_once = "n", reject_always = "N" }

greed.command({
	name = "agent-answer",
	doc = "Answer the question the agent waits on",
	run = function(ctx)
		local s = current(ctx)
		local permission = s and session.pending(s)[1]
		if permission == nil then
			greed.echo("no question waiting")
			return
		end
		local items: { core.TransientItem } = {}
		local used: { [string]: boolean } = {}
		for i, option in permission.options do
			local key = ANSWER_KEYS[option.kind] or tostring(i)
			if used[key] then
				key = tostring(i)
			end
			used[key] = true
			table.insert(items, {
				key = key,
				doc = option.name,
				run = function()
					permission.answer.send(option.id)
				end,
			})
		end
		core.transient.show({
			title = `Allow {permission.title}?`,
			groups = { { title = "Answer", items = items } },
		})
	end,
})

greed.command({
	name = "agents-open",
	doc = "Open the transcript of the agent under the cursor",
	run = function(ctx)
		local s = overview_session(ctx)
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
		local text, err = changes(s)
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
		local s = overview_session(ctx)
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

greed.on("buffer.closed", function(event: greed.BufferClosed)
	overviews[event.id] = nil
end)

for _, mode in { "normal", "vim" } do
	greed.keymap.bind({ mode = mode, kind = "agent-transcript" }, {
		enter = "agent-answer",
		["ctrl-c"] = "agent-stop",
		tab = "agent-fold",
	})
	greed.keymap.bind({ mode = mode, kind = "agents" }, {
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
end
for _, mode in { "normal", "vim", "insert", "vim-insert", "edit" } do
	greed.keymap.bind({ mode = mode, kind = "agent-transcript" }, {
		["alt-enter"] = "agent-send",
		["alt-p"] = "agent-answer",
		["alt-m"] = "agent-mode",
		["alt-M"] = "agent-model",
	})
end
greed.keymap.bind("normal", {
	["space i n"] = "agent-new",
	["space i o"] = "agents",
	["space i r"] = "agent-resume",
})

-- The agent called `name`, or the first installed one, if it's installed.
local function installed(name: string?): Agent?
	for _, known in agents do
		if (name == nil or known.name == name) and command_of(known) then
			return known
		end
	end
	return nil
end

-- What Greed's agent is asked to do with your notes. Changes to notes that
-- are there go through proposals (notes_write proposes them too), so each
-- one waits for you; adding a line or a todo asks, as edits do.
local CONNECT = [=[
Go through %s and connect it with the rest of my notes. For each thought, idea or todo:
find related notes (notes_search, notes_list, notes_read), link them with [[name]], and add a
line of context where it helps: what it relates to, why it matters, what could come next.
Where several items belong together, say so, and suggest a note gathering them.

Change notes that already exist only with the propose tool, using the path notes_read gives,
so I can review each change; make new notes with notes_write. Don't delete anything. End with
a short summary of what you connected and what you'd suggest next.]=]

greed.command({
	name = "notes-connect",
	doc = "Have Greed's agent go through the inbox (or the note you're in), link it to your other notes and add context, as changes you review",
	run = function(ctx)
		local agent = installed("greed")
		if agent == nil then
			greed.echo("Greed's agent isn't registered")
			return
		end
		local path = ctx.buffer:path()
		local what = if path and string.match(path, "%.md$")
			then `the note I have open, {path}`
			else "my inbox note (the project's when it keeps notes)"
		local s, err = M.start(agent, core.project.root())
		if s == nil then
			greed.echo(`can't start Greed's agent: {err}`)
			return
		end
		native.switch_on(s, "notes")
		M.show(s)
		M.prompt(s, string.format(CONNECT, what))
	end,
})

greed.keymap.bind("normal", { ["space n l"] = "notes-connect" })

--- Agents handing tasks to other agents (subagent.luau).
M.subagent = require("@self/subagent")
--- An agent's workspace changes as proposals on your files (review.luau).
M.review = review
M.subagent.offer(M, installed)

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
