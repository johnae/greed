-- Runnable blocks in Markdown: a fenced block whose language has a runner
-- (```` ```sh ````, ```` ```python ````, ```` ```luau ````, ```` ```http ````)
-- runs when you ask, and its output is saved in a `result` block right
-- under it, so the file shows it anywhere and a diff shows what changed.
-- Running it again replaces the result.
--
--   space m r   run the block under the cursor (enter on its fence too)
--   space m R   run every block in the file, in order
--   space m c   clear the block's result; :blocks-results-clear for all
--   space m s   stop the block running under the cursor
--
-- Nothing runs when a file opens. The first time you run a block in a file
-- Greed asks whether to: y for now, a to always trust that file. Files you
-- trust, and those whose front matter says `greed: run`, show a run button
-- on each block.
--
-- Options go in the info string: `id=NAME` names a block's result, and
-- `input=NAME` gives another block that result (on stdin, or as `input` in
-- Luau), running the named block first if it has no result yet. `dir=PATH`
-- runs a program elsewhere than the file's folder, and `timeout=SECONDS`
-- stops it after that long. Add a language from Luau:
--
--     require("@blocks").runner("lua", require("@blocks").program({ "lua", "-e" }))

local greed = require("@greed")
local core = require("@core")
local parse = require("@self/parse")
local runners = require("@self/runners")

type Block = parse.Block

local M = {}

--- Makes blocks in a language run, e.g.
--- `runner("lua", program({ "lua", "-e" }))`; see runners.luau.
M.runner = runners.add
--- A runner for a program taking code as its last argument.
M.program = runners.program
M.runners = runners
M.parse = parse

greed.option.define({
	name = "blocks-max-lines",
	doc = "The most lines of output a block's result keeps; the rest is cut",
	default = 1000,
})

-- Trust: the files whose blocks may run, kept one path a line in the data
-- folder, and those allowed until the editor quits.
local data = greed.fs.dirs().data
local trust_file = data and `{data}/blocks-trusted`
local trusted: { [string]: boolean } = {}
local allowed_now: { [string]: boolean } = {}

local function load_trusted()
	local text = trust_file and greed.fs.read(trust_file)
	for path in string.gmatch(text or "", "[^\n]+") do
		trusted[path] = true
	end
end
load_trusted()

local function save_trusted()
	if trust_file == nil then
		return
	end
	local paths = {}
	for path in trusted do
		table.insert(paths, path)
	end
	table.sort(paths)
	greed.fs.write(trust_file, table.concat(paths, "\n") .. "\n")
end

-- The buffer's file as an absolute path, if it has one.
local function path_of(buffer: greed.Buffer): string?
	local ok, path = pcall(buffer.path, buffer)
	if not ok or path == nil then
		return nil
	end
	return if string.sub(path, 1, 1) == "/" then path else `{greed.fs.cwd()}/{path}`
end

--- Whether blocks in `buffer` may run without asking: its file is trusted
--- or allowed for now, or it has no file (you wrote it here).
function M.trusted(buffer: greed.Buffer): boolean
	local path = path_of(buffer)
	return path == nil or trusted[path] == true or allowed_now[path] == true
end

--- Whether `buffer` shows its blocks as runnable: Markdown whose front
--- matter says `greed: run`, or a file you trusted.
function M.on(buffer: greed.Buffer): boolean
	local ok, language = pcall(buffer.language, buffer)
	if not ok or language ~= "markdown" then
		return false
	end
	local wants = parse.front_matter(buffer)
	if wants and string.find(wants, "%f[%w]run%f[^%w]") then
		return true
	end
	local path = path_of(buffer)
	return path ~= nil and (trusted[path] or allowed_now[path]) == true
end

core.features.add("blocks", M.on, "blocks")

-- Runs in progress, each with a decoration namespace of its own holding a
-- mark on its block's fence: the mark moves with edits, so the result goes
-- under the block wherever it is by the time it's done.
type Running = { buffer: greed.Buffer, ns: string, child: greed.Child?, stopped: boolean }
local running: { Running } = {}
local runs = 0

-- Where a run's block starts now, if its mark is still there.
local function where(run: Running): number?
	local ok, marks = pcall(run.buffer.decorations, run.buffer, run.ns)
	return if ok and marks[1] then marks[1].from else nil
end

local draw: (buffer: greed.Buffer) -> ()

-- Shows `text` after the fence of the block `run` is running.
local function show(run: Running, from: number, text: string)
	local mark: greed.Mark = {
		from = from,
		to = run.buffer:line_end(run.buffer:line_of(from)),
		style = "blocks.running",
		text = text,
		eol = true,
		action = "block-stop",
	}
	pcall(run.buffer.decorate, run.buffer, run.ns, { mark })
end

-- Takes `run` off the running list, along with its mark.
local function finish(run: Running)
	pcall(run.buffer.decorate, run.buffer, run.ns, {})
	table.remove(running, table.find(running, run) :: number)
end

-- The block at `pos` in `buffer`: the one whose fences or code it's in, or
-- whose result.
local function block_at(buffer: greed.Buffer, pos: number): Block?
	for _, block in parse.blocks(buffer) do
		local last = if block.result then block.result.to else block.to
		if pos >= block.from and pos <= last then
			return block
		end
	end
	return nil
end

-- The block named `id` in `buffer`.
local function named(buffer: greed.Buffer, id: string): Block?
	for _, block in parse.blocks(buffer) do
		if block.opts.id == id then
			return block
		end
	end
	return nil
end

-- The result block's text for `outcome`: the output, cut to the
-- `blocks-max-lines` option, in a fence longer than any it holds.
local function result_text(outcome: runners.Outcome): string
	local body = if outcome.error then `error: {outcome.error}` else outcome.output
	body = string.gsub(string.gsub(body, "\r\n", "\n"), "\n+$", "")
	local max = greed.option.get("blocks-max-lines") :: number
	local lines = string.split(body, "\n")
	if #lines > max then
		body = table.concat(lines, "\n", 1, max) .. `\n… {#lines - max} more lines`
	end
	local longest = 0
	for ticks in string.gmatch(body, "`+") do
		longest = math.max(longest, #ticks)
	end
	local fence = string.rep("`", math.max(3, longest + 1))
	local info = "result"
	if outcome.exit and outcome.exit ~= 0 then
		info ..= ` exit={outcome.exit}`
	elseif outcome.error then
		info ..= " error"
	end
	return `\n\n{fence}{info}\n{body}{if body == "" then "" else "\n"}{fence}`
end

-- Saves `outcome` as the result of `block`, replacing the one it had.
local function save(buffer: greed.Buffer, block: Block, outcome: runners.Outcome)
	local text = result_text(outcome)
	-- After the closing fence's line break when there is one, so a cursor
	-- at the fence's end stays there rather than going after the result.
	local from = block.to
	if buffer:slice(block.to, math.min(block.to + 1, buffer:len())) == "\n" then
		from += 1
		text = string.sub(text, 2) .. if block.result then "" else "\n"
	end
	buffer:edit(function(e)
		local result = block.result
		if result then
			e:replace(from, result.to, text)
		else
			e:insert(from, text)
		end
	end)
end

-- The folder a block runs in: its `dir` option (from the file's folder),
-- or the file's folder, or the editor's.
local function dir_for(buffer: greed.Buffer, block: Block): string
	local path = path_of(buffer)
	local base = if path then string.match(path, "^(.*)/[^/]*$") or "/" else greed.fs.cwd()
	local dir = block.opts.dir
	if dir == nil then
		return base
	end
	return if string.sub(dir, 1, 1) == "/" then dir else `{base}/{dir}`
end

local run_block: (buffer: greed.Buffer, block: Block, chain: { [string]: boolean }) -> boolean

-- The input for `block`: the result of the block its `input` option
-- names, running that first if it has none. Nil and why when it can't.
local function input_for(
	buffer: greed.Buffer,
	block: Block,
	chain: { [string]: boolean }
): (string?, string?)
	local id = block.opts.input
	if id == nil then
		return nil, nil
	end
	if chain[id] then
		return nil, `blocks {id} and its inputs feed each other`
	end
	local source = named(buffer, id)
	if source == nil then
		return nil, `there's no block with id={id}`
	end
	local result = source.result
	if result == nil then
		chain[id] = true
		if not run_block(buffer, source, chain) then
			return nil, `block {id} didn't run`
		end
		local ran = named(buffer, id)
		result = ran and ran.result
	end
	if result == nil then
		return nil, `block {id} has no result`
	end
	return result.text, nil
end

--- Runs `block` in `buffer` and saves its result under it, waiting until
--- it's done. Returns whether it ran.
function run_block(buffer: greed.Buffer, block: Block, chain: { [string]: boolean }): boolean
	local runner = runners.get(block.lang)
	if runner == nil then
		greed.echo(
			`blocks in {block.lang} don't run (these do: {table.concat(runners.names(), ", ")})`
		)
		return false
	end
	if block.opts.id then
		chain[block.opts.id] = true
	end
	runs += 1
	local run: Running = { buffer = buffer, ns = `blocks-run-{runs}`, stopped = false }
	table.insert(running, run)
	show(run, block.from, " ■ running")
	draw(buffer)
	-- Running the block its input comes from moves this one, which the
	-- run's mark follows.
	local input, failed = input_for(buffer, block, chain)
	local now = block_at(buffer, where(run) or block.from) or block
	if failed then
		finish(run)
		save(buffer, now, { output = "", error = failed })
		draw(buffer)
		return false
	end
	local timeout = tonumber(now.opts.timeout)
	if timeout then
		greed.spawn(function()
			greed.sleep(timeout * 1000)
			local child = run.child
			if child and table.find(running, run) then
				run.stopped = true
				child.kill()
			end
		end)
	end
	local last = 0
	local ok, outcome = pcall(
		runner,
		{
			code = buffer:slice(now.code_from, now.code_to),
			input = input,
			opts = now.opts,
			dir = dir_for(buffer, now),
			progress = function(output: string)
				local at = where(run)
				if at and greed.now() - last > 150 then
					last = greed.now()
					local _, lines = string.gsub(output, "\n", "")
					show(
						run,
						at,
						` ■ running, {lines} line{if lines == 1 then "" else "s"} so far`
					)
				end
			end,
			started = function(child: greed.Child)
				run.child = child
			end,
		} :: runners.Run
	)
	local at = where(run)
	finish(run)
	local result: runners.Outcome = if ok
		then outcome
		else { output = "", error = tostring(outcome) }
	if run.stopped then
		result.output ..= "\n(stopped)"
	end
	local done = at and block_at(buffer, at)
	if done == nil then
		greed.echo("the block went away before it finished; its result is dropped")
		draw(buffer)
		return false
	end
	save(buffer, done, result)
	draw(buffer)
	return true
end

--- Runs `block` in `buffer`, without asking whether its file may, and
--- saves its result under it. Waits until it's done; returns whether it ran.
function M.run(buffer: greed.Buffer, block: Block): boolean
	return run_block(buffer, block, {})
end

--- The blocks in `buffer` that have a runner, in order.
function M.runnable(buffer: greed.Buffer): { Block }
	local list = {}
	for _, block in parse.blocks(buffer) do
		if runners.get(block.lang) then
			table.insert(list, block)
		end
	end
	return list
end

-- Asks whether blocks in `buffer`'s file may run, unless they may already.
local function allow(buffer: greed.Buffer): boolean
	if M.trusted(buffer) then
		return true
	end
	local path = path_of(buffer) :: string
	local name = string.match(path, "[^/]+$") or path
	greed.echo(`run code blocks from {name}? y yes, a always for this file, n no`)
	local key = greed.next_key()
	if key == "y" then
		allowed_now[path] = true
	elseif key == "a" then
		trusted[path] = true
		save_trusted()
	else
		greed.echo("nothing ran")
		return false
	end
	greed.echo("")
	draw(buffer)
	return true
end

local function cursor(ctx: greed.Context): number
	local selection = ctx.view:selection()
	return selection.ranges[selection.primary].head
end

greed.command({
	name = "block-run",
	doc = "Run the code block under the cursor and save its output in a result block under it",
	run = function(ctx)
		local block = block_at(ctx.buffer, cursor(ctx))
		if block == nil then
			greed.echo("there's no code block here")
		elseif allow(ctx.buffer) then
			run_block(ctx.buffer, block, {})
		end
	end,
})

greed.command({
	name = "blocks-run-all",
	doc = "Run every code block in the file, in order, saving each one's result",
	run = function(ctx)
		local buffer = ctx.buffer
		if #M.runnable(buffer) == 0 then
			greed.echo("there are no blocks to run here")
			return
		end
		if not allow(buffer) then
			return
		end
		-- Each result moves the blocks after it, so they're found again.
		local i = 1
		while true do
			local block = M.runnable(buffer)[i]
			if block == nil then
				break
			end
			run_block(buffer, block, {})
			i += 1
		end
	end,
})

greed.command({
	name = "block-result-clear",
	doc = "Remove the result under the code block at the cursor",
	run = function(ctx)
		local block = block_at(ctx.buffer, cursor(ctx))
		local result = block and block.result
		if result then
			ctx.buffer:edit(function(e)
				e:delete(result.from, result.to)
			end)
		end
	end,
})

greed.command({
	name = "blocks-results-clear",
	doc = "Remove every code block's result in the file",
	run = function(ctx)
		local blocks = parse.blocks(ctx.buffer)
		ctx.buffer:edit(function(e)
			for _, block in blocks do
				local result = block.result
				if result then
					e:delete(result.from, result.to)
				end
			end
		end)
	end,
})

greed.command({
	name = "block-stop",
	doc = "Stop the code block running under the cursor",
	run = function(ctx)
		local block = block_at(ctx.buffer, cursor(ctx))
		for _, run in running do
			local at = where(run)
			if run.buffer:id() == ctx.buffer:id() and block and at == block.from then
				run.stopped = true
				local child = run.child
				if child then
					child.kill()
				end
				return
			end
		end
		greed.echo("nothing is running here")
	end,
})

greed.command({
	name = "blocks-trust",
	doc = "Always let this file's code blocks run, without asking",
	run = function(ctx)
		local path = path_of(ctx.buffer)
		if path then
			trusted[path] = true
			save_trusted()
			draw(ctx.buffer)
		end
	end,
})

greed.command({
	name = "blocks-untrust",
	doc = "Ask again before this file's code blocks run",
	run = function(ctx)
		local path = path_of(ctx.buffer)
		if path then
			trusted[path], allowed_now[path] = nil, nil
			save_trusted()
			draw(ctx.buffer)
		end
	end,
})

-- A run button after each runnable block's fence, which enter on the fence
-- presses too, in files where blocks show as runnable.
function draw(buffer: greed.Buffer)
	local ok = pcall(buffer.line_count, buffer)
	if not ok then
		return
	end
	local busy: { [number]: boolean } = {}
	for _, run in running do
		local at = where(run)
		if at and run.buffer:id() == buffer:id() then
			busy[at] = true
		end
	end
	local marks: { greed.Mark } = {}
	if M.on(buffer) then
		for _, block in M.runnable(buffer) do
			if not busy[block.from] then
				-- Over the whole fence, so enter anywhere on it presses it.
				table.insert(marks, {
					from = block.from,
					to = buffer:line_end(block.open),
					style = "blocks.run",
					text = " ▶ run",
					eol = true,
					action = "block-run",
				})
			end
		end
	end
	buffer:decorate("blocks", marks)
end

local function on_buffer(event: greed.BufferChanged)
	draw(event.buffer)
end

greed.on("buffer.opened", on_buffer)
greed.on("buffer.changed", on_buffer)

require("@self/tools")(M)

greed.keymap.bind("normal", {
	["space m r"] = "block-run",
	["space m R"] = "blocks-run-all",
	["space m c"] = "block-result-clear",
	["space m s"] = "block-stop",
})

return M
