-- Shells and their blocks, as records: what ran, where, how it ended and
-- what it printed. The buffer shows them (log.luau); these are what other
-- plugins and agents read.

local greed = require("@greed")
local parse = require("./parse")
local tables = require("./tables")

local M = {}

--- A command run in a shell, and what came of it.
export type Block = {
	--- Its number in its shell, from 1: `$3` is block 3.
	number: number,
	--- Unique across shells, for its marks' namespace.
	uid: number,
	--- What was typed.
	command: string,
	--- The folder it ran in, and the variables the shell set or left out
	--- (false) for it.
	cwd: string,
	env: { [string]: string | false },
	--- The variables the folder's environment (devenv, direnv) gave it,
	--- under `env`.
	provided: { [string]: string | false },
	--- How it ran: "builtin" (the shell itself), "pipe" (a program with its
	--- output and errors apart), "pty" (in a pseudo terminal, as typed
	--- commands run) or "terminal" (handed to a terminal).
	runner: string,
	--- What ran it: "builtin", or "shell" (the line went to a real shell,
	--- named in `program`).
	via: string,
	program: string?,
	--- "user" or "agent".
	by: string,
	--- The client it ran for.
	client: number?,
	--- When it started and finished, on greed.now()'s clock, and the wall
	--- clock time it started (seconds since 1970).
	started: number,
	finished: number?,
	time: number,
	--- How it ended: an exit code, or the signal that ended it.
	code: number?,
	signal: string?,
	--- "running", "done" (exit 0), "failed", "killed" (by a signal, or
	--- stopped), "error" (it couldn't start), or "asked" (a question to a
	--- model that brought no command back).
	status: string,
	--- Whether it was handed to a terminal at some point.
	handed: boolean,
	--- Whether it has been quiet a while, maybe waiting for input.
	waiting: boolean,
	--- What it printed, as it came, and apart: `stdout` and `stderr` for
	--- the pipe runner; a pseudo terminal has only `output`. Each holds at
	--- most the record limit; past that `truncated` is set and the whole
	--- output goes to the file `spill` once it's done.
	output: string,
	stdout: string,
	stderr: string,
	truncated: boolean,
	spill: string?,
	--- How many lines it printed, and how many the buffer leaves out.
	lines: number,
	omitted: number,
	--- The folder and the variables it left behind, when they changed; for
	--- the user's own commands they carry over to the next.
	cwd_after: string?,
	env_changed: { [string]: string | false }?,
	--- A note about how it ran, e.g. that cd in it doesn't carry over.
	note: string?,
	--- The output read as JSON, when it's an object or an array.
	value: any?,
	--- What the line gave back as data besides what it printed: the table
	--- a nu line gave back, as JSON has it.
	data: any?,
	--- The output read as a table, when it's one: aligned columns under a
	--- header (kubectl, docker, ps), `ls -l`, or a JSON array of objects.
	table: tables.Table?,
	--- What its table's rows are, like "pods", when a kind reads them
	--- (kinds.luau).
	called: { one: string, many: string }?,
	--- For a live block (`watch`), the command it runs each time, whose
	--- output it shows.
	watching: string?,
	--- For a live block, what changed in it last and when, as "new
	--- worker-abc · 14:05", and whether a notification says so each time.
	change: string?,
	notify: boolean?,
	--- What a filter, or a sort of its table, shows of its output, when
	--- one does.
	shown: Shown?,
	--- What went to its input (`$3`, `buf:NAME`, `@sel` or `@file`), and
	--- the buffer its output went to instead of the block (`buf:NAME`).
	input: string?,
	into: string?,
	target: greed.Buffer?,
	--- The places in files its output names, like `src/main.rs:12:5`,
	--- once it's done.
	refs: { Ref }?,
	--- Where it is in the buffer.
	range: greed.Tracked?,
	--- The job running it, to interrupt or stop.
	job: Job?,
	--- Sent once it's done.
	done: greed.Signal,
}

--- What a block shows of its output: the rows of its table (or the lines,
--- without one) that `filter` keeps, indexes from 1 of `total`, sorted by
--- `sort`, from the greatest with `desc`.
export type Shown = {
	filter: string,
	sort: string?,
	desc: boolean,
	rows: { number },
	total: number,
}

--- Something running a block.
export type Job = {
	interrupt: () -> (),
	kill: () -> (),
	--- Shows it in a terminal to type into, if it can be.
	handoff: (() -> boolean)?,
	--- The pseudo terminal it runs in, if it does.
	terminal: greed.Terminal?,
}

--- A place in a file a block's output names: the file, its 1-based line
--- and column, and the line of output saying what's there.
export type Ref = { path: string, line: number, col: number?, text: string }

--- A piece of the prompt before the folder, like the git branch: its text,
--- its style ("shell.segment" by default), and whether it's a warning,
--- which turns the prompt's glyph red too. A `tight` one has no space
--- after it, as a run of a longer piece; with `folder` it shows the folder
--- already, as starship's prompt does, so the prompt doesn't again.
export type Segment = {
	text: string,
	style: string?,
	warning: boolean?,
	tight: boolean?,
	folder: boolean?,
	--- A command a click on it runs, as on a button.
	action: string?,
}

--- A shell: a buffer of blocks with a prompt at the end, its own folder and
--- environment.
export type Shell = {
	id: number,
	name: string,
	buffer: greed.Buffer,
	project: number?,
	cwd: string,
	--- The folder before the last cd, for `cd -`.
	oldpwd: string?,
	--- Variables set (a string) or left out (false), on top of the editor's.
	env: { [string]: string | false },
	blocks: { Block },
	--- How many blocks it has run, which numbers the next.
	count: number,
	--- Where the prompt starts.
	prompt: greed.Anchor,
	ticking: boolean,
	--- What the prompt shows before the folder, as last worked out.
	segments: { Segment }?,
	--- The environment the folder it's in brings, as devenv or direnv
	--- gives it (envs.luau), and its variables, under `env`; or why one
	--- there isn't loaded, like it not being allowed yet.
	environment: Environment?,
	provided: { [string]: string | false },
	unloaded: string?,
	--- The strip of running blocks between the others and the prompt, when
	--- some have scrolled up out of the way (log.luau).
	strip: Strip?,
}

--- An environment a folder brings: who gives it and for which folder,
--- whether it's loaded, its variables, what loading it printed, and the
--- files whose change means loading it again.
--- The lines above the prompt that stand for running blocks: where they
--- start, the blocks, a line each, and their text.
export type Strip = {
	at: greed.Anchor,
	blocks: { Block },
	text: string,
}

export type Environment = {
	provider: string,
	root: string,
	status: "loading" | "loaded" | "failed",
	vars: { [string]: string | false },
	output: string,
	error: string?,
	seconds: number?,
	watch: { string },
	stale: boolean,
	--- What waits for a load to finish, each sent once it has.
	waiters: { greed.Signal },
}

--- Shells by their buffer's id.
M.shells = {} :: { [number]: Shell }

--- The view each block was run from, by its uid: where a handoff shows,
--- and whose size a pseudo terminal starts at.
M.views = {} :: { [number]: greed.View }

local next_id = 0
local next_uid = 0

function M.new_id(): number
	next_id += 1
	return next_id
end

function M.new_uid(): number
	next_uid += 1
	return next_uid
end

--- The shell shown in `buffer`, if it's one.
function M.of(buffer: greed.Buffer): Shell?
	return M.shells[buffer:id()]
end

--- The shells of project `project` (every one with nil), oldest first.
function M.list(project: number?): { Shell }
	local list: { Shell } = {}
	for _, shell in M.shells do
		if project == nil or shell.project == project then
			table.insert(list, shell)
		end
	end
	table.sort(list, function(a: Shell, b: Shell)
		return a.id < b.id
	end)
	return list
end

--- Block `number` of `shell`, if it's still there.
function M.block(shell: Shell, number: number): Block?
	for _, block in shell.blocks do
		if block.number == number then
			return block
		end
	end
	return nil
end

--- The block with id `uid` in any shell, and that shell, if it's still
--- there.
function M.find(uid: number?): (Shell?, Block?)
	for _, shell in M.list() do
		for _, block in shell.blocks do
			if block.uid == uid then
				return shell, block
			end
		end
	end
	return nil, nil
end

--- The blocks still running in `shell`.
function M.running(shell: Shell): { Block }
	local list: { Block } = {}
	for _, block in shell.blocks do
		if block.status == "running" then
			table.insert(list, block)
		end
	end
	return list
end

-- The greed program, once it's known whether it prints the environment
-- (`greed --env0`): false when it doesn't, as when the editor runs inside
-- another program, like a test runner.
local program: string | false | nil = nil

--- The greed program running the editor, which prints the environment
--- exactly on every system with `--env0`, or nil when it can't. Finding
--- out runs it once, so before then (or where nothing can wait) it's nil.
function M.program(): string?
	if program == nil and coroutine.isyieldable() then
		local path = greed.session.program()
		local result = if path then greed.process.run({ path, "--env0" }) else nil
		local works = result ~= nil
			and result.code == 0
			and string.find(result.stdout, "=", 1, true)
		program = if works then path else false
	end
	return program or nil
end

local editor_env: { [string]: string }? = nil

--- The editor's environment, read once: what programs a shell starts get
--- under the shell's own variables.
function M.editor_environment(): { [string]: string }
	if editor_env then
		return editor_env
	end
	local vars: { [string]: string } = {}
	local path = M.program()
	local result = greed.process.run(if path then { path, "--env0" } else { "env", "-0" })
	if result then
		for _, entry in string.split(result.stdout, "\0") do
			local name, value = string.match(entry, "^([^=]+)=(.*)$")
			if name and value then
				vars[name] = value
			end
		end
	end
	editor_env = vars
	return vars
end

--- The variables programs started in `shell` get, all of them: the
--- editor's, then its folder's environment's, then the shell's own.
function M.variables(shell: Shell): { [string]: string }
	local vars: { [string]: string } = table.clone(M.editor_environment())
	for _, layer in { shell.provided, shell.env } do
		for name, value: string | false in layer do
			if value == false then
				vars[name] = nil
			else
				vars[name] = value
			end
		end
	end
	return vars
end

greed.option.define({
	name = "shell-editor",
	doc = "Whether programs you run in a shell, like git commit, open files to edit in Greed: $EDITOR, $VISUAL, $GIT_EDITOR, $JJ_EDITOR and $KUBE_EDITOR are greed edit --wait",
	default = true,
})

-- The variables programs read for an editor, the tools' own first, which
-- would otherwise win over a git or jj config's editor.
local EDITOR_VARIABLES = { "EDITOR", "VISUAL", "GIT_EDITOR", "JJ_EDITOR", "KUBE_EDITOR" }

--- The variables `block`'s command gets on top of the editor's: pagers
--- off, so output comes back as text, where greed is (`GREED_BIN`), the
--- session and block it runs in, an editor that opens files here for a
--- block you ran, then its folder's environment's, then the block's own.
function M.environment(block: Block): { [string]: string | false }
	local out: { [string]: string | false } = { PAGER = "cat", GIT_PAGER = "cat" }
	out.GREED_BIN = M.program() or false
	out.GREED_SESSION = greed.session.current() or false
	out.GREED_BLOCK = tostring(block.uid)
	local program = greed.session.program()
	if program and block.by == "user" and greed.option.get("shell-editor") then
		-- Programs run it through a shell, so the path is quoted.
		local editor = `{parse.quote(program)} edit --wait`
		for _, name in EDITOR_VARIABLES do
			out[name] = editor
		end
	end
	for _, layer in { block.provided, block.env } do
		for name, value: string | false in layer do
			out[name] = value
		end
	end
	return out
end

--- A block as plain data, for agents and for the history: without its
--- place in the buffer or the job running it.
function M.record(block: Block): { [string]: any }
	local seconds = if block.finished then (block.finished - block.started) / 1000 else nil
	return {
		number = block.number,
		command = block.command,
		cwd = block.cwd,
		env = block.env,
		runner = block.runner,
		via = block.via,
		program = block.program,
		by = block.by,
		time = block.time,
		seconds = seconds,
		code = block.code,
		signal = block.signal,
		status = block.status,
		handed = block.handed,
		output = block.output,
		stdout = block.stdout,
		stderr = block.stderr,
		truncated = block.truncated,
		spill = block.spill,
		lines = block.lines,
		cwd_after = block.cwd_after,
		env_changed = block.env_changed,
		note = block.note,
		value = block.value,
		table = block.table,
		input = block.input,
		into = block.into,
		refs = block.refs,
	}
end

return M
