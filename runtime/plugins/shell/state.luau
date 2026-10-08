-- Shells and their blocks, as records: what ran, where, how it ended and
-- what it printed. The buffer shows them (log.luau); these are what other
-- plugins and agents read.

local greed = require("@greed")

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
	--- How it ran: "builtin" (the shell itself), "pipe" (a program with its
	--- output and errors apart), "pty" (in a pseudo terminal, as typed
	--- commands run) or "terminal" (handed to a terminal).
	runner: string,
	--- What ran it: "argv" (a program and its arguments), "builtin", or
	--- "shell" (the line went to a real shell, named in `program`).
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
	--- stopped), or "error" (it couldn't start).
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

--- The variables a command in `shell` gets on top of the editor's: pagers
--- off, so output comes back as text, where greed is (`GREED_BIN`), then
--- the shell's own.
function M.environment(env: { [string]: string | false }): { [string]: string | false }
	local out: { [string]: string | false } = { PAGER = "cat", GIT_PAGER = "cat" }
	out.GREED_BIN = M.program() or false
	for name, value: string | false in env do
		out[name] = value
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
		input = block.input,
		into = block.into,
		refs = block.refs,
	}
end

return M
