-- Tools for agents: run a command in the project's shell and get it back
-- as data (what ran, where, how it ended, what it printed), read a block
-- the user or an agent ran, wait for one and stop one. An agent's blocks
-- show in the shell with ◆, run through a pipe in `sh` with their input
-- closed, and their cd and export stay in their block.
--
-- What commands print was written by someone else, so it goes back to a
-- model marked as untrusted, as web pages and files do; `greed ctl` gets
-- it as it is.

local greed = require("@greed")
local core = require("@core")
local state = require("./state")
local edit = require("./edit")

type Shell = state.Shell
type Block = state.Block

greed.option.define({
	name = "shell-agent-max-output",
	doc = "How many bytes of a command's output and of its errors the shell tools give an agent: the start and the end, with what's between left out",
	default = 30000,
})

-- How many of a table's rows a tool gives back.
local TABLE_ROWS = 50

-- How long shell_run waits for a command before saying it's still running,
-- in seconds.
local DEFAULT_TIMEOUT = 60

-- What the tools need from the plugin, which loads them after it's set up.
export type Shells = {
	open: (options: any) -> Shell,
	project: () -> Shell,
	run: (shell: Shell, line: string, options: any) -> Block?,
	kill: (block: Block) -> boolean,
	wait: (block: Block) -> Block,
	record: (block: Block) -> { [string]: any },
}

-- `text`, what block `id` printed, cut to whole lines in its first and
-- last `max` / 2 bytes (a line longer than that on a character boundary),
-- saying how much was left out and how to get at it; and whether it was
-- cut.
local function cut(text: string, max: number, id: number): (string, boolean)
	if #text <= max then
		return text, false
	end
	local function boundary(at: number): number
		-- Back off continuation bytes, so a character isn't split.
		while at > 1 and at <= #text do
			local byte = string.byte(text, at)
			if byte < 0x80 or byte >= 0xC0 then
				break
			end
			at -= 1
		end
		return at
	end
	-- The head ends after its last whole line, the tail starts at a line.
	local half = max // 2
	local head_end = boundary(half + 1) - 1
	local last_break = string.find(string.sub(text, 1, half), "\n[^\n]*$")
	if last_break then
		head_end = last_break
	end
	local tail_start = boundary(#text - half + 1)
	local next_break = string.find(text, "\n", #text - half, true)
	if next_break and next_break < #text then
		tail_start = next_break + 1
	end
	local head = string.sub(text, 1, head_end)
	local tail = string.sub(text, tail_start)
	local gone = string.sub(text, head_end + 1, tail_start - 1)
	local _, lines = string.gsub(gone, "\n", "")
	local narrow =
		`${id} | where COL = VALUE, ${id} | select COL,... or ${id} | get PATH narrows it`
	return `{head}… {lines} lines ({#gone} bytes) left out; {narrow} …\n{tail}`, true
end

-- Waits up to `seconds` for `block` to finish; whether it did.
local function wait(block: Block, seconds: number): boolean
	if block.status ~= "running" then
		return true
	elseif seconds <= 0 then
		return false
	end
	local woke = greed.signal()
	greed.spawn(function()
		block.done:wait()
		woke:send(true)
	end)
	greed.spawn(function()
		greed.sleep(seconds * 1000)
		woke:send(false)
	end)
	return woke:wait()
end

return function(shells: Shells)
	-- Asked for each time, as the agent plugin may have been loaded again.
	local agent = require("@agent")
	local object = agent.schema.object

	-- `block` as data for `caller`: with what it printed when `output`,
	-- cut to the option's size, and marked as untrusted unless the call
	-- came from a shell (`greed ctl`) rather than a model.
	local function describe(block: Block, caller: any, output: boolean): { [string]: any }
		local record = shells.record(block)
		local finished = block.finished or greed.now()
		local trusted = agent.from_shell(caller)
		local out: { [string]: any } = {
			id = block.uid,
			command = block.command,
			by = block.by,
			cwd = block.cwd,
			status = block.status,
			exit_code = block.code,
			signal = block.signal,
			duration_ms = math.floor(finished - block.started),
			truncated = block.truncated,
			cwd_after = block.cwd_after,
			env_changed = block.env_changed,
		}
		local refs = {}
		local found: { state.Ref } = block.refs or {}
		for _, ref in found do
			table.insert(refs, {
				path = ref.path,
				line = ref.line,
				col = ref.col,
				text = if trusted then ref.text else nil,
			})
		end
		out.refs = greed.json.array(refs)
		if not output then
			return out
		end
		local max = greed.option.get("shell-agent-max-output") :: number
		for _, name in { "stdout", "stderr" } do
			local text, was_cut = cut(record[name] or "", max, block.uid)
			out.truncated = out.truncated or was_cut
			if trusted or text == "" then
				out[name] = text
			else
				out[name] = agent.untrusted(`what \`{block.command}\` printed on {name}`, text)
			end
		end
		local value = block.value
		if value ~= nil then
			-- The value is the output's, so a model gets its shape; stdout
			-- has the text.
			if trusted then
				out.json = value
			else
				local count = 0
				for _ in value do
					count += 1
				end
				out.json =
					{ kind = if #value > 0 or count == 0 then "array" else "object", count = count }
			end
		end
		local tbl = block.table
		if tbl then
			-- Its columns and first rows; `$N | where ...` reaches the rest.
			-- They come from the output, so a model gets them marked.
			local rows = {}
			for i = 1, math.min(#tbl.rows, TABLE_ROWS) do
				rows[i] = tbl.rows[i]
			end
			local columns = greed.json.array(table.clone(tbl.columns))
			out.table = { total = #tbl.rows, shown = #rows }
			if trusted then
				out.table.columns = columns
				out.table.rows = greed.json.array(rows)
			else
				out.table.rows = agent.untrusted(
					`the table \`{block.command}\` printed, its columns and first rows`,
					greed.json.encode({ columns = columns, rows = greed.json.array(rows) })
				)
			end
		end
		return out
	end

	-- The block `args.id` names, or an error saying there's none.
	local function named(args: { [string]: any }): Block
		local _, block = state.find(tonumber(args.id))
		if block == nil then
			error(`there's no block {args.id}; shell_read with last shows the latest`, 0)
		end
		return block
	end

	agent.group(
		"shell",
		"Running commands in the project's shell and reading what they printed, as data"
	)

	agent.tool({
		name = "shell_run",
		group = "shell",
		kind = "execute",
		description = "Run a command line in the project's shell (sh syntax; the user sees it there), from the "
			.. "project's root or `cwd`, with its input closed, and get back how it ended and what it "
			.. "printed: id, status, exit_code, stdout, stderr (each cut to whole lines at its start "
			.. "and end when long), duration_ms, cwd_after and env_changed (cd and export don't carry "
			.. "over to the next run), refs (file:line places the output names), json (when stdout is "
			.. "JSON) and table (its columns, first 50 rows and total, when it's a table like kubectl "
			.. "get prints). `$ID` in a later command is block ID's output: `$ID | where COL = VALUE`, "
			.. "`$ID | select A,B`, `$ID | sort COL` and `$ID | get items.0.name` (JSON) work on it, "
			.. "and after a command's first word `$ID` is a file holding it (`diff $ID1 $ID2`). "
			.. 'After `timeout_s` (default 60) it returns status "running" and the id, for shell_wait',
		input = object({
			command = { type = "string", description = "The command line to run" },
			cwd = { type = "string", description = "The folder to run in, from the project's root" },
			timeout_s = { type = "number" },
			env = {
				type = "object",
				description = "Variables to set for it, NAME to value",
				additionalProperties = { type = "string" },
			},
		}, { "command" }),
		danger = function(args)
			return if type(args.command) == "string" then core.risk.of(args.command) else nil
		end,
		run = function(args, caller)
			if type(args.command) ~= "string" then
				error("shell_run needs command, the command line to run", 0)
			end
			local shell = shells.project()
			local root = greed.project.current().root
			local env = table.clone(shell.env)
			if type(args.env) == "table" then
				for name, value in args.env do
					env[tostring(name)] = tostring(value)
				end
			end
			local cwd = core.project.resolve(args.cwd or ".", root)
			local info = greed.fs.stat(cwd)
			if info == nil or info.kind ~= "dir" then
				error(`no such folder: {args.cwd}`, 0)
			end
			local block = shells.run(shell, args.command, {
				by = "agent",
				runner = "pipe",
				cwd = core.project.clean(cwd),
				env = env,
			})
			if block == nil then
				error("there's no command to run", 0)
			end
			wait(block, tonumber(args.timeout_s) or DEFAULT_TIMEOUT)
			return describe(block, caller, true)
		end,
	})

	agent.tool({
		name = "shell_read",
		group = "shell",
		description = "A block of the project's shells, run by the user or an agent: by `id`, or with `last` "
			.. "the latest; with what it printed unless `include_output` is false",
		input = object({
			id = { type = "number" },
			last = { type = "boolean" },
			include_output = { type = "boolean" },
		}),
		run = function(args, caller)
			local block: Block? = nil
			if args.id ~= nil then
				block = named(args)
			elseif args.last then
				for _, shell in state.list(greed.project.current().id) do
					for _, b in shell.blocks do
						if block == nil or b.uid > (block :: Block).uid then
							block = b
						end
					end
				end
			else
				error("give an id, or last = true", 0)
			end
			if block == nil then
				error("nothing has run in this project's shells", 0)
			end
			return describe(block, caller, args.include_output ~= false)
		end,
	})

	agent.tool({
		name = "shell_wait",
		group = "shell",
		description = "Wait up to `timeout_s` seconds for a block shell_run left running, and get it back as "
			.. "shell_run gives it",
		input = object({ id = { type = "number" }, timeout_s = { type = "number" } }, { "id" }),
		run = function(args, caller)
			local block = named(args)
			wait(block, tonumber(args.timeout_s) or DEFAULT_TIMEOUT)
			return describe(block, caller, true)
		end,
	})

	agent.tool({
		name = "shell_kill",
		group = "shell",
		kind = "execute",
		description = "Stop a block an agent ran that's still running, and get it back as shell_run gives it",
		input = object({ id = { type = "number" } }, { "id" }),
		run = function(args, caller)
			local block = named(args)
			if block.by ~= "agent" then
				error("only a block an agent ran can be stopped this way", 0)
			end
			-- KILL reaches its whole process group, so it ends.
			if shells.kill(block) then
				shells.wait(block)
			end
			return describe(block, caller, true)
		end,
	})

	agent.tool({
		name = "shell_edit",
		shell_only = true,
		description = "Show files to edit, for a program run from a shell (greed edit): in the view "
			.. "where block `block` ran, and with `wait` until each is done with (:q or :wq). "
			.. 'Gives back "done", or "aborted" when :cq stopped one',
		input = object({
			paths = {
				type = "array",
				items = { type = "string" },
				description = "The files, as absolute paths",
			},
			block = { type = "number", description = "The block asking, $GREED_BLOCK" },
			wait = { type = "boolean" },
		}, { "paths" }),
		run = function(args)
			local paths: { string } = {}
			for _, path in args.paths do
				table.insert(paths, tostring(path))
			end
			return edit.open(paths, { block = tonumber(args.block), wait = args.wait == true })
		end,
	})
end
