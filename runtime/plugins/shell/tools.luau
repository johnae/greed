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

type Shell = state.Shell
type Block = state.Block

greed.option.define({
	name = "shell-agent-max-output",
	doc = "How many bytes of a command's output and of its errors the shell tools give an agent: the start and the end, with what's between left out",
	default = 30000,
})

-- How long shell_run waits for a command before saying it's still running,
-- in seconds.
local DEFAULT_TIMEOUT = 60

-- What the tools need from the plugin, which loads them after it's set up.
export type Shells = {
	open: (options: any) -> Shell,
	run: (shell: Shell, line: string, options: any) -> Block?,
	kill: (block: Block) -> boolean,
	wait: (block: Block) -> Block,
	record: (block: Block) -> { [string]: any },
}

-- `text` cut to its first and last `max` / 2 bytes, on character
-- boundaries, saying how much was left out; and whether it was cut.
local function cut(text: string, max: number): (string, boolean)
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
	local head_end = boundary(max // 2 + 1) - 1
	local tail_start = boundary(#text - max // 2 + 1)
	local head = string.sub(text, 1, head_end)
	local tail = string.sub(text, tail_start)
	return `{head}\n… {tail_start - head_end - 1} bytes left out …\n{tail}`, true
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

-- The block with id `id` in any shell.
local function by_id(id: number): Block?
	for _, shell in state.list() do
		for _, block in shell.blocks do
			if block.uid == id then
				return block
			end
		end
	end
	return nil
end

return function(shells: Shells)
	-- Asked for each time, as the agent plugin may have been loaded again.
	local agent = require("@agent")
	local object = agent.schema.object

	-- The project's first shell, opened without showing it if there's none.
	local function project_shell(): Shell
		local project = greed.project.current()
		local found = state.list(project.id)[1]
		if found then
			return found
		end
		return shells.open({ cwd = project.root, show = false })
	end

	-- `block` as data for `caller`: with what it printed when `output`,
	-- cut to the option's size, and marked as untrusted unless the call
	-- came from a shell (`greed ctl`) rather than a model.
	local function describe(block: Block, caller: any, output: boolean): { [string]: any }
		local record = shells.record(block)
		local finished = block.finished or greed.now()
		local trusted = agent.from_shell(caller)
		local out: { [string]: any } = {
			id = block.uid,
			number = block.number,
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
			local text, was_cut = cut(record[name] or "", max)
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
			-- Its shape, for `$N | where ...`; the names come from the output.
			out.table = {
				rows = #tbl.rows,
				columns = if trusted
					then greed.json.array(table.clone(tbl.columns))
					else #tbl.columns,
			}
		end
		return out
	end

	-- The block `args.id` names, or an error saying there's none.
	local function named(args: { [string]: any }): Block
		local block = by_id(tonumber(args.id) or -1)
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
			.. "printed: id, status, exit_code, stdout, stderr (each cut to its start and end when long), "
			.. "duration_ms, cwd_after and env_changed (cd and export don't carry over to the next run), "
			.. "refs (file:line places the output names), json (when stdout is JSON) and table (its "
			.. "rows and columns, when it's a table like kubectl get prints; `$N | where COL = VALUE`, "
			.. "`$N | select A,B` and `$N | sort COL` work on block N's table). After "
			.. '`timeout_s` (default 60) it returns status "running" and the id, for shell_wait',
		input = object({
			command = { type = "string" },
			cwd = { type = "string", description = "The folder to run in, from the project's root" },
			timeout_s = { type = "number" },
			env = {
				type = "object",
				description = "Variables to set for it, NAME to value",
				additionalProperties = { type = "string" },
			},
		}, { "command" }),
		run = function(args, caller)
			local shell = project_shell()
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
			local block = shells.run(shell, tostring(args.command), {
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
end
