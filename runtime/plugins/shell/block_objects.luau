-- Blocks as objects and things to act on (`space .`), with their actions.

local greed = require("@greed")
local core = require("@core")
local state = require("./state")
local log = require("./log")
local kinds = require("./kinds")

type Shell = state.Shell
type Block = state.Block

-- A block as an object, by its shell's buffer and its number there, saying
-- where it is in that buffer so its actions (commands on the block under
-- the cursor) run on it from anywhere.
local function block_object(shell: Shell, block: Block): core.Object
	local from, to = log.range(block)
	return {
		kind = "shell-block",
		id = `shell-block:{shell.buffer:id()}.{block.number}`,
		label = string.match(block.command, "^[^\n]*") or block.command,
		value = { shell = shell, block = block },
		buffer = shell.buffer,
		from = from,
		to = to,
	}
end

-- A shell as an object, by its buffer.
local function shell_object(shell: Shell): core.Object
	return { kind = "shell", id = `shell:{shell.buffer:id()}`, label = shell.name, value = shell }
end

core.objects.kind({
	name = "shell",
	doc = "A shell: its folder, its variables and the commands it ran",
	list = function()
		local out = {}
		for _, shell in state.list() do
			table.insert(out, shell_object(shell))
		end
		return out
	end,
	get = function(key)
		local shell = state.shells[tonumber(key) or -1]
		return if shell then shell_object(shell) else nil
	end,
	inspect = function(shell: Shell)
		local environment = shell.environment
		return {
			name = shell.name,
			folder = shell.cwd,
			blocks = #shell.blocks,
			running = #state.running(shell),
			environment = if environment then environment.status else shell.unloaded,
		}
	end,
	relations = function(shell: Shell)
		local blocks = {}
		for _, block in shell.blocks do
			table.insert(blocks, block_object(shell, block))
		end
		return {
			buffer = { assert(core.objects.get(`buffer:{shell.buffer:id()}`)) },
			blocks = blocks,
		}
	end,
})

core.actions.action({
	kind = "shell",
	name = "show",
	doc = "Show it in the focused view",
	run = function(target)
		greed.view():show(target.value.buffer)
	end,
})
core.actions.set_default("shell", "show")

-- Blocks as things to act on, with `space .`, and as objects.
core.actions.finder({
	name = "shell-block",
	find = function(view, range)
		local shell = state.of(view:buffer())
		local block = shell and log.block_for(shell, range.head)
		if shell == nil or block == nil then
			return nil
		end
		return { core.objects.target(block_object(shell, block)) }
	end,
})

core.objects.kind({
	name = "shell-block",
	doc = "A command run in a shell, with what it printed and how it ended",
	list = function()
		local out = {}
		for _, shell in state.list() do
			for _, block in shell.blocks do
				table.insert(out, block_object(shell, block))
			end
		end
		return out
	end,
	get = function(key)
		local buffer, number = string.match(key, "^(%d+)%.(%d+)$")
		for _, shell in state.list() do
			if tostring(shell.buffer:id()) == buffer then
				local block = state.block(shell, tonumber(number) :: number)
				return if block then block_object(shell, block) else nil
			end
		end
		return nil
	end,
	inspect = function(value: { shell: Shell, block: Block })
		local block = value.block
		local tbl = block.table
		return {
			command = block.command,
			status = block.status,
			exit_code = block.code,
			signal = block.signal,
			folder = block.cwd,
			lines = block.lines,
			seconds = if block.finished then (block.finished - block.started) / 1000 else nil,
			by = block.by,
			table = if tbl then `{#tbl.rows} rows: {table.concat(tbl.columns, ", ")}` else nil,
		}
	end,
	relations = function(value: { shell: Shell, block: Block })
		return {
			shell = { shell_object(value.shell) },
			rows = kinds.row_objects(value.shell, value.block),
		}
	end,
})
for _, action in
	{
		{ "rerun", "shell-rerun", "Run it again as it ran" },
		{ "rerun here", "shell-rerun-here", "Run it again in the shell's folder now" },
		{ "edit", "shell-edit", "Put its command at the prompt" },
		{ "change", "shell-change", "Change its command and run it in its place" },
		{ "copy output", "shell-copy-output", "Copy what it printed" },
		{ "copy command", "shell-copy-command", "Copy its command" },
		{ "interrupt", "shell-interrupt", "Interrupt it" },
		{ "kill", "shell-kill", "Stop it for good" },
		{ "type into it", "shell-handoff", "Show its program in a terminal" },
		{ "open output", "shell-output-open", "Open its whole output in a buffer" },
		{
			"open beside",
			"shell-beside",
			"Show it in a pane beside, following it, with a filter of its own",
		},
		{
			"readable or as it came",
			"shell-pretty",
			"Its JSON lines, as many logs are, readably or as they came",
		},
		{
			"filter",
			"shell-filter",
			"Keep the lines of its output, or rows of its table, with some text",
		},
		{ "sort by this column", "shell-sort", "Sort its table by the column here" },
		{ "show all", "shell-show-all", "Its output as it came, without a filter or a sort" },
		{
			"open in a float",
			"shell-peek",
			"Look at it more closely, filter it or act on its rows; esc closes it",
		},
		{
			"notify on changes",
			"shell-notify",
			"A notification each time its rows change, saying how; again to stop",
		},
	}
do
	core.actions.command("shell-block", action[1], action[2], action[3])
end

return {}
