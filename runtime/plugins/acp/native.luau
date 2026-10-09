-- Greed's own agent: a loop in the editor with a model from the models
-- plugin, rather than a program speaking ACP. It talks to any provider
-- the models plugin knows (Anthropic, or anything with OpenAI's API, like
-- berget or a local Ollama), uses the tools Greed offers every agent plus
-- editing files and running commands, and asks before it edits or runs
-- anything, the same way ACP agents ask. Its session is like theirs, so
-- the transcript, the session list and subagents work the same. Each
-- session is written down as it goes, to take up again (saved.luau), and
-- compacted as it nears the model's limit (compact.luau).

local greed = require("@greed")
local core = require("@core")
local agent = require("@agent")
local models = require("@models")
local vcs = require("@vcs")
local session = require("./session")
local saved = require("./saved")
local compact = require("./compact")

type Session = session.Session

local M = {}

--- The role played by the model it uses, unless it's started with
--- another; without a model in that role it uses `reasoning`.
M.ROLE = "agent"
models.fallback(M.ROLE, "reasoning", "Greed's own agent")
models.fallback(compact.ROLE, M.ROLE, "compacting long conversations with Greed's agent")

-- Turns one prompt may take, so a model that keeps calling tools stops.
local MAX_TURNS = 100

-- Answers in a row that may be cut off at their length before it stops,
-- and what the model hears after one.
local MAX_CUTS = 2
local CUT_OFF = "Your answer was cut off: it was longer than one answer may be, so any tool "
	.. "call in it was lost and nothing ran. Go on in smaller pieces: write a long file with "
	.. "write_file holding its first part, then add the rest with edit_file, a part at a time."

-- How many times a request the provider turns down as too long is compacted
-- and tried again.
local MAX_OVERFLOWS = 3

-- What the model hears after a call it made already, which came back the same.
local REPEATED = "\n\n(You made this same call already and got the same result. "
	.. "Asking again won't change it: try something else.)"

-- Calls in a row that only read or search before the model hears it's been
-- a while: models can go on looking long after trying would have told them
-- more.
local READS = 40
local READING = `\n\n({READS} calls reading and searching in a row. If you're making something, `
	.. "try a first version now and let its checks and tests answer the rest; if something's "
	.. "in the way, tell the user what. If you're only answering a question, carry on.)"

-- The most of a tool's result the model gets back, in characters and lines;
-- the rest of a longer one is in a file it can read on in. Such files go
-- after `OUTPUT_DAYS`.
local MAX_RESULT = 30000
local MAX_LINES = 2000
local OUTPUT_DAYS = 7

-- Takes away results kept longer than OUTPUT_DAYS.
local function clear_old_output(dir: string)
	local before = os.time() - OUTPUT_DAYS * 86400
	local entries = greed.fs.list(dir)
	if entries == nil then
		return
	end
	for _, entry in entries do
		local path = `{dir}/{entry.name}`
		local info = greed.fs.stat(path)
		if info and info.modified and info.modified < before then
			greed.fs.remove(path)
		end
	end
end

--- `text`, a tool's result, as the model gets it: whole when it's short
--- enough, else its start and where the whole of it is kept (under `name`),
--- to read on with `read` or search with `grep`, so nothing is lost.
function M.fit(text: string, name: string): string
	local _, breaks = string.gsub(text, "\n", "")
	if #text <= MAX_RESULT and breaks < MAX_LINES then
		return text
	end
	local lines = string.split(text, "\n")
	local shown, size = {}, 0
	for _, line in lines do
		if #shown >= MAX_LINES or size + #line + 1 > MAX_RESULT then
			break
		end
		table.insert(shown, line)
		size += #line + 1
	end
	local head = table.concat(shown, "\n")
	local dir = agent.output_dir()
	-- Only yours to read, as the conversations kept are.
	if dir == nil or not greed.fs.write(`{dir}/{name}.txt`, text, { private = true }) then
		return `{head}\n\n[showing lines 1-{#shown} of {#lines}; the rest was left out]`
	end
	clear_old_output(dir)
	return `{head}\n\n[showing lines 1-{#shown} of {#lines}; the whole result is in {dir}/{name}.txt: `
		.. `read it from line {#shown + 1} on with read's from_line, or search it with grep and that path]`
end

-- The most of a project's instructions (AGENTS.md, CLAUDE.md) it reads.
local MAX_INSTRUCTIONS = 20000

local ALLOW = {
	{ id = "once", name = "Allow once", kind = "allow_once" },
	{ id = "always", name = "Allow always", kind = "allow_always" },
	{ id = "no", name = "Reject", kind = "reject_once" },
}

-- What each session keeps between prompts.
type State = {
	said: { models.Said },
	role: string,
	cancelled: boolean,
	--- Kinds of tool calls you allowed for the rest of the session. They
	--- aren't kept with it: a session taken up again asks again.
	allowed: { [string]: boolean },
	--- The tool groups it switched on.
	caller: agent.Caller,
	--- Where it works, for its prompt: worked out at its first prompt.
	env: string?,
	--- The tokens the provider last said the conversation takes, and how
	--- many messages of `said` that counted.
	reported: { tokens: number, at: number }?,
	--- The tools' names in the order it first had them, which stays.
	order: { string },
}

local states: { [number]: State } = {}

-- What a tool says after changing `buffer`, with what its language server
-- reports about it then.
local function changed(said: string, buffer: greed.Buffer?): string
	local found = if buffer then agent.problems_after({ buffer }) else nil
	return if found then `{said}\n{found}` else said
end

-- A tool of the agent's own: what the model is told, the kind of call it
-- is (for asking you), and what it does.
type Own = {
	spec: models.ToolSpec,
	kind: string,
	title: (args: any) -> string,
	run: (s: Session, args: any) -> string,
	--- What the call would let a plugin do that it couldn't (agent.widens).
	widens: ((s: Session, args: any) -> string?)?,
	--- The change it would make, as lines starting "- " (gone) and "+ "
	--- (new), shown on its row before you're asked.
	preview: ((s: Session, args: any) -> { string })?,
}

-- The most lines of a change shown before you're asked.
local PREVIEW_LINES = 200

-- `text`'s lines, each after `mark`, into `out`, up to PREVIEW_LINES in all.
local function marked(out: { string }, mark: string, text: string)
	for _, line in string.split(text, "\n") do
		if #out >= PREVIEW_LINES then
			return
		end
		table.insert(out, mark .. line)
	end
end

local object = agent.schema.object

-- What each session's agent last saw of each file, by session and full
-- path, as a hash of the file's whole text: from reading, editing or
-- writing it. write_file won't write over a file that changed since, or
-- that it never saw.
local seen_by: { [number]: { [string]: string } } = {}

local function seen(s: Session): { [string]: string }
	local files = seen_by[s.id]
	if files == nil then
		files = {}
		seen_by[s.id] = files
	end
	return files
end

local function saw(s: Session, path: string, text: string)
	seen(s)[core.project.resolve(path, s.cwd)] = greed.hash.sha256(text)
end

-- Whether `text` of `path` is other than what `s`'s agent last saw of it.
local function changed_since(s: Session, path: string, text: string): boolean
	local last = seen(s)[core.project.resolve(path, s.cwd)]
	return last ~= nil and last ~= greed.hash.sha256(text)
end

-- The 1-based line of byte `at` in `text`.
local function line_at(text: string, at: number): number
	local _, breaks = string.gsub(string.sub(text, 1, at - 1), "\n", "")
	return breaks + 1
end

-- Where `needle` is in `text`, as byte offsets, without overlaps.
local function places(text: string, needle: string): { number }
	local out = {}
	local from = 1
	while true do
		local at = string.find(text, needle, from, true)
		if at == nil then
			return out
		end
		table.insert(out, at)
		from = at + #needle
	end
end

-- `s` without the spaces around it.
local function trimmed(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or s
end

-- Why `old` isn't in `text` of `path`, with what's nearest, so the model
-- can put it right without reading the whole file again.
local function missing(path: string, text: string, old: string, stale: boolean): string
	local said = `old_text isn't in {path}`
	if stale then
		return said
			.. "; the file changed since you last read it (the user may be editing it), so read it again"
	end
	local wanted = {}
	for _, line in string.split(old, "\n") do
		if trimmed(line) ~= "" then
			table.insert(wanted, trimmed(line))
		end
	end
	if #wanted == 0 then
		return said
	end
	local lines = string.split(text, "\n")
	local starts = {}
	for n, line in lines do
		if trimmed(line) == wanted[1] then
			table.insert(starts, n)
		end
	end
	for _, n in starts do
		-- The same lines with other spacing or indentation.
		local i, w = n, 1
		while i <= #lines and w <= #wanted do
			if trimmed(lines[i]) == wanted[w] then
				w += 1
			elseif trimmed(lines[i]) ~= "" then
				break
			end
			i += 1
		end
		if w > #wanted then
			return `{said} as written, but it is on line {n} with other spacing or indentation: `
				.. "copy it exactly as read gives it"
		end
	end
	if #starts > 0 then
		local at = table.concat(starts, ", ", 1, math.min(#starts, 5))
		return `{said}: its first line is on line {at}, but what follows differs; read from there`
	end
	return `{said}, nor its first line: read the file again`
end

-- `text` with each place `old` is (just the first unless `all`) made `new`.
local function replaced(text: string, old: string, new: string, all: boolean): string
	local out = {}
	local from = 1
	for _, at in places(text, old) do
		table.insert(out, string.sub(text, from, at - 1))
		table.insert(out, new)
		from = at + #old
		if not all then
			break
		end
	end
	table.insert(out, string.sub(text, from))
	return table.concat(out)
end

type Change = { old_text: string, new_text: string, replace_all: boolean? }

-- The changes an edit_file call asks for: its `edits`, or the one it gives.
local function changes_of(args: any): { Change }
	if type(args.edits) == "table" and #args.edits > 0 then
		return args.edits
	end
	if type(args.old_text) ~= "string" or type(args.new_text) ~= "string" then
		error("give old_text and new_text, or edits", 0)
	end
	return {
		{ old_text = args.old_text, new_text = args.new_text, replace_all = args.replace_all },
	}
end

-- `text` of `path` with `changes` made in order; fails saying which and why
-- when one can't be, and then none is.
local function apply(path: string, text: string, changes: { Change }, stale: boolean): string
	for n, change in changes do
		local which = if #changes > 1 then `edit {n} of {#changes}: ` else ""
		local none = if #changes > 1 then " (none of the edits were made)" else ""
		if change.old_text == "" then
			error(`{which}old_text is empty{none}`, 0)
		end
		local at = places(text, change.old_text)
		if #at == 0 then
			error(which .. missing(path, text, change.old_text, stale) .. none, 0)
		elseif #at > 1 and not change.replace_all then
			local lines = {}
			for i = 1, math.min(#at, 10) do
				table.insert(lines, tostring(line_at(text, at[i])))
			end
			error(
				`{which}old_text is in {path} {#at} times, on lines {table.concat(lines, ", ")}: `
					.. `give more of it to pick one, or set replace_all{none}`,
				0
			)
		end
		text = replaced(text, change.old_text, change.new_text, change.replace_all == true)
	end
	return text
end

-- How many bytes `a` and `b` share at their start and, after that, at
-- their end, kept to whole characters.
local function shared(a: string, b: string): (number, number)
	local most = math.min(#a, #b)
	local head = 0
	-- A block at a time first: files are long and edits small.
	while
		head + 4096 <= most
		and string.sub(a, head + 1, head + 4096) == string.sub(b, head + 1, head + 4096)
	do
		head += 4096
	end
	while head < most and string.byte(a, head + 1) == string.byte(b, head + 1) do
		head += 1
	end
	-- Not in the middle of a character.
	while head > 0 and bit32.band(string.byte(a, head + 1) or 0, 0xC0) == 0x80 do
		head -= 1
	end
	local tail = 0
	local left = most - head
	while
		tail + 4096 <= left
		and string.sub(a, #a - tail - 4095, #a - tail)
			== string.sub(b, #b - tail - 4095, #b - tail)
	do
		tail += 4096
	end
	while tail < left and string.byte(a, #a - tail) == string.byte(b, #b - tail) do
		tail += 1
	end
	while tail > 0 and bit32.band(string.byte(a, #a - tail + 1) or 0, 0xC0) == 0x80 do
		tail -= 1
	end
	return head, tail
end

-- The most lines an edit's result shows of what it changed.
local SHOWN_LINES = 30

-- Lines `first` to `last` (1-based) of `text`, numbered as an editor shows
-- them, with two more on each side.
local function numbered(text: string, first: number, last: number): string
	local lines = string.split(text, "\n")
	-- A last newline ends the last line; nothing comes after it.
	if #lines > 1 and lines[#lines] == "" then
		table.remove(lines)
	end
	local from, to = math.max(first - 2, 1), math.min(last + 2, #lines)
	local out = {}
	for n = from, math.min(to, from + SHOWN_LINES - 1) do
		table.insert(out, string.format("%6d  %s", n, lines[n]))
	end
	if to > from + SHOWN_LINES - 1 then
		table.insert(out, `       (… to line {to})`)
	end
	return table.concat(out, "\n")
end

local OWN: { Own } = {
	{
		spec = {
			name = "edit_file",
			description = "Replace text in a file: `old_text` must appear in it exactly once (give enough "
				.. "lines around it to be sure), and becomes `new_text`; with replace_all, every place "
				.. "it is does. For several changes to one file, give them as `edits`: they're made in "
				.. "order, as one change, or none is. An open file is edited as the user has it, and "
				.. "saved. Returns the changed lines, numbered, and new problems the language server sees",
			input = object({
				path = { type = "string" },
				old_text = { type = "string" },
				new_text = { type = "string" },
				replace_all = {
					type = "boolean",
					description = "Change every place old_text is, not just one",
				},
				edits = {
					type = "array",
					description = "Several changes, in place of old_text and new_text",
					items = object({
						old_text = { type = "string" },
						new_text = { type = "string" },
						replace_all = { type = "boolean" },
					}, { "old_text", "new_text" }),
				},
			}, { "path" }),
		},
		kind = "edit",
		title = function(args)
			return `Edit {args.path}`
		end,
		preview = function(_, args)
			local out = {}
			local ok, changes = pcall(changes_of, args)
			if ok then
				for _, change in changes do
					marked(out, "- ", change.old_text)
					marked(out, "+ ", change.new_text)
				end
			end
			return out
		end,
		widens = function(s, args)
			local text = core.file.text(args.path, s.cwd)
			if text == nil then
				return nil
			end
			local ok, new = pcall(function()
				return apply(args.path, text, changes_of(args), false)
			end)
			return if ok then agent.widens(args.path, text, new) else nil
		end,
		run = function(s, args)
			local text = core.file.text(args.path, s.cwd)
			if text == nil then
				error(`there's no file {args.path}`, 0)
			end
			local new = apply(args.path, text, changes_of(args), changed_since(s, args.path, text))
			agent.memory.guard(args.path, s.cwd)
			-- Only the part that changed, through its buffer (opened if need
			-- be), so undo takes it back, cursors elsewhere stay put and its
			-- language server sees it.
			local head, tail = shared(text, new)
			local buffer = core.file.write(
				args.path,
				string.sub(new, head + 1, #new - tail),
				{ root = s.cwd, from = head, to = #text - tail, load = true }
			)
			saw(s, args.path, new)
			local first = line_at(new, head + 1)
			local last = math.max(line_at(new, #new - tail), first)
			return changed(`edited {args.path}:\n{numbered(new, first, last)}`, buffer)
		end,
	},
	{
		spec = {
			name = "write_file",
			description = "Write a file's whole text, making it (and its folders) if it's new",
			input = object(
				{ path = { type = "string" }, text = { type = "string" } },
				{ "path", "text" }
			),
		},
		kind = "edit",
		title = function(args)
			return `Write {args.path}`
		end,
		preview = function(s, args)
			local out = {}
			local old = core.file.text(args.path, s.cwd) or ""
			-- Only what changes, for a file that's there already.
			for _, hunk in greed.diff(old, args.text) do
				local gone = string.sub(old, hunk.from + 1, hunk.to)
				if gone ~= "" then
					marked(out, "- ", (string.gsub(gone, "\n$", "")))
				end
				if hunk.text ~= "" then
					marked(out, "+ ", (string.gsub(hunk.text, "\n$", "")))
				end
			end
			return out
		end,
		widens = function(s, args)
			return agent.widens(args.path, core.file.text(args.path, s.cwd), args.text)
		end,
		run = function(s, args)
			-- Writing over a file needs its agent to have seen it as it is
			-- now: the user may have changed it, and their change would go.
			local old = core.file.text(args.path, s.cwd)
			if old and old ~= args.text then
				if seen(s)[core.project.resolve(args.path, s.cwd)] == nil then
					error(
						`{args.path} is there already and you haven't read it: read it first, `
							.. "or change it with edit_file",
						0
					)
				elseif changed_since(s, args.path, old) then
					error(
						`{args.path} changed since you last read it (the user may be editing it): `
							.. "read it again, then change it with edit_file",
						0
					)
				end
			end
			agent.memory.guard(args.path, s.cwd)
			local buffer = core.file.write(args.path, args.text, { root = s.cwd, load = true })
			saw(s, args.path, args.text)
			return changed(`wrote {args.path}`, buffer)
		end,
	},
	{
		spec = {
			name = "run",
			description = "Run a shell command in the project's folder and get what it printed and how "
				.. "it exited: for tests, builds, version control. Don't use it to read or search files; "
				.. "read, grep and files see unsaved changes",
			input = object({ command = { type = "string" } }, { "command" }),
		},
		kind = "execute",
		title = function(args)
			return `Run {args.command}`
		end,
		run = function(s, args)
			local done, err = greed.process.run({ "sh", "-c", args.command }, { cwd = s.cwd })
			if done == nil then
				error(err or "it didn't start", 0)
			end
			local out = done.stdout .. (if done.stderr ~= "" then "\n" .. done.stderr else "")
			return `{out}\n(exit {done.code or "killed"})`
		end,
	},
}

-- The project's own instructions for agents, if it has them.
local function instructions(root: string): string?
	for _, name in { "AGENTS.md", "CLAUDE.md", ".github/copilot-instructions.md" } do
		local text = greed.fs.read(`{root}/{name}`)
		if text then
			return `{name}:\n\n{string.sub(text, 1, MAX_INSTRUCTIONS)}`
		end
	end
	return nil
end

-- What `command` (a shell command line) prints in `cwd`, trimmed, or nil
-- when it fails.
local function output(command: string, cwd: string): string?
	local done = greed.process.run({ "sh", "-c", command }, { cwd = cwd })
	if done == nil or done.code ~= 0 then
		return nil
	end
	local text = string.match(done.stdout, "^%s*(.-)%s*$")
	return if text and text ~= "" then text else nil
end

-- How many lines `args` print in `repo`, or "?" when they fail.
local function count(repo: vcs.Repo, args: { string }): string
	local text = vcs.repo.run(repo, args)
	return if text then tostring(select(2, string.gsub(text, "\n", ""))) else "?"
end

-- Where the agent works, as lines for its prompt: the system and shell,
-- and the project's version control. Worked out once a session.
local function environment(root: string): string
	local lines = {}
	local system_name = output("uname -sr", root)
	local shell_name = output('basename "${SHELL:-sh}"', root)
	if system_name then
		table.insert(lines, `The system is {system_name}; the shell is {shell_name or "sh"}.`)
	end
	local repo = vcs.repo.repo_of(root .. "/.")
	if repo and repo.kind == "jj" then
		local described = vcs.repo.trimmed(
			repo,
			{ "log", "-r", "@", "--no-graph", "-T", "description.first_line()" }
		)
		table.insert(
			lines,
			`The project is a jj repository (use jj, not git). The working copy's change `
				.. (if described then `is "{described}"` else "has no description yet")
				.. `, with {count(repo, { "diff", "--name-only" })} files changed when the session started.`
		)
	elseif repo then
		local branch = vcs.repo.trimmed(repo, { "rev-parse", "--abbrev-ref", "HEAD" })
		local changed = count(repo, { "status", "--porcelain" })
		table.insert(
			lines,
			`The project is a git repository on branch {branch or "?"}, with {changed} `
				.. "files changed when the session started."
		)
	end
	return table.concat(lines, " ")
end

-- What the model is told about where it is and how to work.
-- Where the user's config is and how settings change there, for asks like
-- "make tabs 2 spaces in Lua".
local function config_note(): string
	local config = greed.fs.dirs().config
	if config == nil then
		return "The user has no config folder, so settings can't be kept."
	end
	return `The user's Greed config is {config}/init.luau, Luau that runs as Greed starts and `
		.. 'again when saved. Settings go there: options with require("@greed").option.set '
		.. '(describe an option to see its name and values), a language\'s with require("@languages"), '
		.. 'the theme with require("@theme").use(name). Edit it with edit_file or write_file, '
		.. "keeping what's there; don't look for it anywhere else."
end

local function system(s: Session, env: string?): string
	local lines = {
		"You are Greed's coding agent, working in the Greed editor with the user. You can read and "
			.. "search the project, edit files and run commands with the tools you have.",
		`The project is at {s.root}; paths are relative to it.`
			.. (if env and env ~= "" then " " .. env else ""),
		"A user's message starts with a <time> tag, when they sent it, and may have an "
			.. "<editor-context> block: what they had on screen as they wrote it. That's left out "
			.. "when nothing changed since their last message.",
		"Find your way with focus (what the user is looking at), symbols, grep and files before "
			.. "reading whole files. Files are read as the user has them, unsaved changes included. "
			.. "Edit with edit_file, giving enough of the old text to match once.",
		"More tools come in groups you switch on with the tools tool when you need them: the "
			.. "repo map and the user's working set, renaming and the language server's fixes, "
			.. "history, notes, plugins and more.",
		"When the user asks for something new in Greed itself (a command, keys, a panel, an "
			.. "integration like a GitHub client), build it as a plugin with the plugins group: "
			.. "plugin_guide, then plugin_try until it passes, then plugin_install, which installs "
			.. "it in their own config after they review it. Don't write it into the project, even "
			.. "when the project is Greed's own code, unless they ask you to change the project.",
		config_note(),
		"Keep your plan for bigger tasks with plan_read and plan_write, where the user sees and "
			.. "changes it. Follow the decisions the decisions tool lists as accepted.",
		"Be brief: say what you did and what's left, not every step.",
		agent.memory.prompt(s.root),
	}
	local found = instructions(s.root)
	if found then
		table.insert(lines, "The project's instructions for agents follow.\n\n" .. found)
	end
	return table.concat(lines, "\n\n")
end

-- The tools the model is told about now (Greed's tools for agents in the
-- groups it has, and its own), and every tool it may call, by name, with
-- what to do for each.
local function tools(state: State): ({ models.ToolSpec }, { [string]: Own | agent.Tool })
	local offered: { [string]: models.ToolSpec } = {}
	local by_name: { [string]: Own | agent.Tool } = {}
	for _, tool in agent.offered(state.caller) do
		offered[tool.name] =
			{ name = tool.name, description = tool.description, input = tool.input }
	end
	for _, tool in agent.tools() do
		by_name[tool.name] = tool
	end
	for _, own in OWN do
		offered[own.spec.name] = own.spec
		by_name[own.spec.name] = own
	end
	-- In the order the session first had them: tools of a group switched on
	-- later come last, so the list before them, which providers cache, stays.
	local order = state.order
	local known: { [string]: boolean } = {}
	for _, name in order do
		known[name] = true
	end
	local fresh = {}
	for name in offered do
		if not known[name] then
			table.insert(fresh, name)
		end
	end
	table.sort(fresh)
	table.move(fresh, 1, #fresh, #order + 1, order)
	local specs: { models.ToolSpec } = {}
	for _, name in order do
		local spec = offered[name]
		if spec then
			table.insert(specs, spec)
		end
	end
	return specs, by_name
end

-- Whether you let `kind` of call happen, asking unless you allowed it for
-- the session (or a policy answers).
local function allowed(s: Session, state: State, title: string, kind: string): boolean
	if state.allowed[kind] then
		return true
	end
	local chosen = session.ask(s, title, kind, ALLOW)
	if chosen == "always" then
		state.allowed[kind] = true
	end
	return chosen == "once" or chosen == "always"
end

-- The arguments that best say what a call of one of Greed's tools is about,
-- in the order they're looked for.
local TELLING = { "path", "file", "query", "pattern", "name", "symbol", "group", "url", "command" }

-- A call of one of Greed's tools as its row in the transcript names it:
-- the tool and what it's about, like "read src/main.rs".
local function title_of(s: Session, c: models.Call): string
	for _, key in TELLING do
		local value = c.input[key]
		if type(value) == "string" and value ~= "" then
			if key == "path" or key == "file" then
				value = core.project.relative(value, s.root)
			end
			local line = string.match(value, "^[^\n]*") or value
			return `{c.name} {core.text.clip(line, 50)}`
		end
	end
	return c.name
end

-- Runs one call the model asked for and returns what it gets back, and
-- whether that's an error.
local function call(
	s: Session,
	state: State,
	by_name: { [string]: any },
	c: models.Call
): (string, boolean)
	local found = by_name[c.name]
	if found == nil then
		return `there's no tool called {c.name}`, true
	end
	local own = if found.spec then found :: Own else nil
	local registered = if own then nil else found :: agent.Tool
	local kind = if own then own.kind else (registered and registered.kind) or "read"
	local tool: session.Tool = {
		id = c.id,
		title = if own then own.title(c.input) else title_of(s, c),
		kind = kind,
		status = "pending",
		detail = {},
		output = {},
		open = false,
	}
	s.tools[c.id] = tool
	table.insert(s.entries, { kind = "tool", tool = tool })
	s.tool = tool.title
	if type(c.input.path) == "string" then
		s.where = { path = core.project.resolve(c.input.path, s.cwd) }
	end
	s.changed()
	-- Its own tools all change something; Greed's ask unless they only
	-- read or put what they do in front of you themselves.
	local asks = own ~= nil or (registered ~= nil and agent.asks(registered))
	-- What it would change, on its row before you're asked: tab shows it.
	local before = if own and own.preview then own.preview(s, c.input) else nil
	if before and #before > 0 then
		local removed, added = 0, 0
		for _, line in before do
			if string.sub(line, 1, 1) == "-" then
				removed += 1
			else
				added += 1
			end
		end
		tool.output = before
		tool.detail = { `-{removed} +{added} · tab shows the change` }
		s.changed()
	end
	-- One letting a plugin do more asks you, and only you, every time.
	local widens = if own and own.widens then own.widens(s, c.input) else nil
	local refused = nil
	if widens then
		local title = `{tool.title}, which {widens}`
		if session.ask(s, title, kind, session.ONCE, nil, true) ~= "once" then
			refused = session.NOT_WIDENED
		end
	elseif asks and not allowed(s, state, tool.title, kind) then
		refused = "the user didn't allow it"
	end
	if refused then
		tool.status = "failed"
		s.tool = nil
		return refused, true
	end
	tool.status = "in_progress"
	s.changed()
	local ok, result = pcall(function(): string
		if own then
			return own.run(s, c.input)
		end
		local tool = registered :: agent.Tool
		local wrong = agent.check(tool, c.input)
		if wrong then
			error(wrong, 0)
		end
		-- A path from where it works, as its own tools take them: Greed's
		-- shared ones go from the project shown, which may be another.
		local input = c.input
		local path = input.path
		if type(path) == "string" and not string.match(path, "^[/~]") then
			input = table.clone(input)
			input.path = core.project.resolve(path, s.cwd)
		end
		return agent.as_text(tool.run(input, state.caller))
	end)
	local text = if ok then result else agent.error_text(result)
	tool.status = if ok then "completed" else "failed"
	local lines = string.split(text, "\n")
	while #lines > 0 and lines[#lines] == "" do
		table.remove(lines)
	end
	-- A failure's first line says why; the rest is there unfolded.
	local summary = session.summary(if ok then lines else { lines[1] }, s.root)
	tool.detail = if summary then { summary } else {}
	tool.output = lines
	s.tool = nil
	return M.fit(text, `{s.id}-{c.id}`), not ok
end

-- Adds `text` to the agent's last words in the transcript, or starts them.
local function say(s: Session, text: string)
	local last = s.entries[#s.entries]
	if last and last.kind == "agent" then
		last.text = (last.text or "") .. text
	else
		table.insert(s.entries, { kind = "agent", text = text })
	end
	s.changed()
end

-- Writes `s` down to take up again, once it has been asked something.
local function keep(s: Session, state: State)
	if saved.first_asked(s) == nil then
		return
	end
	local groups = {}
	for group, on in state.caller.groups do
		if on then
			table.insert(groups, group)
		end
	end
	table.sort(groups)
	saved.store(s, { role = state.role, groups = groups, said = state.said })
end

-- About how many tokens the next request takes, with `extra` characters
-- (its system prompt and tools) when the provider hasn't said yet.
local function estimate(state: State, extra: number): number
	local reported = state.reported
	if reported then
		return reported.tokens + compact.tokens(state.said, reported.at + 1)
	end
	return compact.tokens(state.said, 1, extra)
end

-- Replaces all but the end of what `s` said (as much as `tail` tokens hold)
-- with the model's summary of it, shown in the transcript as a folded row
-- with the summary in it. False and why when it can't.
local function compact_now(s: Session, state: State, tail: number?): (boolean, string?)
	local upto = compact.cut(state.said, tail or compact.keep((models.window(state.role))))
	if upto == nil then
		return false, "there's too little to compact yet"
	end
	local before = s.tool
	s.tool = "compacting the conversation"
	s.changed()
	local role = if models.roles[compact.ROLE] then compact.ROLE else state.role
	local summary, err = compact.summarise(role, state.said, upto)
	s.tool = before
	if summary == nil then
		table.insert(
			s.entries,
			{ kind = "note", text = `couldn't compact the conversation: {err}` }
		)
		s.changed()
		return false, err
	end
	state.said = compact.replace(state.said, upto, summary)
	state.reported = nil
	s.tokens = compact.tokens(state.said)
	local tool: session.Tool = {
		id = `compact-{greed.now()}-{#s.entries}`,
		title = `conversation compacted ({upto - 1} messages → summary)`,
		kind = "other",
		status = "completed",
		detail = {},
		output = string.split(summary, "\n"),
		open = false,
	}
	s.tools[tool.id] = tool
	table.insert(s.entries, { kind = "tool", tool = tool })
	keep(s, state)
	s.changed()
	return true, nil
end

-- Turns a prompt into an answer: the model's turns, and the tools it asks
-- for between them, until it's done.
local function prompt(s: Session, text: string, context: string?): (boolean, string?)
	local state = states[s.id]
	if s.status == "working" or s.status == "waiting" then
		return false, "the agent is still working; stop it first"
	end
	state.cancelled = false
	s.failed = nil
	table.insert(s.entries, { kind = "user", text = text })
	local fresh = session.fresh_context(s, context)
	local sent = `<time>{os.date("%A %Y-%m-%d %H:%M %Z")}</time>`
	local said = if fresh then `{sent}\n{fresh}\n\n{text}` else `{sent}\n{text}`
	table.insert(state.said, { role = "user", text = said } :: models.Said)
	s.status = "working"
	s.since = greed.now()
	s.changed()
	state.env = state.env or environment(s.root)
	-- The same from turn to turn, so providers can cache it: the time goes
	-- in each of your messages instead.
	local said_system = system(s, state.env)
	-- Once a summary fails, it isn't asked for again until the next prompt.
	local may_compact = true
	-- Answers cut off at their length in a row.
	local cuts = 0
	-- Requests the provider turned down as too long, compacted and tried again.
	local overflows = 0
	-- What each call (tool and arguments) gave back this prompt.
	local seen: { [string]: string } = {}
	-- Calls that only read in a row, and whether it heard about them.
	local reads, nudged = 0, false
	for _ = 1, MAX_TURNS do
		-- Again each turn, for the groups it switched on in the last.
		local specs, by_name = tools(state)
		local window = models.window(state.role)
		local room = compact.room(window, models.output(state.role))
		local extra = #said_system + #greed.json.encode(specs)
		local tail = compact.keep(window)
		if may_compact and estimate(state, extra) > room and compact.cut(state.said, tail) then
			may_compact = compact_now(s, state, tail)
		end
		local turn, err = models.turn(state.role, {
			system = said_system,
			said = state.said,
			tools = specs,
		}, function(piece)
			say(s, piece)
		end)
		if turn == nil then
			-- Too long for the model after all, as the estimate can be off:
			-- compacted, keeping half as much of the end each time, it's
			-- tried again, a few times at most.
			local smaller = tail * 0.5 ^ (overflows + 1)
			if
				compact.too_long(err)
				and overflows < MAX_OVERFLOWS
				and compact.cut(state.said, smaller)
			then
				overflows += 1
				if compact_now(s, state, smaller) then
					continue
				end
			end
			s.failed = `the model failed: {err}`
			table.insert(s.entries, { kind = "note", text = s.failed })
			break
		end
		-- It answered, so nothing keeps it from working.
		s.problem = nil
		-- An answer cut off at its length may end in half a tool call, so
		-- none of its calls run; the model hears why and goes on in parts.
		local cut = turn.stop == "length"
		table.insert(
			state.said,
			{ role = "assistant", text = turn.text, calls = if cut then {} else turn.calls } :: models.Said
		)
		if turn.tokens then
			state.reported = { tokens = turn.tokens, at = #state.said }
		end
		s.tokens = turn.tokens or s.tokens
		if cut then
			cuts += 1
			if cuts > MAX_CUTS then
				table.insert(
					s.entries,
					{ kind = "note", text = "stopped: the answer ran out of room" }
				)
				break
			end
			table.insert(
				s.entries,
				{ kind = "note", text = "the answer ran out of room; going on" }
			)
			table.insert(state.said, { role = "user", text = CUT_OFF } :: models.Said)
			s.changed()
			continue
		end
		cuts = 0
		if turn.stop ~= "tools" or #turn.calls == 0 then
			break
		end
		for _, c in turn.calls do
			local result, failed = call(s, state, by_name, c)
			-- A call it made already this prompt, coming back the same, says
			-- so: a model can go round asking the same thing.
			local key = c.name .. " " .. greed.json.encode(c.input)
			local before = seen[key]
			seen[key] = result
			if before == result then
				result ..= REPEATED
			end
			-- What it read is what it saw, for writing over it later.
			if c.name == "read" and not failed and type(c.input.path) == "string" then
				local now = core.file.text(c.input.path, s.cwd)
				if now then
					saw(s, c.input.path, now)
				end
			end
			-- Asking the user counts as doing something, as an edit does.
			local tool = s.tools[c.id]
			reads = if tool and tool.kind == "read" and c.name ~= "ask" then reads + 1 else 0
			if reads >= READS and not nudged then
				nudged = true
				result ..= READING
			end
			table.insert(
				state.said,
				{ role = "tool", call = c.id, text = result, error = failed } :: models.Said
			)
			s.changed()
		end
		keep(s, state)
		if state.cancelled then
			table.insert(s.entries, { kind = "note", text = "stopped: cancelled" })
			break
		end
	end
	-- Still waiting for the model's answer to its tools' results: it ran
	-- out of turns.
	local last = state.said[#state.said]
	if last and last.role == "tool" and not state.cancelled and not s.failed then
		table.insert(s.entries, {
			kind = "note",
			text = `stopped: it took {MAX_TURNS} turns without finishing; say go on to let it carry on`,
		})
	end
	s.status = "idle"
	keep(s, state)
	s.changed()
	return true, nil
end

-- The roles the models plugin knows, as the models to pick from.
local function roles(): { session.Mode }
	local list = {}
	for name, role in models.roles do
		if role then
			table.insert(
				list,
				{ id = name, name = name, description = `{role.model} at {role.provider}` }
			)
		end
	end
	table.sort(list, function(a: session.Mode, b: session.Mode)
		return a.id < b.id
	end)
	return list
end

-- Has `s` use the model playing `role`.
local function use(s: Session, state: State, role: string)
	state.role = role
	s.model = role
	s.window = models.window(role)
end

local DRIVER: session.Driver = {
	prompt = prompt,
	cancel = function(s)
		states[s.id].cancelled = true
	end,
	set_model = function(s, id)
		if models.roles[id] == nil then
			return false, `no model plays the role "{id}"`
		end
		use(s, states[s.id], id)
		session.check(s)
		s.changed()
		return true, nil
	end,
	check = function(s)
		return models.check(states[s.id].role)
	end,
}

-- A new session's id: when it started, and a few letters to tell apart
-- sessions started in the same second.
local function new_id(): string
	local salt = greed.hash.sha256(`{greed.now()} {math.random()}`)
	return `{os.date("%Y%m%d-%H%M%S")}-{string.sub(salt, 1, 8)}`
end

--- A session of Greed's own agent for the project at `root`, using the
--- model in role `role` (by default `M.ROLE`, else `reasoning`). With
--- `resume`, the id of a session kept from before, it takes that up where
--- it left off: its transcript, what was said, its model and tool groups.
function M.start(opts: {
	name: string,
	agent: string,
	root: string,
	role: string?,
	resume: string?,
	decide: ((permission: session.Permission) -> string?)?,
	changed: () -> (),
}): (Session?, string?)
	local kept = if opts.resume then saved.load(opts.root, opts.resume) else nil
	if opts.resume and kept == nil then
		return nil, "its conversation isn't kept any more"
	end
	local s = session.start_driven({
		name = opts.name,
		agent = opts.agent,
		root = opts.root,
		cwd = opts.root,
		decide = opts.decide,
		changed = opts.changed,
		driver = DRIVER,
	})
	local role = opts.role or models.playing(M.ROLE)
	local state: State = {
		said = {},
		role = role,
		cancelled = false,
		allowed = {},
		caller = agent.caller(),
		order = {},
	}
	states[s.id] = state
	s.session_id = if kept then kept.id else new_id()
	if kept then
		s.entries = kept.entries
		for _, entry in s.entries do
			if entry.tool then
				s.tools[entry.tool.id] = entry.tool
			end
		end
		table.insert(s.entries, { kind = "note", text = "taken up again" })
		state.said = kept.said
		if models.roles[kept.role] then
			role = kept.role
		end
		for _, group in kept.groups do
			state.caller.groups[group] = true
		end
	end
	s.models = roles()
	use(s, state, role)
	session.check(s)
	return s, nil
end

--- Compacts the conversation of `s`, a session of Greed's own agent, now:
--- the model summarises all but its last few turns. False and why when it
--- can't.
function M.compact(s: Session): (boolean, string?)
	local state = states[s.id]
	if state == nil then
		return false, "only Greed's own agent can be compacted here"
	elseif s.status == "working" or s.status == "waiting" then
		return false, "the agent is working; wait for it or stop it first"
	end
	s.status = "working"
	s.since = greed.now()
	local ok, err = compact_now(s, state)
	s.status = "idle"
	s.changed()
	return ok, err
end

--- Switches tool group `group` on for the session `s`, as the agent would
--- with the tools tool, e.g. to start it with the tools a task needs.
function M.switch_on(s: Session, group: string)
	local state = states[s.id]
	if state then
		state.caller.groups[group] = true
	end
end

return M
