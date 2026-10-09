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
local pty = require("@self/pty")
local fallback = require("@self/fallback")
local history = require("@self/history")
local data = require("@self/data")
local ask = require("@self/ask")
local tables = require("@self/tables")
local rows = require("@self/rows")
local completion = require("@self/complete")
local segments = require("@self/segments")
local envs = require("@self/envs")
local aliases = require("@self/aliases")
local suggest = require("@self/suggest")
local kinds = require("@self/kinds")
local live = require("@self/live")
require("@self/kubernetes")
require("@self/docker")
require("@self/processes")

type Shell = state.Shell
type Block = state.Block
export type Table = tables.Table
export type EnvironmentProvider = envs.Provider
export type LoadedEnvironment = envs.Loaded

local M = {}

local KIND = "shell"
local LANGUAGE = "greed-shell"

--- The modules, for plugins building on the shell.
M.parse = parse
M.log = log
M.runners = run
M.pty = pty
M.data = data
M.ask = ask
M.tables = tables
M.rows = rows
M.jc = require("@self/jc")
M.sources = require("@self/sources")
M.completion = completion
M.segments = segments
M.edit = require("@self/edit")
M.envs = envs
M.aliases = aliases
M.suggest = suggest
M.history = history
M.kinds = kinds
M.live = live

--- Shows what `provider(ctx)` returns (`{ text, style, warning }`, or nil)
--- in every shell's prompt before its folder; see `segments.segment`.
M.segment = segments.segment

--- Loads the environment folders bring for provider `name` (as devenv
--- does), for `shell-environments` to name; see `envs.provider`.
M.environment = envs.provider

--- Completes the arguments of program `name` with `complete`, ahead of
--- Cobra, fish, carapace and the program's help; see `sources.completer`.
M.completer = M.sources.completer

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

--- What a plugin's builtin gets besides its arguments: the shell and the
--- block it runs for, the block's folder, and how to print in the block,
--- as output or as errors.
export type BuiltinContext = {
	shell: Shell,
	block: Block,
	cwd: string,
	write: (text: string) -> (),
	error: (text: string) -> (),
}

export type BuiltinSpec = {
	name: string,
	--- How it's typed and what it does, for `help`, `which` and completion.
	usage: string,
	doc: string,
	--- What its arguments are, for completion: "folder", "path",
	--- "assignment", "variable" or "topic".
	args: string?,
}

--- Adds a command the shell runs itself, `spec.name`: `call(args, ctx)`
--- does it, printing with `ctx.write`, and gives its exit code (0 when it
--- gives none); an error fails it, saying why. It can wait, as a command
--- can. It wins over a program or an alias of that name, and `^NAME` runs
--- the program instead; the shell's own builtins can't be replaced. It
--- goes when the plugin that added it does.
function M.builtin(spec: BuiltinSpec, call: (args: { string }, ctx: BuiltinContext) -> number?)
	local name = spec.name
	assert(string.match(name, "^[%w_%-]+$"), "a builtin's name is one word")
	local own = parse.BUILTINS[name]
	if own and own.plugin == nil then
		error(`{name} is one of the shell's own builtins`, 2)
	end
	local entry: parse.Builtin =
		{ usage = spec.usage, doc = spec.doc, args = spec.args, plugin = greed.plugin.caller() }
	local function runs(shell: Shell, block: Block, args: { string }): number
		return call(args, {
			shell = shell,
			block = block,
			cwd = block.cwd,
			write = function(text: string)
				run.write(shell, block, text, "stdout")
			end,
			error = function(text: string)
				run.write(shell, block, text, "stderr")
			end,
		}) or 0
	end
	greed.plugin.tie(core.registry.set(parse.BUILTINS, name, entry))
	greed.plugin.tie(core.registry.set(run.builtins, name, runs))
end

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
		provided = {},
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
		table = nil,
		called = nil,
		watching = nil,
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
	envs.prepare(shell, block)
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

-- Runs `line`, programs with `input` going in, in a real shell for
-- `block`, and gives back what they printed, their errors and how they
-- exited (nil when stopped). Interrupting the block stops them. What they
-- print goes to the table stages after them, so it isn't shown.
local function capture(
	shell: Shell,
	block: Block,
	line: string,
	input: string?
): (string, string, number?)
	envs.prepare(shell, block)
	local program = if block.by == "agent" then "sh" else nil
	local wrapped = fallback.prepare(block, line, { program = program, rc = false })
	local child, err = greed.process.spawn(wrapped.argv, {
		cwd = block.cwd,
		env = state.environment(block),
		group = true,
	})
	if child == nil then
		return "", err or `can't start {wrapped.argv[1]}`, 127
	end
	local c = child :: greed.Child
	block.job = {
		interrupt = function()
			c:signal("INT")
		end,
		kill = function()
			c:kill()
		end,
	}
	if input and input ~= "" then
		c:write(input)
	end
	c:close()
	local parts: { string } = {}
	while true do
		local piece = c:read()
		if piece == nil then
			break
		end
		table.insert(parts, piece)
	end
	local code = c:wait()
	block.job = nil
	-- A pipeline's cd and export are its own.
	fallback.collect(block, wrapped)
	block.cwd_after, block.env_changed = nil, nil
	return table.concat(parts), c:stderr(), code
end

-- `template` once for each row of `tbl`, a line each, its `{COL}`s the
-- row's cells quoted for a shell; braces naming no column stay as they
-- are. Nil and why when `tbl` isn't a table or `template` names no column.
local function each_lines(tbl: tables.Table?, template: string): (string?, string?)
	if tbl == nil then
		return nil,
			"each works on a table, and this isn't one; columns, from csv/tsv/json, split or lines make one"
	end
	local named = false
	for name in string.gmatch(template, "{([^{}]+)}") do
		named = named or tables.column(tbl, name) ~= nil
	end
	if not named then
		local example = tbl.columns[1] or "COL"
		return nil,
			`each runs a command for every row with its cells in it, like each echo \{{example}\}; there's {table.concat(
				tbl.columns,
				", "
			)}`
	end
	local lines: { string } = {}
	for _, row in tbl.rows do
		local line = string.gsub(template, "{([^{}]+)}", function(name: string): string
			local column = tables.column(tbl, name)
			return if column then parse.quote(row[column] or "") else "{" .. name .. "}"
		end)
		table.insert(lines, line)
	end
	return table.concat(lines, "\n"), nil
end

-- Runs `line` once as `capture` does, table stages after its programs
-- included, as `kubectl get pods | where RESTARTS > 0`: what it printed in
-- the end, its errors, and how it exited (nil when stopped).
local function capture_all(shell: Shell, block: Block, line: string): (string, string, number?)
	local programs, stages = tables.after_programs(line)
	if programs == nil or stages == nil then
		return capture(shell, block, line, nil)
	end
	local out, errors, code = capture(shell, block, programs, nil)
	if code == nil then
		return out, errors, code
	end
	local value = tables.json(out)
	local tbl = tables.from_value(value) or tables.parse(out, programs, block)
	local staged, rest, why, json = tables.pipeline(tbl, out, stages, value)
	if why then
		return "", errors .. why .. "\n", 2
	end
	local text = if staged
		then tables.text(staged)
		elseif json ~= nil then tables.value_text(json) .. "\n"
		else out
	if rest == nil then
		return text, errors, code
	end
	local more, more_errors, more_code = capture(shell, block, rest, text)
	return more, errors .. more_errors, more_code
end

-- Runs `line` for `block` on `text`, what goes into it (with `value` when
-- that was JSON and `tbl` when it was a table): the table stages at its
-- start, then the programs after them in a real shell. Table stages after
-- programs, as in `kubectl get pods | where STATUS != Running`, run on what
-- the programs print, read as a table as a block's output is. With
-- `raw` the line starts with a program, `^sort`; with `handoff` it runs in
-- a terminal.
local function flow(
	shell: Shell,
	block: Block,
	line: string,
	opts: RunOptions,
	text: string?,
	value: any,
	tbl: tables.Table?,
	flags: { raw: boolean?, handoff: boolean? }
)
	if text ~= nil and not flags.raw then
		local staged, rest, why, json = tables.pipeline(tbl, text, line, value)
		if why then
			run.fail(shell, block, why, 2)
			return
		end
		if staged or json ~= nil then
			local out = if staged then tables.text(staged) else tables.value_text(json) .. "\n"
			if rest == nil then
				block.table = staged
				run.write(shell, block, out, "stdout")
				run.finish(shell, block, 0, nil)
				return
			end
			line, text, value, tbl = rest, out, if staged then nil else json, staged
		end
	end
	block.via = "shell"
	local template = string.match(line, "^%s*each%s+(.-)%s*$")
	if template and text ~= nil and not flags.raw then
		local script, why = each_lines(tbl or tables.from_value(value), template)
		if script == nil then
			run.fail(shell, block, why or "", 2)
		elseif script == "" then
			run.finish(shell, block, 0, nil)
		else
			fall_back(shell, block, script, opts, false, nil)
		end
		return
	end
	local programs, stages = tables.after_programs(line)
	if programs == nil or stages == nil or flags.handoff then
		fall_back(shell, block, line, opts, flags.handoff == true, text)
		return
	end
	local out, errors, code = capture(shell, block, programs, text)
	if errors ~= "" then
		run.write(shell, block, errors, "stderr")
	end
	if code == nil then
		run.finish(shell, block, nil, "INT")
		return
	elseif out == "" and code ~= 0 then
		run.finish(shell, block, code, nil)
		return
	end
	local json = tables.json(out)
	local made = tables.from_value(json) or tables.parse(out, programs, block)
	flow(shell, block, stages, opts, out, json, made, {})
end

-- Adds a block for `command` to `shell`, running.
local function add_block(shell: Shell, command: string, opts: RunOptions): Block
	shell.count += 1
	local block = new_block(shell, command, opts)
	if opts.view then
		state.views[block.uid] = opts.view
	end
	log.add(shell, block)
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

--- Runs `line` in `shell` as a new block after the others and returns it;
--- nil for an empty line, `clear`, which takes the blocks away, or a
--- question for a model (ask.luau), whose answer comes to the prompt. A
--- line of yours starting with one of your shell's aliases runs it, and
--- the block shows what you typed.
function M.run(shell: Shell, line: string, options: RunOptions?): Block?
	local opts: RunOptions = options or {}
	local command = string.match(line, "^%s*(.-)%s*$") or line
	if opts.by ~= "agent" then
		line = aliases.expand(line)
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
	-- `watch COMMAND` runs the command again and again in its block.
	local watched, every, unwatchable = live.read(line)
	if watched or unwatchable then
		local watching = add_block(shell, command, opts)
		if opts.by == "agent" then
			run.fail(shell, watching, "watch runs until it's stopped; run the command once", 2)
		elseif watched then
			live.start(shell, watching, watched, every, capture_all)
		else
			run.fail(shell, watching, unwatchable or "", 2)
		end
		return watching
	end
	local block = add_block(shell, command, opts)
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
		flow(
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

-- `env` also says what environment the folder brings (envs.luau), and
-- `env reload` loads it again.
local list_env = run.builtins.env
run.builtins.env = function(shell: Shell, block: Block, args: { string }): number
	local reload = #args == 1 and args[1] == "reload"
	local code = 0
	if reload then
		envs.reload(shell)
	else
		code = list_env(shell, block, args)
	end
	for _, line in envs.describe(shell) do
		run.write(shell, block, line .. "\n", "stdout")
	end
	local failed = shell.environment and shell.environment.status == "failed"
	return if reload and failed then 1 else code
end

-- What `name` at the start of a line runs, first what wins: a line each.
local function which(shell: Shell, name: string): { string }
	local found: { string } = {}
	local builtin = parse.BUILTINS[name]
	if builtin then
		local whose = if builtin.plugin
			then `a builtin from {builtin.plugin}`
			else "the shell's builtin"
		table.insert(found, `{name}: {whose}, {builtin.usage}`)
	end
	for _, stage in tables.STAGES do
		if stage.name == name then
			local from = if stage.plugin then ` from {stage.plugin}` else ""
			table.insert(found, `{name}: a table stage{from} after $3 |, {stage.usage}`)
			break
		end
	end
	local alias = aliases.known()[name]
	if alias and builtin == nil then
		table.insert(found, `{name}: your alias for {alias}`)
	end
	local program = M.sources.find(name, state.variables(shell).PATH)
	if program then
		local caret = if builtin or alias then ` (^{name} runs it)` else ""
		table.insert(found, `{name}: {program}{caret}`)
	end
	return found
end

run.builtins.which = function(shell: Shell, block: Block, args: { string }): number
	if #args == 0 then
		run.write(shell, block, "which: which names?\n", "stderr")
		return 2
	end
	local code = 0
	for _, name in args do
		local found = which(shell, name)
		if #found == 0 then
			run.write(shell, block, `{name}: not found\n`, "stderr")
			code = 1
		end
		for _, line in found do
			run.write(shell, block, line .. "\n", "stdout")
		end
	end
	return code
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
	-- What opened is for reading and moving around in, not the shell's
	-- typing.
	local view = greed.view()
	if view:buffer() ~= shell.buffer then
		greed.mode.set(core.style.home_for(view))
	end
	return 0
end

-- The keys `help` lists, in the vscode style and in the others.
local HELP_KEYS = {
	vscode = {
		{ "enter", "run what's at the prompt; alt-enter starts another line" },
		{ "up  down", "commands typed before, starting with what's typed" },
		{ "right  end", "take the rest of the command the prompt suggests" },
		{ "ctrl-r", "pick a command typed before" },
		{ "tab", "complete a program, its flags, a file, $3, buf:; again for each in the menu" },
		{ "ctrl-c", "copy a selection, or interrupt the running block" },
		{ "ctrl-t", "type into the running block's program" },
		{ "ctrl-up  ctrl-down", "the block before or after the cursor" },
		{ "f8  shift-f8", "the next or previous file:line the output names" },
		{ "ctrl-space r  R", "run the block again, as it ran or here" },
		{ "ctrl-space y  Y", "copy its output or its command" },
		{ "ctrl-space x  v  c", "stop it, open its output, clear finished blocks" },
		{ "ctrl-f", "keep a block's lines with what's typed, or a table's rows (COL=VALUE)" },
		{ "ctrl-space s  S", "sort a table by the column here; show it as it came" },
	},
	other = {
		{ "enter", "run what's at the prompt; on a block, edit its command" },
		{ "up  down", "commands typed before, starting with what's typed" },
		{ "right  end", "take the rest of the command the prompt suggests" },
		{ "ctrl-r", "pick a command typed before" },
		{ "tab", "complete a program, its flags, a file, $3, buf:; again for each in the menu" },
		{ "ctrl-c", "interrupt the running block" },
		{ "ctrl-t", "type into the running block's program" },
		{ "[ p  ] p", "the block before or after the cursor (normal mode)" },
		{ "] e  [ e", "the next or previous file:line the output names" },
		{ "g o", "select the block's output" },
		{ "space r  R", "run the block again, as it ran or here" },
		{ "space y  Y", "copy its output or its command" },
		{ "space x  v  c", "stop it, open its output, clear finished blocks" },
		{ "/", "keep a block's lines with what's typed, or a table's rows (COL=VALUE)" },
		{ "space s  S", "sort a table by the column here; show it as it came" },
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

-- The lines of each part of `help` (parse.HELP_TOPICS), by topic.
local TOPICS: { [string]: () -> { string } } = {
	builtins = function()
		local rows: { { string } } = {}
		for _, name in parse.builtin_names() do
			local builtin = parse.BUILTINS[name]
			table.insert(rows, { builtin.usage, builtin.doc })
		end
		local lines = { "Run by the shell itself:" }
		add_columns(lines, rows)
		local program, carries = fallback.which()
		local carry = if carries
			then "cd and export there carry over"
			else "cd and export there don't carry over"
		table.insert(lines, "")
		table.insert(
			lines,
			`Everything else runs in {program} ({carry}); :set shell-fallback picks another.`
		)
		return lines
	end,
	line = function()
		local lines = { "Read by the shell in a line:" }
		add_columns(lines, {
			{ "$3 | cmd", "block 3's output as cmd's input; $3 alone shows it again" },
			{ "buf:NAME | cmd", "a buffer's text as input; open buf:NAME shows it" },
			{ "@sel | cmd", "the selection in the file you're in" },
			{ "@file | cmd", "the file you're in" },
			{ "cmd > buf:NAME", "cmd's output into a buffer; >> adds to it" },
			{ "!cmd", "run cmd in a terminal from the start" },
			{ "? question", "ask a model for a command, put at the prompt to run" },
			{ "cmd ? question", "the same, starting from what's typed; or end with ?" },
		})
		return lines
	end,
	tables = function()
		local lines = {
			"/ on a block's output keeps the lines with what's typed (/ again for a regex);",
			"in a table, COL=VALUE, COL~TEXT and COL>N look in a column.",
			"",
			"Run by the shell on a table, or on text to make one, after $3 |:",
		}
		local rows: { { string } } = {}
		for _, stage in tables.STAGES do
			table.insert(rows, { stage.usage, stage.doc })
		end
		add_columns(lines, rows)
		return lines
	end,
	prompt = function()
		local lines = { "Before the folder, the prompt shows:" }
		add_columns(lines, {
			{ "⎇ main", "the branch of the repository the shell is in" },
			{
				"⎈ context:namespace",
				"the kubernetes context kubectl would use, from its config",
			},
			{ "❄ devenv", "the environment the folder brings (env says more)" },
		})
		local production = greed.option.get("shell-production-contexts")
		table.insert(lines, "")
		table.insert(
			lines,
			`A context matching shell-production-contexts ({production}) shows in red, and so does ❯.`
		)
		local others: { string } = {}
		for _, name in segments.names() do
			if name ~= "git" and name ~= "kubernetes" and name ~= "environment" then
				table.insert(others, name)
			end
		end
		if #others > 0 then
			table.insert(lines, `From plugins: {table.concat(others, ", ")}.`)
		end
		return lines
	end,
	keys = function()
		local style = core.style.current().name
		local lines = { `Keys ({style} style):` }
		add_columns(lines, if style == "vscode" then HELP_KEYS.vscode else HELP_KEYS.other)
		return lines
	end,
}

-- The topics' names, for saying which there are.
local function topic_names(): string
	local names: { string } = {}
	for _, topic in parse.HELP_TOPICS do
		table.insert(names, topic.name)
	end
	return table.concat(names, ", ")
end

--- The page `help` prints: what the shell runs itself and which shell runs
--- the rest, what it reads in a line, tables, and the keys in the style in
--- use; with `topic`, only that part. Nil for a topic it doesn't know.
function M.help(topic: string?): string?
	local lines: { string } = {}
	for _, part in parse.HELP_TOPICS do
		if topic == nil or topic == part.name then
			if #lines > 0 then
				table.insert(lines, "")
			end
			local more = TOPICS[part.name]()
			table.move(more, 1, #more, #lines + 1, lines)
		end
	end
	if #lines == 0 then
		return nil
	end
	if topic == nil then
		table.insert(lines, "")
		table.insert(lines, `help TOPIC shows one part: {topic_names()}.`)
		table.insert(lines, "The shell page in Greed's docs has the rest.")
	end
	return table.concat(lines, "\n") .. "\n"
end

run.builtins.help = function(shell: Shell, block: Block, args: { string }): number
	local page = M.help(args[1])
	if page == nil then
		run.write(shell, block, `help: no topic {args[1]}; there's {topic_names()}\n`, "stderr")
		return 1
	end
	run.write(shell, block, page, "stdout")
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
	M.run(shell, line, { view = ctx.view })
	-- Undo takes back typing since the last run, never what ran: the
	-- steps before it would put their text back in the empty prompt.
	shell.buffer:clear_history()
end

-- Puts `block`'s command at the prompt to change and run again.
local function edit(shell: Shell, block: Block, ctx: greed.Context)
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

-- Takes what the prompt suggests, or else runs `otherwise`, the key's
-- usual command.
local function accept_or(ctx: greed.Context, otherwise: string)
	local shell = state.of(ctx.buffer)
	if shell == nil or not suggest.accept(shell, ctx.view) then
		greed.run(otherwise)
	end
end

greed.command({
	name = "shell-accept-or-right",
	doc = "At the end of the prompt, take the rest of the command it suggests; elsewhere move right",
	run = function(ctx)
		accept_or(ctx, "move-right")
	end,
})

greed.command({
	name = "shell-accept-or-end",
	doc = "At the end of the prompt, take the rest of the command it suggests; elsewhere go to the end of the line",
	run = function(ctx)
		accept_or(ctx, "line-end")
	end,
})

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

-- The finished block whose output holds the cursor, if any; for a block
-- a filter shows nothing of, its command line too.
local function output_block(ctx: greed.Context): (Shell?, Block?)
	local shell = state.of(ctx.buffer)
	local pos = ctx.view:cursor()
	local block = shell and log.block_at(shell, pos)
	if shell == nil or block == nil or block.status == "running" then
		return nil, nil
	end
	local from, to = log.output_range(shell, block)
	local inside = from ~= nil and to ~= nil and pos >= from and pos <= to
	if not inside and block.shown == nil then
		return nil, nil
	end
	return shell, block
end

-- Puts the cursor of `view` on `block`'s first line of output, where a
-- table's header is, or its command when a filter shows none of it, so
-- it stays in the block as what it shows changes.
local function to_output(shell: Shell, block: Block, view: greed.View)
	local from = log.output_range(shell, block) or log.range(block)
	if from then
		view:set_cursor(from)
	end
end

greed.command({
	name = "shell-filter",
	doc = "Keep the lines of the block at the cursor with what's typed in them (/ for a regex), or a table's rows (COL=VALUE, COL~TEXT, COL>N); elsewhere, search",
	run = function(ctx)
		local shell, block = output_block(ctx)
		if shell == nil or block == nil then
			greed.run("search")
			return
		end
		local view = ctx.view
		local shown = block.shown
		local sort, desc = if shown then shown.sort else nil, shown ~= nil and shown.desc
		local function set(text: string)
			rows.set(shell, block, text, sort, desc)
			to_output(shell, block, view)
		end
		core.prompt.open({
			title = if block.table then "Filter rows" else "Filter lines",
			text = if shown then shown.filter else "",
			on_change = set,
			on_submit = set,
			on_cancel = function()
				set("")
			end,
		})
	end,
})

greed.command({
	name = "shell-sort",
	doc = "Sort the table at the cursor by the column under it; again to reverse, a third time as it came",
	run = function(ctx)
		local shell, block = output_block(ctx)
		local pos = ctx.view:cursor()
		local column = shell and block and rows.column_at(shell, block, pos)
		if shell == nil or block == nil or column == nil then
			greed.echo("put the cursor on a column of a table, like kubectl get pods prints")
			return
		end
		local col = ctx.buffer:display_column(pos)
		rows.sort(shell, block, column)
		-- The cursor stays in the column, on the header.
		local from = log.output_range(shell, block)
		if from then
			ctx.view:set_cursor(ctx.buffer:at_display_column(ctx.buffer:line_of(from), col))
		end
	end,
})

greed.command({
	name = "shell-unfilter",
	doc = "Show every line, or row, of the filtered block at the cursor again, keeping its sort",
	run = function(ctx)
		local shell, block = output_block(ctx)
		local shown = block and block.shown
		if shell and block and shown and shown.filter ~= "" then
			rows.set(shell, block, "", shown.sort, shown.desc)
			to_output(shell, block, ctx.view)
		end
	end,
})

greed.command({
	name = "shell-show-all",
	doc = "Show the block at the cursor's output as it came, without a filter or a sort",
	run = function(ctx)
		local shell, block = output_block(ctx)
		if shell and block then
			rows.reset(shell, block)
		end
	end,
})

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
		{
			"filter",
			"shell-filter",
			"Keep the lines of its output, or rows of its table, with some text",
		},
		{ "sort by this column", "shell-sort", "Sort its table by the column here" },
		{ "show all", "shell-show-all", "Its output as it came, without a filter or a sort" },
	}
do
	core.actions.command("shell-block", action[1], action[2], action[3])
end

-- What the prompt shows can change with any command: a cd, a checkout,
-- `kubectl config use-context`; and so can the environment the folder
-- brings. A block's rows are read as things as it finishes, while what
-- they came from (a kubernetes context) is still what it ran against.
run.on_finish(function(shell: Shell, block: Block)
	kinds.finished(shell, block)
	greed.spawn(function()
		envs.refresh(shell)
	end)
end)

kinds.runs_with(function(shell: Shell, line: string, view: greed.View)
	M.run(shell, line, { view = view })
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
