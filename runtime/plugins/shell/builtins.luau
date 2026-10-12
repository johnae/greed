-- Builtins: those plugins add, and the shell's own `env`, `stop`, `which`,
-- `open` and `history` (`help` is in help.luau).

local greed = require("@greed")
local core = require("@core")
local parse = require("./parse")
local state = require("./state")
local run = require("./run")
local envs = require("./envs")
local tables = require("./tables")
local aliases = require("./aliases")
local sources = require("./sources")
local data = require("./data")
local history = require("./history")

type Shell = state.Shell
type Block = state.Block

local M = {}

--- What a plugin's builtin gets besides its arguments: the shell and the
--- block it runs for, the block's folder, and how to print in the block,
--- as output or as errors.
export type BuiltinContext = {
	shell: Shell,
	block: Block,
	cwd: string,
	write: (text: string) -> (),
	error: (text: string) -> (),
	--- Whether the block was stopped (ctrl-c): its output goes nowhere now,
	--- so a builtin that waits in steps can quit early.
	stopped: () -> boolean,
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

-- The plugins' builtins, by name, to run where a line pipes what they
-- print into table stages, as `prom 'up' | chart` does.
local pluggable: { [string]: (args: { string }, ctx: BuiltinContext) -> number? } = {}

--- Adds a command the shell runs itself, `spec.name`: `call(args, ctx)`
--- does it, printing with `ctx.write`, and gives its exit code (0 when it
--- gives none); an error fails it, saying why. It can wait, as a command
--- can. It wins over a program or an alias of that name, and `^NAME` runs
--- the program instead; the shell's own builtins can't be replaced. It
--- goes when the plugin that added it does.
function M.add(spec: BuiltinSpec, call: (args: { string }, ctx: BuiltinContext) -> number?)
	local name = spec.name
	assert(string.match(name, "^[%w_%-]+$"), "a builtin's name is one word")
	local own = parse.BUILTINS[name]
	if own and own.plugin == nil then
		error(`{name} is one of the shell's own builtins`, 2)
	end
	local entry: parse.Builtin =
		{ usage = spec.usage, doc = spec.doc, args = spec.args, plugin = greed.plugin.caller() }
	local function runs(shell: Shell, block: Block, args: { string }): number
		local function stopped(): boolean
			return block.status ~= "running"
		end
		return call(args, {
			shell = shell,
			block = block,
			cwd = block.cwd,
			write = function(text: string)
				if not stopped() then
					run.write(shell, block, text, "stdout")
				end
			end,
			error = function(text: string)
				if not stopped() then
					run.write(shell, block, text, "stderr")
				end
			end,
			stopped = stopped,
		}) or 0
	end
	greed.plugin.tie(core.registry.set(parse.BUILTINS, name, entry))
	greed.plugin.tie(core.registry.set(run.builtins, name, runs))
	greed.plugin.tie(core.registry.set(pluggable, name, call))
end

-- `line`, programs whose output goes to table stages, run by a plugin's
-- builtin when it's one alone: what it printed, its errors and its exit
-- code. Nil when it's something else.
function M.capture(shell: Shell, block: Block, line: string): (string?, string, number?)
	if string.find(line, "|", 1, true) then
		return nil, "", nil
	end
	local words = parse.words(line, greed.fs.dirs().home)
	local call = if words then pluggable[words[1]] else nil
	if words == nil or call == nil then
		return nil, "", nil
	end
	local args = table.clone(words)
	table.remove(args, 1)
	local out, errors = {}, {}
	local ok, code = pcall(call, args, {
		shell = shell,
		block = block,
		cwd = block.cwd,
		write = function(text: string)
			table.insert(out, text)
		end,
		error = function(text: string)
			table.insert(errors, text)
		end,
		stopped = function(): boolean
			return block.status ~= "running"
		end,
	})
	if not ok then
		return table.concat(out), `{words[1]}: {code}\n`, 1
	end
	return table.concat(out), table.concat(errors), (code :: number?) or 0
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
	local program = sources.find(name, state.variables(shell).PATH)
	if program then
		local caret = if builtin or alias then ` (^{name} runs it)` else ""
		table.insert(found, `{name}: {program}{caret}`)
	end
	return found
end

-- A block's number and its command's first line, as `stop` lists it.
local function stop_line(block: Block): string
	local command = string.match(block.command, "^[^\n]*") or block.command
	return `{block.number}  {command}\n`
end

run.builtins.stop = function(shell: Shell, block: Block, args: { string }): number
	local running: { Block } = {}
	for _, other in state.running(shell) do
		if other ~= block then
			table.insert(running, other)
		end
	end
	if #args == 0 then
		if #running == 0 then
			run.write(shell, block, "nothing else is running\n", "stdout")
		end
		for _, other in running do
			run.write(shell, block, stop_line(other), "stdout")
		end
		return 0
	end
	local code = 0
	for _, arg in args do
		local targets: { Block } = {}
		if arg == "all" then
			targets = running
		else
			local number = tonumber(string.match(arg, "^[$%%]?(%d+)$"))
			local found = if number then state.block(shell, number) else nil
			if found and found ~= block and found.status == "running" then
				targets = { found }
			else
				run.write(shell, block, `stop: {arg} isn't a running block\n`, "stderr")
				code = 1
			end
		end
		for _, target in targets do
			state.stop(target, "interrupt")
			run.write(shell, block, `stopped {stop_line(target)}`, "stdout")
		end
	end
	return code
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

run.builtins.history = function(shell: Shell, block: Block, _args: { string }): number
	local list = history.entries()
	-- The last ones typed, oldest first, as a terminal's shell lists them.
	for i = math.max(#list - 99, 1), #list do
		run.write(shell, block, `{i}  {list[i].command}\n`, "stdout")
	end
	return 0
end

return M
