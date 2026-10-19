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
-- (data.luau). Output that's JSON is kept as a value on the block, and a
-- table (kubectl get, docker ps, ps) as a table, which `$3 | where ...`,
-- `select` and `sort` work on (tables.luau). `/` filters what a block
-- shows, and `space s` sorts a table (rows.luau).
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
local folding = require("@self/folding")
-- Loaded here, before navigate, for the order their event handlers run in.
require("@self/pty")
local fallback = require("@self/fallback")
local history = require("@self/history")
local data = require("@self/data")
local ask = require("@self/ask")
local tables = require("@self/tables")
-- The commands the shell reads with sikt programs.
require("@self/readers")
local rows = require("@self/rows")
local completion = require("@self/complete")
local segments = require("@self/segments")
local envs = require("@self/envs")
local aliases = require("@self/aliases")
require("@self/suggest")
local kinds = require("@self/kinds")
local live = require("@self/live")
local peek = require("@self/peek")
local pretty = require("@self/pretty")
require("@self/filtering")
local navigate = require("@self/navigate")
local sources = require("@self/sources")
local builtins = require("@self/builtins")
local help = require("@self/help")
local pipeline = require("@self/pipeline")
require("@self/processes")

export type Shell = state.Shell
export type Block = state.Block
export type Table = tables.Table
export type Thing = kinds.Thing
export type SegmentContext = segments.Context
export type Segment = segments.Segment
export type EnvironmentProvider = envs.Provider
export type LoadedEnvironment = envs.Loaded

local M = {}

local KIND = "shell"
local LANGUAGE = "greed-shell"

--- Reading command lines (`parse.words`, `parse.quote`) and tables, for
--- plugins building on the shell.
M.parse = parse
M.tables = tables

--- `text` quoted as one word for the shell your lines run in (nu's and
--- fish's quotes differ from sh's), or for `program`, as "sh".
M.quote = fallback.quote

--- Where `block` is in its shell's buffer, from its command to the next
--- block; and where what it printed is. Nil once its text was deleted.
M.range = log.range
M.output = log.output_range

--- Puts `text` at `shell`'s prompt, and takes `block` away.
M.set_prompt = log.set_prompt
M.remove = log.remove

--- The block at `pos` in `shell`'s buffer, and the row of its table there,
--- filtered and sorted as it shows.
M.block_at = log.block_at
M.row_at = rows.row_at

--- How `block` is going: its glyph, its status line, and for a running one
--- what the strip says.
M.glyph = log.glyph
M.status = log.status_text
M.running_status = log.running_status

--- Calls `listener(block)` when a block's output or status changes, when
--- its lines are placed in the buffer, and `call(shell, block)` once it
--- finishes.
M.on_update = log.on_update
M.on_status = log.on_status
M.on_placed = log.on_placed
M.on_finish = run.on_finish

--- Shows `block` in a peek float; and the block a peek's view shows.
M.peek = peek.open
M.peeked = peek.of

--- The command line `block` ran.
M.command_line = kinds.command_line

--- `line` read as `watch [-n SECONDS] COMMAND`: the command and how many
--- seconds apart, or nil (with why when it's a watch that can't run).
M.watched = live.read

--- The buffer `> buf:NAME` writes to, made if there's none.
M.into = data.target

--- Runs a completion source's program the way the shell's sources do; see
--- `sources.run`.
M.run_source = sources.run

--- What could complete the word before the cursor in a view showing a
--- shell's prompt.
M.completions = completion.items

--- Uses `aliases` from now on, or with nil reads your shell's again.
M.use_aliases = aliases.use

--- A prompt segment's icon in use, whether a context is a production one
--- (`shell-production-contexts`), and drawing a shell's prompt again.
M.icon = segments.icon
M.production = segments.production
M.refresh_prompt = segments.refresh

--- Shows what `provider(ctx)` returns (`{ text, style, warning }`, or nil)
--- in every shell's prompt before its folder; see `segments.segment`.
M.segment = segments.segment

--- Gives segment `name` its icons, plain and from a Nerd Font, for
--- `shell-icons` to pick; see `segments.add_icon`.
M.segment_icon = segments.add_icon

--- Has the prompt's git segment find a folder's branch with `find(dir)`;
--- see `segments.branch_finder`.
M.branch_finder = segments.branch_finder

--- The editor's environment: what programs a shell starts get under the
--- shell's own variables.
M.editor_environment = state.editor_environment

--- Loads the environment folders bring for provider `name` (as devenv
--- does), for `shell-environments` to name; see `envs.provider`.
M.environment = envs.provider

--- Completes the arguments of program `name` with `complete`, ahead of
--- Cobra, fish, carapace and the program's help; see `sources.completer`.
M.completer = sources.completer

--- Reads the output of the commands `match` names (a program, or a pattern
--- for the command line) as tables with `parse`, ahead of the shell's own
--- look for one; see `tables.parser`.
M.parser = tables.parser

--- Adds a table stage, as in `$3 | NAME ...`; see `tables.stage`.
M.stage = tables.stage

--- Says what the rows of some commands' tables are, to act on; see
--- `kinds.kind`.
M.kind = kinds.kind

--- Adds an action running a command made from a thing; see `kinds.command`.
M.action_command = kinds.command

--- A kind's `fresh` for things shells show, from the command line that
--- lists just one; see `kinds.fresh`.
M.fresh = kinds.fresh

--- Reads what a program puts before each line of a log it merged, like
--- kubectl's `[pod/api-1/app] `, as fields; see `pretty.prefix`.
M.log_prefix = pretty.prefix

--- The variables the block a thing's row came from ran with; see
--- `kinds.env_of`.
M.env_of = kinds.env_of

export type BuiltinContext = builtins.BuiltinContext
export type BuiltinSpec = builtins.BuiltinSpec

--- Adds a command the shell runs itself; see `builtins.add`.
M.builtin = builtins.add

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
	-- What's typed and printed here is nothing to save.
	core.file.scratch(buffer)
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
		segments = nil,
		environment = nil,
		provided = {},
		unloaded = nil,
		strip = nil,
	}
	state.shells[buffer:id()] = shell
	log.draw_prompt(shell)
	greed.spawn(function()
		envs.refresh(shell)
	end)
	-- Read now, so the first line typed needn't wait for them.
	greed.spawn(aliases.known)
	if opts.show ~= false then
		M.show(shell, view)
	end
	return shell
end

--- The current project's shell: its first, or a new one in its root,
--- opened without showing it, as tools and plugins that run programs in
--- the project's environment want.
function M.project(): Shell
	local project = greed.project.current()
	return state.list(project.id)[1] or M.open({ cwd = project.root, show = false })
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

export type RunOptions = pipeline.RunOptions

-- A new block for `command` in `shell`, running.
local function new_block(shell: Shell, command: string, opts: RunOptions): Block
	return {
		number = shell.count,
		uid = state.new_uid(),
		command = command,
		cwd = opts.cwd or shell.cwd,
		env = table.clone(opts.env or shell.env),
		provided = {},
		runner = "builtin",
		via = "builtin",
		program = nil,
		runs_in = opts.program or (if opts.by == "agent" then "sh" else nil),
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
		table = nil,
		called = nil,
		watching = nil,
		drawn = nil,
		change = nil,
		notify = nil,
		shown = nil,
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
			peek.follow(block)
			state.views[block.uid] = nil
		end
	end
end

-- Makes `block`, finished, a new block for `command`, running, in its
-- place: its number and where it is stay, with what it printed, its filter
-- and its sort gone.
local function reuse(shell: Shell, block: Block, command: string, opts: RunOptions): Block
	rows.reset(shell, block)
	local fresh = new_block(shell, command, opts)
	fresh.number, fresh.uid, fresh.range = block.number, block.uid, block.range
	for key in block :: any do
		(block :: any)[key] = nil
	end
	for key, value in fresh :: any do
		(block :: any)[key] = value
	end
	if opts.view then
		state.views[block.uid] = opts.view
	end
	log.restart(shell, block)
	tick(shell)
	return block
end

-- Adds a block for `command` to `shell`, running, or runs it in
-- `opts.block`'s place.
local function add_block(shell: Shell, command: string, opts: RunOptions): Block
	if opts.block then
		return reuse(shell, opts.block, command, opts)
	end
	shell.count += 1
	local block = new_block(shell, command, opts)
	if opts.view then
		state.views[block.uid] = opts.view
	end
	log.add(shell, block)
	folding.fold_older(shell, block)
	tick(shell)
	return block
end

-- What `source` names for an agent, whose `$N` is the block with id N
-- (the id shell_run gives back) in any shell: that shell and the block's
-- `$` there, or nil when there's none. Anything else is as it is.
local function by_id(shell: Shell, source: string): (Shell?, string)
	local id = tonumber(string.match(source, "^%$(%d+)$"))
	if id == nil then
		return shell, source
	end
	for _, other in state.list() do
		for _, block in other.blocks do
			if block.uid == id then
				return other, `${block.number}`
			end
		end
	end
	return nil, source
end

-- Runs `start`, which starts `block`. Its failing (a capability refused, a
-- program that can't start, anything) ends the block as failed with the
-- error as its output, so a block never stays running with nothing said.
local function starting(shell: Shell, block: Block, start: () -> ())
	local why: string? = nil
	xpcall(start, function(err)
		why = tostring(err)
	end)
	if why and block.status == "running" then
		state.stop(block, "kill")
		local message = string.match(why, "^[^\n]*") or why
		run.fail(shell, block, (string.gsub(message, "^runtime error: ", "")))
	end
end

-- Starts `block`, made for the line `parsed`: its builtin, or its programs
-- and table stages, with what goes in.
local function begin(
	shell: Shell,
	block: Block,
	parsed: parse.Parsed,
	opts: RunOptions,
	file_error: string?
)
	local why = file_error or parsed.error
	-- What goes in (`$3 | ...`): its text, its JSON and its table.
	local input: string?, value: any, source: tables.Table? = nil, nil, nil
	if parsed.input and why == nil then
		block.input = parsed.input
		local from: Shell?, named = shell, parsed.input
		if opts.by == "agent" then
			from, named = by_id(shell, parsed.input)
		end
		local err: string? = `there's no block with id {string.sub(named, 2)}`
		if from then
			input, value, err = data.read(from, named, block.cwd)
			source = data.table(from, named, input, value)
			local number = tonumber(string.match(named, "^%$(%d+)$"))
			block.from = if number then state.block(from, number) else nil
		end
		why = err
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
		-- builtins; table stages run on what goes in and what programs
		-- print.
		pipeline.flow(
			shell,
			block,
			parsed.line,
			opts,
			input,
			value,
			source,
			{ raw = parsed.raw, handoff = parsed.terminal }
		)
	end
end

--- Runs `line` in `shell` as a new block after the others and returns it;
--- nil for an empty line, `clear`, which takes the blocks away, or a
--- question for a model (ask.luau), whose answer comes to the prompt. A
--- line of yours starting with one of your shell's aliases runs it, and
--- the block shows what you typed.
---
--- Called by a plugin, the programs the line runs are that plugin's: it
--- needs `proc`, and the builtins `cd` and `open` need `fs.read`. The
--- shell's own work around them, its wrapper files, history, environments
--- and prompt, is the shell's. A block that can't start ends as failed,
--- saying why.
function M.run(shell: Shell, line: string, options: RunOptions?): Block?
	local opts: RunOptions = options or {}
	local command = opts.typed or string.match(line, "^%s*(.-)%s*$") or line
	if opts.by ~= "agent" and not opts.expanded then
		local by
		line, by = aliases.expand(line)
		if by then
			-- A plugin's alias runs as that plugin may.
			local again = table.clone(opts)
			again.expanded = true
			again.typed = command
			return greed.plugin.within(by, M.run, shell, line, again)
		end
	end
	-- `$3` after the first word is a file holding what block 3 printed.
	local with_files, file_error = data.files(shell, line, opts.by == "agent")
	line = with_files or line
	local parsed = parse.parse(line, greed.fs.dirs().home)
	if parsed.kind == "empty" then
		return nil
	end
	if parsed.kind == "builtin" and parsed.name == "clear" and opts.by ~= "agent" then
		log.set_prompt(shell, "")
		clear(shell)
		return nil
	end
	if opts.by ~= "agent" then
		history.add(command, opts.cwd or shell.cwd)
		local draft, question = ask.question(line)
		if draft and question then
			greed.spawn(function()
				ask.ask(shell, line, draft, question, function(why: string)
					run.unanswered(shell, add_block(shell, command, opts), why)
				end)
			end)
			return nil
		end
	end
	-- A command printing rows again as they change, `kubectl get pods -w`,
	-- shows them in place, as its kind says.
	if opts.by ~= "agent" and not parsed.raw and kinds.streams(line) then
		local following = add_block(shell, command, opts)
		starting(shell, following, function()
			live.follow(shell, following, line, pipeline.open_stream)
		end)
		return following
	end
	-- `watch COMMAND` runs the command again and again in its block.
	local watched, every, unwatchable = live.read(line)
	if watched or unwatchable then
		local watching = add_block(shell, command, opts)
		if opts.by == "agent" then
			run.fail(shell, watching, "watch runs until it's stopped; run the command once", 2)
		elseif watched then
			starting(shell, watching, function()
				live.start(shell, watching, watched, every, pipeline.capture_all)
			end)
		else
			run.fail(shell, watching, unwatchable or "", 2)
		end
		return watching
	end
	local block = add_block(shell, command, opts)
	starting(shell, block, function()
		begin(shell, block, parsed, opts, file_error)
	end)
	return block
end

--- Runs `line` in `block`'s place, with its folder and variables, as
--- `run` would: the same number, place and floats, with what it printed,
--- its filter and its sort replaced, and what it showed kept as `before`.
--- A running block is stopped first. This is how a watch or `kubectl get
--- -w` switches to showing something else.
--- Waits (in a command, handler or greed.spawn) for that.
function M.change(shell: Shell, block: Block, line: string, options: RunOptions?): Block?
	if block.status == "running" then
		M.kill(block)
		M.wait(block)
	end
	run.fill(block)
	local before: state.Before =
		{ command = block.command, output = block.output, time = block.time, status = block.status }
	local opts: RunOptions = if options then table.clone(options) else {}
	opts.block = block
	opts.cwd = opts.cwd or block.cwd
	opts.env = opts.env or block.env
	opts.by = opts.by or block.by
	local ran = M.run(shell, line, opts)
	if ran then
		ran.before = before
	end
	return ran
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
	return state.stop(block, "interrupt")
end

--- Stops `block` for good. False when it isn't running.
function M.kill(block: Block): boolean
	return state.stop(block, "kill")
end

--- The page `help` prints; see `help.help`.
M.help = help.help

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
	return log.block_for(shell, pos)
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
	name = "shell-line",
	doc = "Run a command line in this project's shell, opening one if there's none, as :!cmd does",
	args = { { name = "line", doc = "What to run, as typed at the prompt" } },
	run = function(ctx)
		local line = table.concat(ctx.args, " ")
		if string.match(line, "^%s*$") then
			error("shell-line needs something to run, e.g. :!cargo test", 0)
		end
		local shell = state.list(greed.project.current().id)[1]
		if shell then
			M.show(shell, ctx.view)
		else
			shell = M.open({ view = ctx.view })
		end
		M.run(shell, line)
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
		elseif #shells == 1 and ctx.buffer ~= shells[1].buffer then
			-- The only one: no need to pick. From it, the picker offers a
			-- new one.
			M.show(shells[1], ctx.view)
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

-- The last command you ran in `shell`, or else typed at any shell.
local function previous_command(shell: Shell): string?
	for i = #shell.blocks, 1, -1 do
		local block = shell.blocks[i]
		if block.by == "user" then
			return block.command
		end
	end
	return history.commands()[1]
end

-- Runs what's at the prompt, with `!!`, `!$` and `^old^new` as a shell
-- expands them. Many lines, as a paste of a transcript or a file can leave
-- there, run only once you say so.
local function run_prompt(shell: Shell, ctx: greed.Context)
	local expanded, why = history.expand(log.prompt_text(shell), previous_command(shell))
	if expanded == nil then
		greed.echo(why or "")
		return
	end
	local line = expanded
	local _, breaks = string.gsub(line, "\n", "")
	local most = greed.option.get("shell-confirm-lines") :: number
	if breaks + 1 > most then
		greed.echo(`run these {breaks + 1} lines as one command? y/n`)
		local yes = greed.next_key() == "y"
		greed.echo("")
		if not yes then
			return
		end
	end
	local editing = shell.editing
	shell.editing = nil
	log.draw_prompt(shell)
	if editing and table.find(shell.blocks, editing) then
		M.change(shell, editing, line, { view = ctx.view })
	else
		M.run(shell, line, { view = ctx.view })
	end
	-- Undo takes back typing since the last run, never what ran: the
	-- steps before it would put their text back in the empty prompt.
	shell.buffer:clear_history()
end

-- Puts `block`'s command at the prompt to change and run again in its
-- place.
local function edit(shell: Shell, block: Block, ctx: greed.Context)
	shell.editing = block
	log.set_prompt(shell, block.command, { ctx.view })
	greed.mode.set(core.style.typing_mode())
end

greed.command({
	name = "shell-enter",
	doc = "Run what's at the prompt; on a block, put its command at the prompt to edit, or on a row that's a file or a pod, open or describe it",
	run = function(ctx)
		local shell = shell_of(ctx)
		if shell == nil then
			return
		end
		local pos = ctx.view:cursor()
		local stripped = log.strip_block(shell, pos)
		if log.in_prompt(shell, pos) then
			run_prompt(shell, ctx)
		elseif stripped then
			peek.open(shell, stripped)
		elseif core.style.is_typing() and not navigate.on() then
			greed.run("insert-newline")
		else
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
			-- A row that's a thing does what its kind does first.
			if kinds.default(shell, pos) then
				return
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
	"shell-change",
	"Change the block's command and run it in the block's place, as a watch switching to show something else",
	function(shell, block)
		local line = core.prompt.ask("change to", block.command)
		if line and not string.match(line, "^%s*$") then
			M.change(shell, block, line)
		end
	end
)

block_command(
	"shell-peek",
	"Open the block in a float, to filter it, act on its rows or stop it, and close it again with esc",
	function(shell, block)
		peek.open(shell, block)
	end
)

block_command(
	"shell-notify",
	"Send a notification each time a watch's rows change, saying how, while Greed isn't focused; again to stop",
	function(shell, block)
		if block.watching == nil or block.status ~= "running" then
			greed.echo("only a running watch (or kubectl get -w) notifies")
			return
		end
		block.notify = not block.notify
		log.draw_block(shell, block)
		greed.echo(
			if block.notify
				then `{block.number} notifies when it changes`
				else `{block.number} doesn't notify any more`
		)
	end
)

block_command(
	"shell-rerun",
	"Run the block's command again, in the folder and with the variables it had",
	function(shell, block, ctx)
		M.run(shell, block.command, { cwd = block.cwd, env = block.env, view = ctx.view })
	end
)

block_command(
	"shell-beside",
	"Show the block in a pane beside, following it as it prints, with a filter of its own (/)",
	function(shell, block)
		peek.open(shell, block, { beside = true, tail = block.status == "running" })
	end
)

block_command(
	"shell-pretty",
	"Show the block's JSON lines readably (time, level and message first) or as they came",
	function(shell, block)
		local on = not block.pretty
		if not pretty.set(shell, block, on) then
			greed.echo("its lines aren't JSON objects with a time, level or message")
		end
	end
)

block_command(
	"shell-rerun-in-place",
	"Run the block's command again in its place, keeping what it showed before (b in blocks mode shows it)",
	function(shell, block, ctx)
		M.change(shell, block, block.command, { view = ctx.view })
	end
)

-- What `block` showed the run before, or nil after saying it has none.
local function run_before(block: Block): state.Before?
	if block.before == nil then
		greed.echo(`{block.number} hasn't run again in its place`)
	end
	return block.before
end

block_command(
	"shell-before",
	"Show what the block showed the run before this one",
	function(_shell, block)
		local before = run_before(block)
		if before == nil then
			return
		end
		local at = os.date("%H:%M:%S", math.floor(before.time))
		core.floats.show_text(
			`❯ {block.number} the run before, at {at} ({before.status}): {before.command}`,
			before.output,
			{ kind = "shell-before" }
		)
	end
)

-- `old` and `new` as one text, a line each: those in both start with two
-- spaces, those only in `old` with "- " and those only in `new` with "+ ",
-- and marks colouring those.
local function line_diff(old: string, new: string): (string, { greed.Mark })
	local out: { string } = {}
	local marks: { greed.Mark } = {}
	local at_byte = 0
	local function add(prefix: string, text: string)
		local style = if prefix == "- "
			then "diff.minus"
			elseif prefix == "+ " then "diff.plus"
			else nil
		for line in string.gmatch(text, "([^\n]*)\n") do
			local shown = prefix .. line
			if style then
				table.insert(marks, { from = at_byte, to = at_byte + #shown, style = style })
			end
			table.insert(out, shown)
			at_byte += #shown + 1
		end
	end
	local at = 0
	for _, hunk in greed.diff(old, new) do
		add("  ", string.sub(old, at + 1, hunk.from))
		add("- ", string.sub(old, hunk.from + 1, hunk.to))
		add("+ ", hunk.text)
		at = hunk.to
	end
	add("  ", string.sub(old, at + 1))
	return table.concat(out, "\n") .. "\n", marks
end

-- `text` ending in a line break, as `line_diff` reads lines.
local function ended(text: string): string
	return if text == "" or string.sub(text, -1) == "\n" then text else text .. "\n"
end

block_command(
	"shell-diff-before",
	"Show what changed in the block since the run before",
	function(_shell, block)
		local before = run_before(block)
		if before == nil then
			return
		end
		run.fill(block)
		local at = os.date("%H:%M:%S", math.floor(before.time))
		local text, marks = line_diff(ended(before.output), ended(block.output))
		core.floats.show_text(
			`❯ {block.number} since the run at {at}: - then, + now`,
			text,
			{ kind = "shell-before", marks = marks }
		)
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

-- Interrupts `block` of `shell`, saying which blocks still run when others
-- do, as ctrl-c at the prompt stops only the latest.
local function interrupt(shell: Shell, block: Block)
	M.interrupt(block)
	local others: { string } = {}
	for _, other in state.running(shell) do
		if other ~= block then
			table.insert(others, tostring(other.number))
		end
	end
	if #others > 0 then
		greed.echo(
			`stopped {block.number} · still running: {table.concat(others, ", ")} (ctrl-c on its line above the prompt, or stop N)`
		)
	end
end

block_command(
	"shell-interrupt",
	"Interrupt the running block at the cursor, or the latest one, as ctrl-c does",
	interrupt,
	running_target
)

-- Puts the cursor of the focused view on `block` of `shell`, showing the
-- shell there first.
local function go_to(shell: Shell, block: Block)
	local view = greed.view()
	if view:buffer() ~= shell.buffer then
		view:show(shell.buffer)
	end
	local from = log.range(block)
	if from then
		view:set_cursor(from)
		greed.mode.set(core.style.home())
	end
end

greed.command({
	name = "pick-running",
	doc = "Pick among what runs in every shell, its output beside: enter opens it in a float, ctrl-o goes to it, ctrl-x stops it",
	run = function()
		local items: { picker.Item } = {}
		local here = greed.project.current().id
		local shells = state.list(here)
		for _, shell in state.list() do
			if shell.project ~= here then
				table.insert(shells, shell)
			end
		end
		for _, shell in shells do
			for _, block in state.running(shell) do
				local command = string.match(block.command, "^[^\n]*") or block.command
				table.insert(items, {
					label = `{shell.name} {block.number}  {command}  · {log.running_status(block)}`,
					value = { shell = shell, block = block },
				})
			end
		end
		if #items == 0 then
			greed.echo("nothing is running in any shell")
			return
		end
		local function chosen(item: picker.Item?): (Shell?, Block?)
			local value = item and item.value
			return value and value.shell, value and value.block
		end
		picker.pick("Running", items, function(item)
			local shell, block = chosen(item)
			if shell and block then
				peek.open(shell, block)
			end
		end, {
			preview = function(item)
				local shell, block = chosen(item)
				if shell == nil or block == nil then
					return nil
				end
				local from, to = log.range(block)
				if from == nil or to == nil then
					return nil
				end
				return { text = shell.buffer:slice(from, to) }
			end,
			keys = {
				["ctrl-o"] = function(_items, current)
					local shell, block = chosen(current)
					if shell and block then
						go_to(shell, block)
					end
				end,
				["ctrl-x"] = function(_items, current)
					local shell, block = chosen(current)
					if shell and block then
						interrupt(shell, block)
					end
				end,
			},
		})
	end,
})

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
		if core.text.anything_selected(ctx.view:selection()) then
			greed.run("copy-or-line")
			return
		end
		local shell = shell_of(ctx)
		local block = shell and running_target(shell, ctx)
		if shell and block then
			interrupt(shell, block)
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
		if block.spill == nil then
			core.file.scratch(buffer)
		end
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

require("@self/prompt_keys")

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

require("@self/block_filter")

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
	-- In what a command printed, the section indented under a line, as of
	-- YAML or what `kubectl describe` prints; else the whole block.
	local block = log.block_at(shell, buffer:line_start(line))
	local from, to = nil, nil
	if block then
		from, to = log.output_range(shell, block)
	end
	if from and to then
		local top, bottom = buffer:line_of(from), buffer:line_of(to)
		if line >= top then
			local first, last = core.folds.indented(buffer, line, top, bottom, true)
			if first then
				return first, last
			end
		end
	end
	return log.fold(shell, line)
end)

require("@self/block_objects")

-- What the prompt shows can change with any command: a cd, a checkout,
-- `kubectl config use-context`; and so can the environment the folder
-- brings. A block's rows are read as things as it finishes, while what
-- they came from (a kubernetes context) is still what it ran against, and
-- a table's header and cells that say something are colored.
run.on_finish(function(shell: Shell, block: Block)
	kinds.finished(shell, block)
	rows.paint(shell, block)
	greed.spawn(function()
		envs.refresh(shell)
	end)
end)

-- A client that asked for a shell (`greed --shell`, `greed ssh HOST
-- --shell`) is shown the project's last shell, or a new one.
greed.on("client.attached", function(event: greed.ClientAttached)
	if not event.shell then
		return
	end
	local shells = state.list(greed.project.current().id)
	local shell = shells[#shells]
	if shell then
		M.show(shell)
	else
		M.open()
	end
end)

core.actions.action({
	kind = "folder",
	name = "new shell here",
	doc = "Open a shell of its own starting in it",
	run = function(target)
		M.open({ cwd = target.value })
	end,
})

kinds.runs_with(function(shell: Shell, line: string, view: greed.View): Block?
	return M.run(shell, line, { view = view })
end)

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

greed.command({
	name = "shell-esc",
	doc = "Leave the prompt: for blocks mode, or the style's own mode with shell-blocks off",
	run = function(ctx)
		if not (navigate.on() and navigate.enter(ctx.view)) then
			greed.mode.set(core.style.home())
		end
	end,
})

-- Coming back from a terminal a program was handed to, the prompt takes
-- typing again.
core.style.typing_kind(KIND)

greed.keymap.bind({ layer = "leader" }, { ["o s"] = "pick-shell", ["o w"] = "pick-running" })
greed.keymap.bind({ role = "typing", kind = KIND }, {
	enter = "shell-enter",
	esc = "shell-esc",
	["alt-enter"] = "insert-newline",
	["ctrl-c"] = "shell-interrupt",
	["ctrl-t"] = "shell-handoff",
	up = "shell-history-back",
	down = "shell-history-forward",
	["ctrl-r"] = "shell-history",
	tab = "completion-ask",
	right = "shell-accept-or-right",
	["end"] = "shell-accept-or-end",
	["ctrl-e"] = "shell-accept-or-end",
})
-- In the vscode style ctrl-c copies a selection, and blocks are a ctrl-arrow
-- away, there being no keys without modifiers to spare.
greed.keymap.bind({ style = "vscode", role = "typing", kind = KIND }, {
	["ctrl-c"] = "shell-copy-or-interrupt",
	["ctrl-up"] = "shell-prev-block",
	["ctrl-down"] = "shell-next-block",
	f8 = "shell-next-reference",
	["shift-f8"] = "shell-prev-reference",
	["ctrl-f"] = "shell-filter",
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
	["/"] = "shell-filter",
	esc = "shell-unfilter",
})
greed.keymap.bind({ layer = "leader", kind = KIND }, {
	r = "shell-rerun",
	R = "shell-rerun-here",
	y = "shell-copy-output",
	Y = "shell-copy-command",
	x = "shell-kill",
	v = "shell-output-open",
	c = "shell-clear",
	C = "shell-change",
	s = "shell-sort",
	S = "shell-show-all",
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
