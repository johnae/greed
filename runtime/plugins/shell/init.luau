-- A shell in a buffer: type a command at the prompt at the bottom, enter
-- runs it, and it becomes a block above: the command, what it printed, and
-- how it ended. Blocks stay to read, search, fold, copy and run again.
--
--   space o s   switch to a shell, or open one (:shell opens a new one)
--   enter       run what's at the prompt; on a block, edit its command
--   [ p  ] p    the block before or after the cursor
--   g o         select the block's output
--   ctrl-c      interrupt the running block (vscode style: copy a selection)
--   ctrl-t      type into the running block's program, in a terminal
--   space r     run the block again, as it ran; space R here and now
--   space y/Y   copy its output / its command
--   space x     stop it; space v opens its whole output; space c clears
--
-- The shell runs `cd`, `export`, `unset`, `env`, `history`, `clear` and
-- `open` itself, and starts a program with plain arguments on its own;
-- lines with pipes, globs or variables go to a real shell. Programs run in
-- a pseudo terminal (pty.luau), handed to a terminal when they want one;
-- an agent's run through a pipe. Each shell has its own folder and
-- variables, and a project can have several.

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")
local terminal = require("@terminal")
local parse = require("@self/parse")
local state = require("@self/state")
local log = require("@self/log")
local run = require("@self/run")
local pty = require("@self/pty")

type Shell = state.Shell
type Block = state.Block

local M = {}

local KIND = "shell"
local LANGUAGE = "greed-shell"

--- The modules, for plugins building on the shell.
M.parse = parse
M.log = log
M.runners = run
M.pty = pty

--- The shell shown in `buffer`, if it's one.
M.of = state.of

--- Every shell, or those of project `project`, oldest first.
M.list = state.list

--- Block `number` of `shell`, if it's still there.
M.block = state.block

--- A block as plain data, for agents and tools.
function M.record(block: Block): { [string]: any }
	run.fill(block)
	return state.record(block)
end

-- A name for a new shell in project `project`: "shell", "shell 2", ...
local function new_name(project: number?): string
	local taken: { [string]: boolean } = {}
	for _, shell in state.list(project) do
		taken[shell.name] = true
	end
	if not taken.shell then
		return "shell"
	end
	local n = 2
	while taken[`shell {n}`] do
		n += 1
	end
	return `shell {n}`
end

export type OpenOptions = {
	--- What to call it; "shell", "shell 2", ... by default.
	name: string?,
	--- The folder to start in; by default the focused shell's or terminal's,
	--- or the project's root.
	cwd: string?,
	--- The view to show it in; the focused one by default. With `show =
	--- false` it isn't shown at all, e.g. for an agent's shell.
	view: greed.View?,
	show: boolean?,
}

-- The folder a new shell starts in, from what `view` shows.
local function here(view: greed.View): string
	local shell = state.of(view:buffer())
	if shell then
		return shell.cwd
	end
	return terminal.cwd(view:buffer()) or greed.project.current().root
end

--- Opens a new shell and shows it, with the cursor at its prompt.
function M.open(options: OpenOptions?): Shell
	local opts: OpenOptions = options or {}
	local view = opts.view or greed.view()
	local buffer = greed.create_buffer(KIND, "", { language = LANGUAGE })
	buffer:set_line_numbers(false)
	buffer:set_kept(true)
	-- Output streams into the buffer as edits; keeping each to undo would
	-- make undo at the prompt take output back. Edits kept out of undo can
	-- replace this later.
	buffer:forget_history()
	local project = buffer:project() or greed.project.current().id
	local shell: Shell = {
		id = state.new_id(),
		name = opts.name or new_name(project),
		buffer = buffer,
		project = project,
		cwd = core.project.clean(opts.cwd or here(view)),
		oldpwd = nil,
		env = {},
		blocks = {},
		count = 0,
		prompt = buffer:track(0, { gravity = "left" }),
		ticking = false,
	}
	state.shells[buffer:id()] = shell
	log.draw_prompt(shell)
	if opts.show ~= false then
		M.show(shell, view)
	end
	return shell
end

--- Shows `shell` in `view` (the focused one by default) with the cursor at
--- the end of its prompt, typing.
function M.show(shell: Shell, view: greed.View?)
	local v = view or greed.view()
	if v:buffer() ~= shell.buffer then
		v:show(shell.buffer)
	end
	v:set_cursor(shell.buffer:len())
	if v == greed.view() then
		greed.mode.set(core.style.typing_mode())
	end
end

-- Redraws the running blocks' status each second while there are any.
local function tick(shell: Shell)
	if shell.ticking then
		return
	end
	shell.ticking = true
	greed.spawn(function()
		while true do
			greed.sleep(1000)
			local running = state.running(shell)
			if #running == 0 or not shell.buffer:valid() then
				break
			end
			for _, block in running do
				log.draw_block(shell, block)
			end
		end
		shell.ticking = false
	end)
end

export type RunOptions = {
	--- "user" (the default) or "agent". An agent's cd and export show in
	--- its block but don't change the shell.
	by: string?,
	--- The folder and variables to run with, instead of the shell's.
	cwd: string?,
	env: { [string]: string | false }?,
	--- The view it was typed in, where a handoff shows.
	view: greed.View?,
	--- How programs run: "pty" (a pseudo terminal, the default for the
	--- user's commands) or "pipe" (output and errors apart, the default
	--- for an agent's).
	runner: ("pty" | "pipe")?,
}

-- A new block for `command` in `shell`, running.
local function new_block(shell: Shell, command: string, opts: RunOptions): Block
	return {
		number = shell.count,
		uid = state.new_uid(),
		command = command,
		cwd = opts.cwd or shell.cwd,
		env = table.clone(opts.env or shell.env),
		runner = "builtin",
		via = "builtin",
		program = nil,
		by = opts.by or "user",
		client = greed.client.id(),
		started = greed.now(),
		finished = nil,
		time = os.time(),
		code = nil,
		signal = nil,
		status = "running",
		handed = false,
		waiting = false,
		output = "",
		stdout = "",
		stderr = "",
		truncated = false,
		spill = nil,
		lines = 0,
		omitted = 0,
		cwd_after = nil,
		env_changed = nil,
		note = nil,
		value = nil,
		range = nil,
		job = nil,
		done = greed.signal(),
	}
end

-- Takes the finished blocks out of `shell`.
local function clear(shell: Shell)
	for _, block in table.clone(shell.blocks) do
		if block.status ~= "running" then
			log.remove(shell, block)
			state.views[block.uid] = nil
		end
	end
end

-- Starts `argv` for `block`: in a pseudo terminal, handed to a terminal
-- right away for a line typed with `!`, or through a pipe for an agent or
-- when asked.
local function start(
	shell: Shell,
	block: Block,
	argv: { string },
	opts: RunOptions,
	handoff: boolean
)
	local runner = opts.runner or (if block.by == "agent" then "pipe" else "pty")
	if runner == "pipe" and not handoff then
		block.runner = "pipe"
		run.pipe(shell, block, argv)
	else
		pty.start(shell, block, argv, { terminal = handoff })
	end
end

--- Runs `line` in `shell` as a new block after the others and returns it;
--- nil for an empty line, or `clear`, which takes the blocks away.
function M.run(shell: Shell, line: string, options: RunOptions?): Block?
	local opts: RunOptions = options or {}
	local parsed = parse.parse(line, greed.fs.dirs().home)
	if parsed.kind == "empty" then
		return nil
	end
	if parsed.kind == "builtin" and parsed.name == "clear" and opts.by ~= "agent" then
		log.set_prompt(shell, "")
		clear(shell)
		return nil
	end
	local command = string.match(line, "^%s*(.-)%s*$") or line
	shell.count += 1
	local block = new_block(shell, command, opts)
	if opts.view then
		state.views[block.uid] = opts.view
	end
	log.add(shell, block)
	tick(shell)
	if parsed.error then
		run.fail(shell, block, parsed.error, 2)
	elseif parsed.kind == "builtin" then
		run.builtin(shell, block, parsed.name :: string, parsed.args or {})
	elseif parsed.kind == "argv" then
		block.via = "argv"
		local argv = run.program(parsed.argv :: { string }, block.cwd)
		start(shell, block, argv, opts, parsed.terminal)
	else
		block.via = "shell"
		block.program = "sh"
		start(shell, block, { "sh", "-c", parsed.line }, opts, parsed.terminal)
	end
	return block
end

--- Waits for `block` to finish (in a command, handler or greed.spawn) and
--- returns it.
function M.wait(block: Block): Block
	if block.status ~= "running" then
		return block
	end
	return block.done:wait()
end

--- Interrupts `block`, as ctrl-c does in a terminal. False when it isn't
--- running.
function M.interrupt(block: Block): boolean
	local job = block.job
	if job == nil or block.status ~= "running" then
		return false
	end
	job.interrupt()
	return true
end

--- Stops `block` for good. False when it isn't running.
function M.kill(block: Block): boolean
	local job = block.job
	if job == nil or block.status ~= "running" then
		return false
	end
	job.kill()
	return true
end

run.builtins.open = function(shell: Shell, block: Block, args: { string }): number
	if #args == 0 then
		run.write(shell, block, "open: which files?\n", "stderr")
		return 2
	end
	for _, arg in args do
		core.file.open(core.project.resolve(arg, block.cwd))
	end
	return 0
end

run.builtins.history = function(shell: Shell, block: Block, _args: { string }): number
	for _, b in shell.blocks do
		if b ~= block then
			run.write(shell, block, `{b.number}  {b.command}\n`, "stdout")
		end
	end
	return 0
end

-- The shell of the command's buffer, or a message saying it isn't one.
local function shell_of(ctx: greed.Context): Shell?
	local shell = state.of(ctx.buffer)
	if shell == nil then
		greed.echo("not a shell: space o s opens one")
	end
	return shell
end

-- The block at the cursor, or the latest one when the cursor is at the
-- prompt.
local function target(shell: Shell, ctx: greed.Context): Block?
	local pos = ctx.view:cursor()
	if log.in_prompt(shell, pos) then
		return shell.blocks[#shell.blocks]
	end
	return log.block_at(shell, pos)
end

-- The running block at the cursor, or else the latest running one.
local function running_target(shell: Shell, ctx: greed.Context): Block?
	local at = target(shell, ctx)
	if at and at.status == "running" then
		return at
	end
	local running = state.running(shell)
	return running[#running]
end

-- Defines a command acting on a shell's block.
local function block_command(
	name: string,
	doc: string,
	act: (shell: Shell, block: Block, ctx: greed.Context) -> (),
	pick: ((shell: Shell, ctx: greed.Context) -> Block?)?
)
	greed.command({
		name = name,
		doc = doc,
		run = function(ctx)
			local shell = shell_of(ctx)
			if shell == nil then
				return
			end
			local block = if pick then pick(shell, ctx) else target(shell, ctx)
			if block == nil then
				greed.echo("no block here")
				return
			end
			act(shell, block, ctx)
		end,
	})
end

greed.command({
	name = "shell",
	doc = "Open a new shell: a buffer of commands and what they printed",
	args = { { name = "name", doc = "What to call it" } },
	run = function(ctx)
		local name = if #ctx.args > 0 then table.concat(ctx.args, " ") else nil
		M.open({ name = name, view = ctx.view })
	end,
})

greed.command({
	name = "pick-shell",
	doc = "Switch to a shell of this project, or open a new one",
	run = function(ctx)
		local shells = state.list(greed.project.current().id)
		if #shells == 0 then
			M.open({ view = ctx.view })
			return
		end
		local items: { picker.Item } = { { label = "new shell", value = 0 } }
		for _, shell in shells do
			local running = #state.running(shell)
			local busy = if running > 0 then ` · {running} running` else ""
			table.insert(items, {
				label = `{shell.name}  {core.project.tilde(shell.cwd)}{busy}`,
				value = shell.buffer:id(),
			})
		end
		picker.pick("Shells", items, function(item)
			local shell = state.shells[item.value]
			if shell then
				M.show(shell)
			else
				M.open()
			end
		end)
	end,
})

-- Runs what's at the prompt.
local function run_prompt(shell: Shell, ctx: greed.Context)
	M.run(shell, log.prompt_text(shell), { view = ctx.view })
end

-- Puts `block`'s command at the prompt to change and run again.
local function edit(shell: Shell, block: Block, ctx: greed.Context)
	log.set_prompt(shell, block.command, { ctx.view })
	greed.mode.set(core.style.typing_mode())
end

greed.command({
	name = "shell-enter",
	doc = "Run what's at the prompt; on a block, put its command at the prompt to edit",
	run = function(ctx)
		local shell = shell_of(ctx)
		if shell == nil then
			return
		end
		if log.in_prompt(shell, ctx.view:cursor()) then
			run_prompt(shell, ctx)
		elseif core.style.is_typing() then
			greed.run("insert-newline")
		else
			local block = log.block_at(shell, ctx.view:cursor())
			if block then
				edit(shell, block, ctx)
			end
		end
	end,
})

greed.command({
	name = "shell-run",
	doc = "Run what's at the prompt",
	run = function(ctx)
		local shell = shell_of(ctx)
		if shell then
			run_prompt(shell, ctx)
		end
	end,
})

block_command("shell-edit", "Put the block's command at the prompt, to change and run again", edit)

block_command(
	"shell-rerun",
	"Run the block's command again, in the folder and with the variables it had",
	function(shell, block, ctx)
		M.run(shell, block.command, { cwd = block.cwd, env = block.env, view = ctx.view })
	end
)

block_command(
	"shell-rerun-here",
	"Run the block's command again in the shell's folder now",
	function(shell, block, ctx)
		M.run(shell, block.command, { view = ctx.view })
	end
)

block_command("shell-copy-output", "Copy what the block printed", function(_shell, block)
	run.fill(block)
	greed.clipboard.set(block.output)
	greed.echo(`copied block {block.number}'s output`)
end)

block_command("shell-copy-command", "Copy the block's command", function(_shell, block)
	greed.clipboard.set(block.command)
	greed.echo(`copied {block.command}`)
end)

block_command(
	"shell-interrupt",
	"Interrupt the running block at the cursor, or the latest one, as ctrl-c does",
	function(_shell, block)
		M.interrupt(block)
	end,
	running_target
)

block_command(
	"shell-kill",
	"Stop the running block at the cursor, or the latest one, for good",
	function(_shell, block)
		M.kill(block)
	end,
	running_target
)

block_command(
	"shell-handoff",
	"Show the running block's program in a terminal, to type into it",
	function(_shell, block)
		local job = block.job
		if job == nil or job.handoff == nil or not job.handoff() then
			greed.echo("only a program running in a pseudo terminal can be typed into")
		end
	end,
	running_target
)

greed.command({
	name = "shell-copy-or-interrupt",
	doc = "Copy the selection, or with nothing selected interrupt the running block",
	run = function(ctx)
		for _, range in ctx.view:selection().ranges do
			if range.anchor ~= range.head then
				greed.run("copy-or-line")
				return
			end
		end
		local shell = shell_of(ctx)
		local block = shell and running_target(shell, ctx)
		if block then
			M.interrupt(block)
		else
			greed.echo("nothing running to interrupt")
		end
	end,
})

block_command(
	"shell-output-open",
	"Open the block's whole output in a buffer of its own",
	function(_shell, block, ctx)
		run.fill(block)
		local buffer = if block.spill
			then greed.load(block.spill)
			else greed.create_buffer("file", block.output)
		if ctx.view:is_pane() then
			ctx.view:split("right", buffer)
		else
			ctx.view:show(buffer)
		end
	end
)

greed.command({
	name = "shell-clear",
	doc = "Take the finished blocks out of the shell",
	run = function(ctx)
		local shell = shell_of(ctx)
		if shell then
			clear(shell)
		end
	end,
})

-- Moves the cursor to the block before (`back`) or after its line.
local function to_block(ctx: greed.Context, back: boolean)
	local shell = shell_of(ctx)
	if shell == nil then
		return
	end
	local found = log.neighbor(shell, ctx.view:cursor(), back)
	if found == nil then
		greed.echo(`no block {if back then "before" else "after"} this one`)
		return
	end
	ctx.view:set_cursor(found)
end

greed.command({
	name = "shell-prev-block",
	doc = "Go to the block before the cursor",
	run = function(ctx)
		to_block(ctx, true)
	end,
})

greed.command({
	name = "shell-next-block",
	doc = "Go to the block after the cursor, or the prompt",
	run = function(ctx)
		to_block(ctx, false)
	end,
})

block_command(
	"shell-select-output",
	"Select the block's output, to copy or search",
	function(shell, block, ctx)
		local from, to = log.output_range(shell, block)
		if from == nil or to == nil then
			greed.echo("the block printed nothing")
			return
		end
		ctx.view:set_selection({
			ranges = { { anchor = from, head = math.max(from, to - 1) } },
			primary = 1,
		})
	end
)

-- The prompt's glyph and folder follow what's typed.
greed.on("buffer.changed", function(event: greed.BufferChanged)
	local shell = state.of(event.buffer)
	if shell then
		log.draw_prompt(shell)
	end
end)

-- A shell whose buffer was closed stops what it runs.
greed.on("buffer.closed", function(event: greed.BufferClosed)
	local shell = state.shells[event.id]
	if shell == nil then
		return
	end
	state.shells[event.id] = nil
	for _, block in shell.blocks do
		M.kill(block)
		state.views[block.uid] = nil
	end
	log.forget(shell)
end)

core.folds.provider(LANGUAGE, function(buffer: greed.Buffer, line: number): (number?, number)
	local shell = state.of(buffer)
	if shell == nil then
		return nil, line
	end
	return log.fold(shell, line)
end)

-- Blocks as things to act on, with `space .`.
core.actions.finder({
	name = "shell-block",
	find = function(view, range)
		local shell = state.of(view:buffer())
		local block = shell and log.block_at(shell, range.head)
		if block == nil then
			return nil
		end
		return { { kind = "shell-block", label = block.command, value = block.number } }
	end,
})
for _, action in
	{
		{ "rerun", "shell-rerun", "Run it again as it ran" },
		{ "rerun here", "shell-rerun-here", "Run it again in the shell's folder now" },
		{ "edit", "shell-edit", "Put its command at the prompt" },
		{ "copy output", "shell-copy-output", "Copy what it printed" },
		{ "copy command", "shell-copy-command", "Copy its command" },
		{ "interrupt", "shell-interrupt", "Interrupt it" },
		{ "kill", "shell-kill", "Stop it for good" },
		{ "type into it", "shell-handoff", "Show its program in a terminal" },
		{ "open output", "shell-output-open", "Open its whole output in a buffer" },
	}
do
	core.actions.command("shell-block", action[1], action[2], action[3])
end

-- A running block keeps the session on :q (core's on-quit).
core.file.running("shells", function()
	local found = {}
	for _, shell in state.shells do
		for _, block in state.running(shell) do
			table.insert(found, `{block.command} in {shell.name}`)
		end
	end
	return found
end)

-- Coming back from a terminal a program was handed to, the prompt takes
-- typing again.
core.style.typing_kind(KIND)

greed.keymap.bind({ layer = "leader" }, { ["o s"] = "pick-shell" })
greed.keymap.bind({ role = "typing", kind = KIND }, {
	enter = "shell-enter",
	["alt-enter"] = "insert-newline",
	["ctrl-c"] = "shell-interrupt",
	["ctrl-t"] = "shell-handoff",
})
-- In the vscode style ctrl-c copies a selection, and blocks are a ctrl-arrow
-- away, there being no keys without modifiers to spare.
greed.keymap.bind({ style = "vscode", role = "typing", kind = KIND }, {
	["ctrl-c"] = "shell-copy-or-interrupt",
	["ctrl-up"] = "shell-prev-block",
	["ctrl-down"] = "shell-next-block",
})
greed.keymap.bind({ role = "command", kind = KIND }, {
	enter = "shell-enter",
	["ctrl-c"] = "shell-interrupt",
	["ctrl-t"] = "shell-handoff",
	["[ p"] = "shell-prev-block",
	["] p"] = "shell-next-block",
	["g o"] = "shell-select-output",
})
greed.keymap.bind({ layer = "leader", kind = KIND }, {
	r = "shell-rerun",
	R = "shell-rerun-here",
	y = "shell-copy-output",
	Y = "shell-copy-command",
	x = "shell-kill",
	v = "shell-output-open",
	c = "shell-clear",
})

return M
