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
local tables = require("./tables")
local jc = require("./jc")

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

type Piece = { text: string, stream: string }

-- What a running block printed and hasn't been drawn yet, and its record
-- as pieces until it's done.
type Pending = {
	-- Pieces not drawn yet, and those of the line being printed.
	pieces: { Piece },
	partial: { Piece },
	-- Whether a draw is due, under way, and whether more came in meanwhile.
	due: boolean,
	drawing: boolean,
	stale: boolean,
	-- How it exited, once it did: it finishes after the last draw.
	exit: { code: number?, signal: string?, status: string? }?,
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
		due = false,
		drawing = false,
		stale = false,
		exit = nil,
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
-- to `limit` bytes.
local function keep(p: Pending, block: Block, kind: string, text: string, limit: number)
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
	local limit = greed.option.get("shell-max-record") :: number
	local spilled = p.spill
	if spilled then
		table.insert(spilled, text)
	elseif p.sizes.output + #text > limit then
		p.spill = { table.concat(p.output), text }
	end
	keep(p, block, "output", text, limit)
	keep(p, block, if stream == "stderr" then "stderr" else "stdout", text, limit)
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
local function line_of(pieces: { Piece }): Line
	if
		#pieces == 1
		and pieces[1].stream ~= "stderr"
		and not string.find(pieces[1].text, "[\r\27]")
	then
		return { text = pieces[1].text }
	end
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
-- `final`, for good). Lines the block would leave out anyway aren't made
-- into lines at all, so a flood of output costs little more than its
-- record. Output sent to a buffer (`> buf:NAME`) goes there instead.
local function draw(shell: Shell, block: Block, final: boolean)
	local p = pending[block.uid]
	if p == nil then
		return
	end
	local pieces = p.pieces
	p.pieces = {}
	local target = block.target
	if target then
		local sent: { string } = {}
		local kept: { Piece } = {}
		for _, piece in pieces do
			if piece.stream == "stdout" then
				table.insert(sent, piece.text)
			else
				table.insert(kept, piece)
			end
		end
		pieces = kept
		if #sent > 0 and target:valid() then
			target:edit(function(e)
				e:insert(target:len(), table.concat(sent))
			end)
		end
	end
	-- Each whole line: its pieces, or for the many made of one piece, that
	-- piece's text and stream.
	local texts: { string } = {}
	local streams: { string } = {}
	local joined: { [number]: { Piece } } = {}
	local current = p.partial
	local function close(text: string, stream: string)
		if #current == 0 then
			table.insert(texts, text)
			table.insert(streams, stream)
			return
		end
		if text ~= "" then
			table.insert(current, { text = text, stream = stream })
		end
		table.insert(texts, "")
		table.insert(streams, "")
		joined[#texts] = current
		current = {}
	end
	for _, piece in pieces do
		local parts = string.split(piece.text, "\n")
		for i, part in parts do
			if i < #parts then
				close(part, piece.stream)
			elseif part ~= "" then
				table.insert(current, { text = part, stream = piece.stream })
			end
		end
	end
	if final and #current > 0 then
		close("", "stdout")
	end
	p.partial = current
	local count = #texts
	local fill, skip = log.room(block, count)
	local lines: { Line } = {}
	for i = 1, count do
		if i <= fill or i > fill + skip then
			table.insert(lines, line_of(joined[i] or { { text = texts[i], stream = streams[i] } }))
		end
	end
	local volatile: { Line } = if #current > 0 then { line_of(current) } else {}
	log.update(shell, block, lines, volatile, skip)
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

-- Asks jc, when it's installed, for a table in what `block` printed, and
-- shows it has one if jc found it.
local function from_jc(shell: Shell, block: Block)
	greed.spawn(function()
		local own = block.env.PATH
		local path = if type(own) == "string"
			then own
			elseif own == false then nil
			else state.editor_environment().PATH
		local found = jc.parse(plain(block.stdout), block.command, path)
		if found and block.table == nil then
			block.table = found
			log.draw_block(shell, block)
		end
	end)
end

-- What `block`, done printing, gives besides its text: the file its whole
-- output went to when the record couldn't hold it, its value, its table
-- and the references in it.
local function read_output(shell: Shell, block: Block, p: Pending?)
	if p then
		spill(block, p)
	end
	if not block.truncated then
		block.value = tables.json(block.stdout) or block.data
		-- A stage's block has its table already; a table some lines of
		-- which aren't shown is left alone.
		if block.table == nil and block.omitted == 0 then
			block.table = tables.drawn(block.data, plain(block.stdout))
				or tables.from_value(block.value)
				or tables.parse(plain(block.stdout), block.command, block)
			if block.table == nil and block.stdout ~= "" then
				from_jc(shell, block)
			end
		end
	end
	block.refs = log.draw_refs(shell, block)
end

-- Ends `block`, whose output is all drawn: as `status` says, or as how it
-- exited says.
local function complete(shell: Shell, block: Block, code: number?, signal: string?, status: string?)
	local p = pending[block.uid]
	if p then
		M.fill(block)
		pending[block.uid] = nil
	end
	-- Reading what it printed is the shell's own work, whichever plugin's
	-- line it was, and its failing still ends the block.
	xpcall(greed.vouch, function(err)
		greed.echo(`shell: {err}`)
	end, read_output, shell, block, p)
	block.finished = greed.now()
	block.code = code
	block.signal = signal
	block.job = nil
	block.status = if status
		then status
		elseif signal then "killed"
		elseif code == 0 then "done"
		elseif code == nil then "error"
		else "failed"
	log.draw_block(shell, block)
	core.registry.tell(finished, shell, block)
	block.done:send(block)
end

--- Finishes `block` once its program exited, telling `before` how first.
--- `before` failing doesn't keep the block running.
function M.exited(
	shell: Shell,
	block: Block,
	code: number?,
	signal: string?,
	before: ((code: number?, signal: string?) -> ())?
)
	if before then
		core.registry.tell({ before }, code, signal)
	end
	M.finish(shell, block, code, signal)
end

-- Draws `block` until nothing more came in meanwhile, and ends it once it
-- exited. A draw's time slice can run out partway and another start on the
-- half-drawn block; that one leaves it to the first.
local function pump(shell: Shell, block: Block)
	local p = pending[block.uid]
	if p == nil then
		return
	end
	if p.drawing then
		p.stale = true
		return
	end
	p.drawing = true
	local ok, err = pcall(function()
		repeat
			p.stale = false
			draw(shell, block, p.exit ~= nil)
		until not p.stale
	end)
	p.drawing = false
	if not ok then
		error(err, 0)
	end
	local exit = p.exit
	if exit and block.status == "running" then
		complete(shell, block, exit.code, exit.signal, exit.status)
	end
end

--- Adds what `block` printed to its record, and draws it soon.
function M.write(shell: Shell, block: Block, text: string, stream: string)
	M.record(block, text, stream)
	local p = pending_of(block)
	table.insert(p.pieces, { text = text, stream = stream })
	if p.due then
		return
	end
	p.due = true
	greed.spawn(function()
		greed.sleep(FRAME_MS)
		p.due = false
		if block.status == "running" then
			pump(shell, block)
		end
	end)
end

--- Ends `block`: how it exited (a code, or the signal that ended it),
--- once what it printed is drawn for good. `status` says how it ended in
--- place of the code, like "asked" for a question to a model.
function M.finish(shell: Shell, block: Block, code: number?, signal: string?, status: string?)
	if block.status ~= "running" then
		return
	end
	local p = pending[block.uid]
	if p == nil then
		complete(shell, block, code, signal, status)
		return
	end
	p.exit = { code = code, signal = signal, status = status }
	pump(shell, block)
end

--- Ends `block` as one that couldn't run, saying why.
function M.fail(shell: Shell, block: Block, message: string, code: number?)
	M.write(shell, block, message .. "\n", "stderr")
	M.finish(shell, block, code or 127, nil)
end

--- Ends `block`, a question to a model that brought no command back,
--- saying why. Nothing ran, so it has no exit code: it ends as "asked".
function M.unanswered(shell: Shell, block: Block, message: string)
	M.write(shell, block, message .. "\n", "stderr")
	M.finish(shell, block, nil, nil, "asked")
end

--- Runs `argv` for `block` through a pipe: no terminal, its output and
--- errors apart, in a process group of its own so an interrupt reaches
--- what it starts. It reads `input`, if given, and then its input is
--- closed. `before` hears how it exited before the block finishes.
function M.pipe(
	shell: Shell,
	block: Block,
	argv: { string },
	before: ((code: number?, signal: string?) -> ())?,
	input: string?
)
	local child, err = greed.process.spawn(argv, {
		cwd = block.cwd,
		env = state.environment(block),
		stderr = "stream",
		group = true,
	})
	if child == nil then
		M.fail(shell, block, err or `can't start {argv[1]}`)
		return
	end
	local c = child :: greed.Child
	if input and input ~= "" then
		c:write(input)
	end
	c:close()
	local stopped: string? = nil
	state.give_job(block, {
		interrupt = function()
			stopped = "INT"
			c:signal("INT")
		end,
		kill = function()
			stopped = "KILL"
			c:kill()
		end,
	})
	greed.spawn(function()
		while true do
			local piece, from = c:read()
			if piece == nil then
				break
			end
			M.write(shell, block, piece, from or "stdout")
		end
		local code, signal = c:wait()
		signal = signal or (if code == nil then stopped else nil)
		M.exited(shell, block, code, signal, before)
	end)
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
	-- A builtin that waits can't be cut short, so stopping it ends its block
	-- at once; what it does after goes nowhere.
	local function stop(signal: string)
		return function()
			M.finish(shell, block, nil, signal)
		end
	end
	state.give_job(block, { interrupt = stop("INT"), kill = stop("KILL") })
	if block.status ~= "running" then
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
