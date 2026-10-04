-- Agents in Greed over the Agent Client Protocol: Claude Code, Gemini,
-- Codex or any agent that speaks ACP, each in a transcript buffer you write
-- to and read from, working in the project or in a workspace of its own.
--
--   space i n   start an agent: pick which, and where it works
--   space i o   the agents: what each is doing, its changes, bring them in
--
-- In a transcript, alt-enter sends what's below the prompt line, ctrl-c
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
local transcript = require("@self/transcript")

type Session = session.Session

local M = {}

export type Agent = { name: string, title: string?, commands: { { string } } }

local agents: { Agent } = {}

--- Adds an agent to pick from, or replaces the one of the same name.
function M.register(agent: Agent)
	for i, known in agents do
		if known.name == agent.name then
			agents[i] = agent
			return
		end
	end
	table.insert(agents, agent)
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

--- The command that runs `agent`: the first one installed.
local function command_of(agent: Agent): { string }?
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
local buffers: { [number]: greed.Buffer } = {}

-- The overview buffers open, to redraw when a session changes.
local overviews: { [number]: { buffer: greed.Buffer, rows: { [number]: Session } } } = {}

local render_overviews: () -> ()

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

-- A workspace of its own for an agent named `name`, outside the project.
local function make_workspace(root: string, name: string): (session.Workspace?, string?)
	local kind = repo_kind(root)
	if kind == nil then
		return nil, "the project isn't in a jj or git repository"
	end
	local base = greed.fs.dirs().cache or (root .. "/..")
	local project = string.match(root, "([^/]+)/*$") or "project"
	local path = `{base}/workspaces/{project}-{name}`
	greed.process.run({ "mkdir", "-p", `{base}/workspaces` })
	if kind == "jj" then
		local _, err = run({ "jj", "workspace", "add", "--name", name, path }, root)
		if err then
			return nil, err
		end
		return { kind = "jj", name = name, path = path }, nil
	end
	local head = run({ "git", "rev-parse", "HEAD" }, root)
	local _, err = run({ "git", "worktree", "add", "-q", "-b", `greed/{name}`, path }, root)
	if err then
		return nil, err
	end
	return { kind = "git", name = name, path = path, base = head and string.match(head, "%x+") },
		nil
end

--- Starts a session of `agent` for the project at `root`, in a workspace
--- of its own if `own` is set.
function M.start(agent: Agent, root: string, own: boolean?): (Session?, string?)
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
	local name = `{agent.name}-{count}`
	local workspace = nil
	if own then
		local made, err = make_workspace(root, `greed-{name}`)
		if made == nil then
			return nil, err
		end
		workspace = made
	end
	local s: Session
	s = session.start({
		name = (agent.title or agent.name) .. (if count > 1 then ` {count}` else ""),
		agent = agent.name,
		command = command,
		root = root,
		cwd = if workspace then workspace.path else root,
		workspace = workspace,
		servers = M.servers(greed.session.current(), greed.session.program()),
		changed = function()
			changed(s)
		end,
	})
	table.insert(sessions, s)
	local buffer = transcript.create(s)
	buffers[s.id] = buffer
	by_buffer[buffer:id()] = s
	render_overviews()
	return s, nil
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

--- Stops `s` and, if it had a workspace, removes it.
function M.close(s: Session)
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
	local lines =
		{ "Agents    enter opens · n new · d diff · b bring in · s stop · x close", "" }
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
			local how = if command then table.concat(command, " ") else "not installed"
			table.insert(items, { label = `{agent.title or agent.name}  ({how})`, value = agent })
		end
		local agent = picker.choose("Agent", items)
		if agent == nil then
			return
		end
		local place = picker.choose("Where it works", {
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
	doc = "Send what's below the transcript's prompt line to its agent",
	run = function(ctx)
		local s = by_buffer[ctx.buffer:id()]
		if s == nil then
			return
		end
		local text = trim(transcript.prompt(ctx.buffer))
		if text == "" then
			greed.echo("write a message below the prompt line first")
			return
		end
		if s.status == "working" or s.status == "waiting" then
			greed.echo("the agent is still working; ctrl-c stops it")
			return
		end
		transcript.clear_prompt(ctx.buffer)
		local ok, err = session.prompt(s, text)
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
		s = "agent-stop",
		x = "agents-close",
		q = "buffer-close",
	})
end
for _, mode in { "normal", "vim", "insert", "vim-insert", "edit" } do
	greed.keymap.bind({ mode = mode, kind = "agent-transcript" }, {
		["alt-enter"] = "agent-send",
		["alt-p"] = "agent-answer",
	})
end
greed.keymap.bind("normal", {
	["space i n"] = "agent-new",
	["space i o"] = "agents",
})

return M
