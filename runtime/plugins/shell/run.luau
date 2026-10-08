-- Running blocks: the shell's own builtins, and programs through a pipe
-- with their output and errors apart (agents and data use this, and typed
-- commands until the pseudo terminal runner is in). What they print goes
-- into the block's record as it comes, and into the buffer a frame at a
-- time.

local greed = require("@greed")
local core = require("@core")
local parse = require("./parse")
local state = require("./state")
local log = require("./log")

type Shell = state.Shell
type Block = state.Block
type Line = log.Line

local M = {}

greed.option.define({
	name = "shell-max-record",
	doc = "How many bytes of a block's output its record keeps; the rest goes to a file in the cache folder",
	default = 8 * 1024 * 1024,
})

-- How long output waits to be drawn, so a fast program's lines are drawn a
-- frame's worth at a time.
local FRAME_MS = 16

-- What a running block printed and hasn't been drawn yet, and its record
-- as pieces until it's done.
type Pending = {
	-- Pieces not drawn yet, and those of the line being printed.
	pieces: { { text: string, stream: string } },
	partial: { { text: string, stream: string } },
	drawing: boolean,
	-- The record, in pieces, each kind up to the limit, and past it the
	-- whole output for the spill file.
	output: { string },
	stdout: { string },
	stderr: { string },
	sizes: { [string]: number },
	spill: { string }?,
}

local pending: { [number]: Pending } = {}

local function pending_of(block: Block): Pending
	local found = pending[block.uid]
	if found then
		return found
	end
	local p: Pending = {
		pieces = {},
		partial = {},
		drawing = false,
		output = {},
		stdout = {},
		stderr = {},
		sizes = { output = 0, stdout = 0, stderr = 0 },
		spill = nil,
	}
	pending[block.uid] = p
	return p
end

-- Adds `text` to the record's `kind` ("output", "stdout" or "stderr") up
-- to the limit.
local function keep(p: Pending, block: Block, kind: string, text: string)
	local limit = greed.option.get("shell-max-record") :: number
	local size = p.sizes[kind]
	local list: { string } = (p :: any)[kind]
	if size + #text <= limit then
		table.insert(list, text)
	else
		if size < limit then
			table.insert(list, string.sub(text, 1, limit - size))
		end
		block.truncated = true
	end
	p.sizes[kind] = size + #text
end

--- Adds what `block` printed on `stream` ("stdout" or "stderr") to its
--- record, without drawing it.
function M.record(block: Block, text: string, stream: string)
	local p = pending_of(block)
	local spilled = p.spill
	if spilled then
		table.insert(spilled, text)
	elseif p.sizes.output + #text > (greed.option.get("shell-max-record") :: number) then
		p.spill = { table.concat(p.output), text }
	end
	keep(p, block, "output", text)
	keep(p, block, if stream == "stderr" then "stderr" else "stdout", text)
end

--- The record so far: `block.output`, `stdout` and `stderr` are filled in
--- from what came, for a block still running.
function M.fill(block: Block)
	local p = pending[block.uid]
	if p then
		block.output = table.concat(p.output)
		block.stdout = table.concat(p.stdout)
		block.stderr = table.concat(p.stderr)
	end
end

-- Escape sequences a program printed for a terminal, left out of text.
local function plain(text: string): string
	text = string.gsub(text, "\27%][^\7\27]*\7", "")
	text = string.gsub(text, "\27%][^\7\27]*\27\\", "")
	text = string.gsub(text, "\27%[[%d;?]*[%a@]", "")
	return text
end

-- A line made of `pieces`, with what came on stderr styled as errors. A
-- carriage return starts the line over, as on a terminal.
local function line_of(pieces: { { text: string, stream: string } }): Line
	local parts: { string } = {}
	local marks: { greed.Mark } = {}
	local at = 0
	local errors = false
	for _, piece in pieces do
		local text = plain(piece.text)
		if piece.stream == "stderr" and text ~= "" then
			errors = true
			table.insert(marks, { from = at, to = at + #text, style = "shell.stderr" })
		end
		table.insert(parts, text)
		at += #text
	end
	local text = table.concat(parts)
	text = string.gsub(text, "\r$", "")
	if string.find(text, "\r", 1, true) then
		text = string.match(text, "\r([^\r]*)$") or text
		marks = {}
		if errors then
			table.insert(marks, { from = 0, to = #text, style = "shell.stderr" })
		end
	end
	return { text = text, marks = marks }
end

-- Draws what `block` printed since last time: whole lines join the
-- output, and the line being printed shows until it's done (or, with
-- `final`, for good).
local function draw(shell: Shell, block: Block, final: boolean)
	local p = pending[block.uid]
	if p == nil then
		return
	end
	local lines: { Line } = {}
	local current = p.partial
	for _, piece in p.pieces do
		local start = 1
		while true do
			local stop = string.find(piece.text, "\n", start, true)
			if stop == nil then
				if start <= #piece.text then
					table.insert(
						current,
						{ text = string.sub(piece.text, start), stream = piece.stream }
					)
				end
				break
			end
			if stop > start then
				table.insert(
					current,
					{ text = string.sub(piece.text, start, stop - 1), stream = piece.stream }
				)
			end
			table.insert(lines, line_of(current))
			current = {}
			start = stop + 1
		end
	end
	p.pieces = {}
	p.partial = current
	local volatile: { Line } = {}
	if #current > 0 then
		if final then
			table.insert(lines, line_of(current))
			p.partial = {}
		else
			table.insert(volatile, line_of(current))
		end
	end
	log.update(shell, block, lines, volatile)
end

--- Adds what `block` printed to its record, and draws it soon.
function M.write(shell: Shell, block: Block, text: string, stream: string)
	M.record(block, text, stream)
	local p = pending_of(block)
	table.insert(p.pieces, { text = text, stream = stream })
	if p.drawing then
		return
	end
	p.drawing = true
	greed.spawn(function()
		greed.sleep(FRAME_MS)
		p.drawing = false
		if block.status == "running" then
			draw(shell, block, false)
		end
	end)
end

--- Draws everything `block` printed, for good.
function M.flush(shell: Shell, block: Block)
	draw(shell, block, true)
end

-- Called with each block that finishes.
local finished: { (shell: Shell, block: Block) -> () } = {}

--- Calls `call` with each block that finishes from now on, until the
--- plugin that asked goes.
function M.on_finish(call: (shell: Shell, block: Block) -> ())
	greed.plugin.tie(core.registry.put(finished, call))
end

-- Writes the whole output of a block that went past the record's limit
-- to a file in the cache folder.
local function spill(block: Block, p: Pending)
	local whole = p.spill
	if whole == nil then
		return
	end
	local cache = greed.fs.dirs().cache
	if cache == nil then
		return
	end
	local path = `{cache}/shell/{block.time}-{block.uid}.log`
	if greed.fs.write(path, table.concat(whole)) then
		block.spill = path
	end
end

--- Ends `block`: how it exited (a code, or the signal that ended it),
--- with what it printed drawn for good.
function M.finish(shell: Shell, block: Block, code: number?, signal: string?)
	if block.status ~= "running" then
		return
	end
	M.flush(shell, block)
	local p = pending[block.uid]
	if p then
		M.fill(block)
		spill(block, p)
		pending[block.uid] = nil
	end
	block.finished = greed.now()
	block.code = code
	block.signal = signal
	block.job = nil
	block.status = if signal
		then "killed"
		elseif code == 0 then "done"
		elseif code == nil then "error"
		else "failed"
	log.draw_block(shell, block)
	for _, call in table.clone(finished) do
		pcall(call, shell, block)
	end
	block.done:send(block)
end

--- Ends `block` as one that couldn't run, saying why.
function M.fail(shell: Shell, block: Block, message: string, code: number?)
	M.write(shell, block, message .. "\n", "stderr")
	M.finish(shell, block, code or 127, nil)
end

--- Runs `argv` for `block` through a pipe: no terminal, its output and
--- errors apart, in a process group of its own so an interrupt reaches
--- what it starts. Its input is closed.
function M.pipe(shell: Shell, block: Block, argv: { string })
	local child, err = greed.process.spawn(argv, {
		cwd = block.cwd,
		env = state.environment(block.env),
		stderr = "stream",
		group = true,
	})
	if child == nil then
		M.fail(shell, block, err or `can't start {argv[1]}`)
		return
	end
	local c = child :: greed.Child
	c:close()
	local stopped: string? = nil
	block.job = {
		interrupt = function()
			stopped = "INT"
			c:signal("INT")
		end,
		kill = function()
			stopped = "KILL"
			c:kill()
		end,
	}
	greed.spawn(function()
		while true do
			local piece, from = c:read()
			if piece == nil then
				break
			end
			M.write(shell, block, piece, from or "stdout")
		end
		local code, signal = c:wait()
		M.finish(shell, block, code, signal or (if code == nil then stopped else nil))
	end)
end

--- A program in `argv` named with a relative path, like `./build.sh`, as
--- found from `cwd`.
function M.program(argv: { string }, cwd: string): { string }
	local first = argv[1]
	if string.find(first, "/", 1, true) and string.sub(first, 1, 1) ~= "/" then
		local out = table.clone(argv)
		out[1] = core.project.resolve(first, cwd)
		return out
	end
	return argv
end

--- Lines of `text`, for a builtin's output.
local function say(shell: Shell, block: Block, text: string)
	M.write(shell, block, text .. "\n", "stdout")
end

-- What `cd ARG` goes to from `shell`'s folder: home without one, the one
-- before with `-`.
local function cd_target(shell: Shell, block: Block, arg: string?): (string?, string?)
	local home = greed.fs.dirs().home
	if arg == nil or arg == "" then
		return home, nil
	elseif arg == "-" then
		return shell.oldpwd or block.cwd, nil
	end
	local path = core.project.resolve(arg, block.cwd)
	local info = greed.fs.stat(path)
	if info == nil then
		return nil, `cd: no such folder: {arg}`
	elseif info.kind ~= "dir" then
		return nil, `cd: not a folder: {arg}`
	end
	return path, nil
end

--- Whether a block's builtin changes its shell: the user's own do; an
--- agent's change only what its block says.
local function carries(block: Block): boolean
	return block.by ~= "agent"
end

--- Moves `shell` to `cwd`, for the commands after.
function M.move(shell: Shell, cwd: string)
	if cwd ~= shell.cwd then
		shell.oldpwd = shell.cwd
		shell.cwd = cwd
	end
	log.draw_prompt(shell)
end

--- Sets (a string) or leaves out (false) variables in `shell`, for the
--- commands after.
function M.set_env(shell: Shell, changes: { [string]: string | false })
	for name, value: string | false in changes do
		shell.env[name] = value
	end
end

-- Records `changes` in `block`, and makes them in `shell` when the block's
-- builtins carry over.
local function change_env(shell: Shell, block: Block, changes: { [string]: string | false })
	block.env_changed = changes
	if carries(block) then
		M.set_env(shell, changes)
	end
end

--- The builtins, by name: each runs for `block` with its arguments and
--- returns the exit code. `open` and `history` come from the plugin.
M.builtins = {} :: { [string]: (shell: Shell, block: Block, args: { string }) -> number }

M.builtins.cd = function(shell: Shell, block: Block, args: { string }): number
	if #args > 1 then
		say(shell, block, "cd: one folder at a time")
		return 1
	end
	local target, err = cd_target(shell, block, args[1])
	if target == nil then
		say(shell, block, err or "cd: no home folder")
		return 1
	end
	block.cwd_after = target
	if carries(block) then
		M.move(shell, target)
	end
	return 0
end

M.builtins.export = function(shell: Shell, block: Block, args: { string }): number
	local changes: { [string]: string | false } = {}
	for _, arg in args do
		local name, value = parse.assignment(arg)
		if name == nil or value == nil then
			if parse.valid_name(arg) then
				-- Already in the environment, or nothing to export.
				continue
			end
			say(shell, block, `export: not NAME=VALUE: {arg}`)
			return 1
		end
		changes[name] = value
	end
	change_env(shell, block, changes)
	return 0
end

M.builtins.unset = function(shell: Shell, block: Block, args: { string }): number
	local changes: { [string]: string | false } = {}
	for _, name in args do
		if not parse.valid_name(name) then
			say(shell, block, `unset: not a name: {name}`)
			return 1
		end
		changes[name] = false
	end
	change_env(shell, block, changes)
	return 0
end

M.builtins.env = function(shell: Shell, block: Block, args: { string }): number
	if #args > 0 then
		say(shell, block, "env: lists this shell's variables; run /usr/bin/env for a program's")
		return 2
	end
	local names: { string } = {}
	for name in shell.env do
		table.insert(names, name)
	end
	table.sort(names)
	if #names == 0 then
		say(shell, block, "(no variables set here; programs get the editor's)")
	end
	for _, name in names do
		local value = shell.env[name]
		say(shell, block, if value == false then `-{name}` else `{name}={value}`)
	end
	return 0
end

--- Runs builtin `name` for `block`.
function M.builtin(shell: Shell, block: Block, name: string, args: { string })
	local run = M.builtins[name]
	if run == nil then
		M.fail(shell, block, `{name}: no such builtin`, 127)
		return
	end
	local ok, result = pcall(run, shell, block, args)
	if not ok then
		M.fail(shell, block, `{name}: {result}`, 1)
		return
	end
	M.finish(shell, block, result :: number, nil)
end

return M
