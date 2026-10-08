-- A shell in a buffer: type a command at the prompt at the bottom, enter
-- runs it, and it becomes a block above: the command, what it printed, and
-- how it ended. Blocks stay to read, search, fold, copy and run again.
--
--   space o s   switch to a shell, or open one (:shell opens a new one)
--   enter       run what's at the prompt; on a block, edit its command
--   [ p  ] p    the block before or after the cursor
--   g o         select the block's output
--   ] e  [ e    the next or previous file:line the output names; enter opens it
--   ctrl-c      interrupt the running block (vscode style: copy a selection)
--   ctrl-t      type into the running block's program, in a terminal
--   space r     run the block again, as it ran; space R here and now
--   space y/Y   copy its output / its command
--   space x     stop it; space v opens its whole output; space c clears
--
-- The shell runs `cd`, `export`, `unset`, `env`, `history`, `clear`,
-- `open` and `help` itself; every other line goes to a real shell, yours
-- (`sh` for an agent), whose cd and export carry over (fallback.luau). It
-- runs in a pseudo terminal (pty.luau), handed to a terminal when a
-- program wants one; an agent's run through a pipe. Each shell has its own
-- folder and variables, and a project can have several.
--
-- `$3 | sort`, `buf:NAME | ...`, `@sel | ...` and `@file | ...` send block
-- 3's output, a buffer, the selection or the file you're in to a command,
-- and `... > buf:NAME` (`>>` adds) sends its output to a buffer
-- (data.luau). Output that's JSON is kept as a value on the block.
--
-- Agents run commands with shell_run and read blocks with shell_read
-- (tools.luau).

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")
local terminal = require("@terminal")
local parse = require("@self/parse")
local state = require("@self/state")
local log = require("@self/log")
local run = require("@self/run")
local pty = require("@self/pty")
local fallback = require("@self/fallback")
local history = require("@self/history")
local data = require("@self/data")
require("@self/complete")

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
M.data = data

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
		input = nil,
		into = nil,
		target = nil,
		refs = nil,
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
-- right away for a line typed with `!`, or through a pipe for an agent,
-- when asked, or for data going in (`input`) or out to a buffer.
local function start(
	shell: Shell,
	block: Block,
	argv: { string },
	opts: RunOptions,
	handoff: boolean,
	input: string?,
	before: ((code: number?, signal: string?) -> ())?
)
	local runner = opts.runner or (if block.by == "agent" then "pipe" else "pty")
	if input or block.target then
		runner = "pipe"
	end
	if runner == "pipe" and not handoff then
		block.runner = "pipe"
		run.pipe(shell, block, argv, before, input)
	else
		pty.start(shell, block, argv, { terminal = handoff, before = before })
	end
end

-- Runs `line` for `block` in a real shell: the user's (`sh` for an agent),
-- whose cd and export carry over to the user's commands after.
local function fall_back(
	shell: Shell,
	block: Block,
	line: string,
	opts: RunOptions,
	handoff: boolean,
	input: string?
)
	local agent = block.by == "agent"
	local wrapped =
		fallback.prepare(block, line, { program = if agent then "sh" else nil, rc = not agent })
	start(shell, block, wrapped.argv, opts, handoff, input, function()
		local cwd, changed = fallback.collect(block, wrapped)
		if not agent then
			if cwd then
				run.move(shell, cwd)
			end
			if changed then
				run.set_env(shell, changed)
			end
		end
	end)
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
	if opts.by ~= "agent" then
		history.add(command, opts.cwd or shell.cwd)
	end
	shell.count += 1
	local block = new_block(shell, command, opts)
	if opts.view then
		state.views[block.uid] = opts.view
	end
	log.add(shell, block)
	tick(shell)
	local input: string?, why: string? = nil, parsed.error
	if parsed.input and why == nil then
		block.input = parsed.input
		local text, _, err = data.read(shell, parsed.input, block.cwd)
		input, why = text, err
	end
	local into = parsed.into
	if into and why == nil then
		block.into = `buf:{into.name}`
		block.target = data.target(into, block.cwd)
	end
	if why then
		run.fail(shell, block, why, 2)
	elseif parsed.kind == "source" then
		run.write(shell, block, input or "", "stdout")
		run.finish(shell, block, 0, nil)
	elseif parsed.kind == "builtin" then
		run.builtin(shell, block, parsed.name :: string, parsed.args or {})
	else
		-- Everything else goes to a real shell, so `ls` and `ls | head`
		-- behave the same, with its aliases (given startup files) and
		-- builtins.
		block.via = "shell"
		fall_back(shell, block, parsed.line, opts, parsed.terminal, input)
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
		local name = string.match(arg, "^buf:(.+)$")
		local buffer = if name then data.buffer(name, block.cwd) else nil
		if buffer then
			local main = greed.tab.current().active
			main:show(buffer)
			main:focus()
		elseif name then
			run.write(shell, block, `open: no buffer is called {name}\n`, "stderr")
			return 1
		else
			core.file.open(core.project.resolve(arg, block.cwd))
		end
	end
	return 0
end

-- The keys `help` lists, in the vscode style and in the others.
local HELP_KEYS = {
	vscode = {
		{ "enter", "run what's at the prompt; alt-enter starts another line" },
		{ "up  down", "commands typed before, starting with what's typed" },
		{ "ctrl-r", "pick a command typed before" },
		{ "tab", "complete a program, a file, $3, buf: or @sel" },
		{ "ctrl-c", "copy a selection, or interrupt the running block" },
		{ "ctrl-t", "type into the running block's program" },
		{ "ctrl-up  ctrl-down", "the block before or after the cursor" },
		{ "f8  shift-f8", "the next or previous file:line the output names" },
		{ "ctrl-space r  R", "run the block again, as it ran or here" },
		{ "ctrl-space y  Y", "copy its output or its command" },
		{ "ctrl-space x  v  c", "stop it, open its output, clear finished blocks" },
	},
	other = {
		{ "enter", "run what's at the prompt; on a block, edit its command" },
		{ "up  down", "commands typed before, starting with what's typed" },
		{ "ctrl-r", "pick a command typed before" },
		{ "tab", "complete a program, a file, $3, buf: or @sel" },
		{ "ctrl-c", "interrupt the running block" },
		{ "ctrl-t", "type into the running block's program" },
		{ "[ p  ] p", "the block before or after the cursor (normal mode)" },
		{ "] e  [ e", "the next or previous file:line the output names" },
		{ "g o", "select the block's output" },
		{ "space r  R", "run the block again, as it ran or here" },
		{ "space y  Y", "copy its output or its command" },
		{ "space x  v  c", "stop it, open its output, clear finished blocks" },
	},
}

-- Adds `rows` to `lines` as two columns, the first padded to line the
-- second up.
local function add_columns(lines: { string }, rows: { { string } })
	local wide = 0
	for _, row in rows do
		wide = math.max(wide, core.text.width(row[1]))
	end
	for _, row in rows do
		table.insert(lines, `  {row[1]}{string.rep(" ", wide - core.text.width(row[1]))}  {row[2]}`)
	end
end

--- The page `help` prints: what the shell runs itself, what it reads in a
--- line, which shell runs the rest, and the keys in the style in use.
function M.help(): string
	local names: { string } = {}
	for name in parse.BUILTINS do
		table.insert(names, name)
	end
	table.sort(names)
	local builtins: { { string } } = {}
	for _, name in names do
		table.insert(builtins, { name, parse.BUILTINS[name] })
	end
	local program, carries = fallback.which()
	local lines = { "Run by the shell itself:" }
	add_columns(lines, builtins)
	table.insert(lines, "")
	table.insert(lines, "Read by the shell in a line:")
	add_columns(lines, {
		{ "$3 | cmd", "block 3's output as cmd's input; $3 alone shows it again" },
		{ "buf:NAME | cmd", "a buffer's text as input; open buf:NAME shows it" },
		{ "@sel | cmd", "the selection in the file you're in" },
		{ "@file | cmd", "the file you're in" },
		{ "cmd > buf:NAME", "cmd's output into a buffer; >> adds to it" },
		{ "!cmd", "run cmd in a terminal from the start" },
	})
	table.insert(lines, "")
	local carry = if carries
		then "cd and export there carry over"
		else "cd and export there don't carry over"
	table.insert(
		lines,
		`Everything else runs in {program} ({carry}); :set shell-fallback picks another.`
	)
	table.insert(lines, "")
	local style = core.style.current().name
	table.insert(lines, `Keys ({style} style):`)
	add_columns(lines, if style == "vscode" then HELP_KEYS.vscode else HELP_KEYS.other)
	table.insert(lines, "")
	table.insert(lines, "The shell page in Greed's docs has the rest.")
	return table.concat(lines, "\n") .. "\n"
end

run.builtins.help = function(shell: Shell, block: Block, _args: { string }): number
	run.write(shell, block, M.help(), "stdout")
	return 0
end

run.builtins.history = function(shell: Shell, block: Block, _args: { string }): number
	local list = history.entries()
	-- The last ones typed, oldest first, as a terminal's shell lists them.
	for i = math.max(#list - 99, 1), #list do
		run.write(shell, block, `{i}  {list[i].command}\n`, "stdout")
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
			local pos = ctx.view:cursor()
			local block = log.block_at(shell, pos)
			if block == nil then
				return
			end
			for _, ref in log.references(shell, block) do
				if pos >= ref.from and pos < ref.to then
					core.file.open_at(ref.path, ref.line - 1, if ref.col then ref.col - 1 else nil)
					return
				end
			end
			edit(shell, block, ctx)
		end
	end,
})

-- Selects the next file:line the output names after the cursor, or with
-- `back` the one before it.
local function to_reference(ctx: greed.Context, back: boolean)
	local shell = shell_of(ctx)
	if shell == nil then
		return
	end
	local head = ctx.view:cursor()
	local list = log.all_references(shell)
	local found = nil
	for _, ref in list do
		if back and ref.to <= head then
			found = ref
		elseif not back and ref.from > head then
			found = ref
			break
		end
	end
	if found == nil then
		greed.echo(if #list == 0 then "no output names a file and line" else "no more")
		return
	end
	ctx.view:set_selection({
		ranges = { { anchor = found.from, head = found.to - 1 } },
		primary = 1,
	})
end

greed.command({
	name = "shell-next-reference",
	doc = "Go to the next file and line a block's output names, like an error's place; enter opens it",
	run = function(ctx)
		to_reference(ctx, false)
	end,
})

greed.command({
	name = "shell-prev-reference",
	doc = "Go to the file and line a block's output names before the cursor",
	run = function(ctx)
		to_reference(ctx, true)
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

-- Each shell's walk through the history, while what's at its prompt is
-- what the walk put there.
local walks: { [number]: history.Walk } = {}

-- Puts the command `step` (1 older, -1 newer) from the one at the prompt
-- there, among those starting with what was typed. Away from the prompt,
-- or on a line of it other than the first (going back) or the last, the
-- arrow moves the cursor as usual.
local function walk(ctx: greed.Context, step: number)
	local buffer = ctx.buffer
	local shell = state.of(buffer)
	local pos = ctx.view:cursor()
	local edge = if step > 0
		then shell and buffer:line_of(log.prompt_start(shell))
		else buffer:line_count() - 1
	if shell == nil or not log.in_prompt(shell, pos) or buffer:line_of(pos) ~= edge then
		greed.run(if step > 0 then "move-up" else "move-down")
		return
	end
	local typed = log.prompt_text(shell)
	local current = walks[shell.id]
	if current == nil or current.shown ~= typed then
		current = history.walk(typed)
		walks[shell.id] = current
	end
	local found = history.step(current, step)
	if found == nil then
		greed.echo(if typed == "" then "no older command" else `no older command starting {typed}`)
		return
	end
	log.set_prompt(shell, found, { ctx.view })
end

greed.command({
	name = "shell-history-back",
	doc = "Put the command typed before at the prompt, one starting with what's typed there",
	run = function(ctx)
		walk(ctx, 1)
	end,
})

greed.command({
	name = "shell-history-forward",
	doc = "Put the command typed after at the prompt, or back to what was typed",
	run = function(ctx)
		walk(ctx, -1)
	end,
})

greed.command({
	name = "shell-history",
	doc = "Pick a command typed before, in any shell, to put at the prompt",
	run = function(ctx)
		local shell = shell_of(ctx)
		if shell == nil then
			return
		end
		local items: { picker.Item } = {}
		for _, command in history.commands() do
			table.insert(items, { label = command, value = command })
		end
		if #items == 0 then
			greed.echo("no commands typed yet")
			return
		end
		local view = ctx.view
		picker.pick("History", items, function(item)
			log.set_prompt(shell, item.value, { view })
			greed.mode.set(core.style.typing_mode())
		end)
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
	up = "shell-history-back",
	down = "shell-history-forward",
	["ctrl-r"] = "shell-history",
	tab = "completion-ask",
})
-- In the vscode style ctrl-c copies a selection, and blocks are a ctrl-arrow
-- away, there being no keys without modifiers to spare.
greed.keymap.bind({ style = "vscode", role = "typing", kind = KIND }, {
	["ctrl-c"] = "shell-copy-or-interrupt",
	["ctrl-up"] = "shell-prev-block",
	["ctrl-down"] = "shell-next-block",
	f8 = "shell-next-reference",
	["shift-f8"] = "shell-prev-reference",
})
greed.keymap.bind({ role = "command", kind = KIND }, {
	enter = "shell-enter",
	["ctrl-c"] = "shell-interrupt",
	["ctrl-t"] = "shell-handoff",
	["ctrl-r"] = "shell-history",
	["[ p"] = "shell-prev-block",
	["] p"] = "shell-next-block",
	["g o"] = "shell-select-output",
	["] e"] = "shell-next-reference",
	["[ e"] = "shell-prev-reference",
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

-- Agents' tools come from the agent plugin, which can be unloaded: they're
-- offered while it's loaded.
local function offer_tools()
	require("@self/tools")(M)
end

if table.find(greed.plugin.list(), "agent") then
	offer_tools()
end

greed.on("plugin.loaded", function(event: greed.PluginLoaded)
	if event.name == "agent" then
		offer_tools()
	end
end)

return M
