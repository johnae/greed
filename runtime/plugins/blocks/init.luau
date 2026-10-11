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
-- on each block. Agents run blocks only in files you trust, and only as
-- they were when you last ran them or trusted the file, so a block an
-- agent rewrote waits for you to run it first.
--
-- Options go in the info string: `id=NAME` names a block's result, and
-- `input=NAME` gives another block that result (on stdin, or as `input` in
-- Luau), running the named block first if it has no result yet, or every
-- time with `rerun=true`. `dir=PATH` runs a program elsewhere than the
-- file's folder, and `timeout=SECONDS` stops it after that long. Add a
-- language from Luau:
--
--     require("@blocks").runner("lua", require("@blocks").program({ "lua", "-e" }))

local greed = require("@greed")
local core = require("@core")
local parse = require("@self/parse")
local runners = require("@self/runners")
local markdown = require("@markdown")
local scene = require("@scene")

type Block = parse.Block
export type Run = runners.Run
export type Outcome = runners.Outcome

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

-- The buffer's file, if it has one and is still open.
local function path_of(buffer: greed.Buffer): string?
	return if buffer:valid() then buffer:path() else nil
end

--- Whether blocks in `buffer` may run without asking: its file is trusted
--- or allowed for now, or it has no file (you wrote it here).
function M.trusted(buffer: greed.Buffer): boolean
	local path = path_of(buffer)
	return path == nil or trusted[path] == true or allowed_now[path] == true
end

-- What you let run, block by block: for each file, the blocks (their info
-- string and code) as they were when you ran one yourself or trusted the
-- file. Agents run only those, so one that rewrote a block, in the buffer
-- or on disk, can't run it. Kept in the data folder as JSON.
local approved_file = data and `{data}/blocks-approved.json`
local approved: { [string]: { [string]: boolean } } = {}

local function load_approved()
	local text = approved_file and greed.fs.read(approved_file)
	local ok, saved = pcall(greed.json.decode, text or "{}")
	for path, texts in (if ok and type(saved) == "table" then saved else {}) :: { [string]: any } do
		approved[path] = {}
		for _, block in texts do
			approved[path][block] = true
		end
	end
end
load_approved()

local function save_approved()
	if approved_file == nil then
		return
	end
	local out: { [string]: { string } } = {}
	for path, texts in approved do
		local list = {}
		for text in texts do
			table.insert(list, text)
		end
		out[path] = list
	end
	greed.fs.write(approved_file, greed.json.encode(out))
end

-- A block as it's approved: what it runs as and its code.
local function block_text(buffer: greed.Buffer, block: Block): string
	return block.info .. "\n" .. buffer:slice(block.code_from, block.code_to)
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

-- `block` and the blocks it takes input from, and theirs, in `buffer`.
local function with_inputs(buffer: greed.Buffer, block: Block): { Block }
	local list: { Block } = { block }
	local seen: { [string]: boolean } = {}
	local i = 1
	while list[i] do
		local id = list[i].opts.input
		if id and not seen[id] then
			seen[id] = true
			local source = named(buffer, id)
			if source then
				table.insert(list, source)
			end
		end
		i += 1
	end
	return list
end

-- Approves `blocks` of `buffer`'s file as they are now, forgetting what
-- was approved there that's no longer in it.
local function approve(buffer: greed.Buffer, blocks: { Block })
	local path = path_of(buffer)
	if path == nil then
		return
	end
	local now: { [string]: boolean } = {}
	for _, block in parse.blocks(buffer) do
		now[block_text(buffer, block)] = true
	end
	local kept: { [string]: boolean } = {}
	for text in approved[path] or {} :: { [string]: boolean } do
		if now[text] then
			kept[text] = true
		end
	end
	for _, block in blocks do
		kept[block_text(buffer, block)] = true
	end
	approved[path] = kept
	save_approved()
end

--- Why an agent may not run `block` in `buffer`: the file isn't trusted,
--- or the block (or one it takes input from) isn't as you last ran it or
--- trusted the file. Nil when it may.
function M.refused(buffer: greed.Buffer, block: Block): string?
	if not M.trusted(buffer) then
		return "the user hasn't let blocks in this file run; they can with :blocks-trust"
	end
	local path = path_of(buffer)
	if path == nil then
		return nil
	end
	local known: { [string]: boolean } = approved[path] or {}
	for _, needed in with_inputs(buffer, block) do
		if not known[block_text(buffer, needed)] then
			return `the block on line {needed.open + 1} changed since the user last ran it or `
				.. "trusted the file; they can run it themselves (space m r) or :blocks-trust again"
		end
	end
	return nil
end

--- Whether `buffer` shows its blocks as runnable: Markdown whose front
--- matter says `greed: run`, or a file you trusted.
function M.on(buffer: greed.Buffer): boolean
	if not buffer:valid() or buffer:language() ~= "markdown" then
		return false
	end
	local wants = parse.front_matter(buffer)
	if wants and string.find(wants, "%f[%w]run%f[^%w]") then
		return true
	end
	local path = path_of(buffer)
	return path ~= nil and (trusted[path] or allowed_now[path]) == true
end

core.features.add("blocks", M.on)

-- Runs in progress, each tracking its block's fence as it moves with edits,
-- so the result goes under the block wherever it is by the time it's done.
-- `status` shows after the fence. A live run stays until `stop` ends it.
type Running = {
	buffer: greed.Buffer,
	fence: greed.Tracked,
	status: string,
	child: greed.Child?,
	stopped: boolean,
	stop: (() -> ())?,
}
local running: { Running } = {}

-- What runs drew over their results, by the fence of their block.
type Drawn = { buffer: greed.Buffer, fence: greed.Tracked, drawing: runners.Drawing }
local drawn: { Drawn } = {}

local OUT_OF_UNDO: { undo: boolean? } = { undo = false }

-- Where a run's block starts now, unless its fence went.
local function where(run: Running): number?
	return (run.fence:range())
end

local draw: (buffer: greed.Buffer) -> ()

-- Shows `text` after the fence of the block `run` is running.
local function show(run: Running, text: string)
	run.status = text
	draw(run.buffer)
end

-- Takes `run` off the running list, along with what it shows.
local function finish(run: Running)
	run.fence:forget()
	table.remove(running, table.find(running, run) :: number)
	draw(run.buffer)
end

-- Ends `run`, a live one.
local function stop_live(run: Running)
	local stop = run.stop
	if stop and not run.stopped then
		run.stopped = true
		stop()
		finish(run)
	end
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

-- Keeps what `outcome` drew to show over the result of `block`, in place
-- of what a run of it drew before.
local function keep_drawing(buffer: greed.Buffer, block: Block, outcome: runners.Outcome)
	for i = #drawn, 1, -1 do
		local d = drawn[i]
		local at = d.fence:range()
		if d.buffer == buffer and (at == nil or at == block.from) then
			d.fence:forget()
			table.remove(drawn, i)
		end
	end
	local drawing = outcome.drawing
	if drawing then
		local fence = buffer:track_range(block.from, buffer:line_end(block.open))
		table.insert(drawn, { buffer = buffer, fence = fence, drawing = drawing })
	end
end

-- Saves `outcome` as the result of `block`, replacing the one it had,
-- kept to undo unless `opts` says.
local function save(
	buffer: greed.Buffer,
	block: Block,
	outcome: runners.Outcome,
	opts: { undo: boolean? }?
)
	keep_drawing(buffer, block, outcome)
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
	end, opts)
end

-- The choices an `output=choices` block's output makes: a JSON list of
-- strings, or its lines. One starting `(x) ` is picked to begin with.
local function choices_of(output: string): { string }
	local ok, list = pcall(greed.json.decode, output)
	local items: { string } = {}
	if ok and type(list) == "table" then
		for _, item in list :: { any } do
			table.insert(items, tostring(item))
		end
	else
		for line in string.gmatch(output, "[^\n]+") do
			if not string.match(line, "^%s*$") then
				table.insert(items, line)
			end
		end
	end
	return items
end

-- Writes `output` as the choices under `block`, in place of the ones it
-- made before, keeping the pick when that option is still there.
local function save_choices(buffer: greed.Buffer, block: Block, output: string)
	-- Its list: on the line after it, or after one blank line.
	local old: markdown.Group? = nil
	for _, line in { block.close + 1, block.close + 2 } do
		old = old or markdown.choices.at(buffer, line)
	end
	local picked: string? = nil
	for _, option in (if old then old.options else {}) :: { markdown.Option } do
		if option.picked then
			picked = option.value
		end
	end
	local lines = {}
	for _, item in choices_of(output) do
		local text = string.match(item, "^%(x%) (.*)$") or item
		local chosen = if picked then markdown.choices.value_of(text) == picked else text ~= item
		table.insert(lines, `- ({if chosen then "x" else " "}) {text}`)
	end
	local list = table.concat(lines, "\n")
	buffer:edit(function(e)
		if old then
			local last = old.options[#old.options].line
			e:replace(buffer:line_start(old.options[1].line), buffer:line_end(last), list)
		else
			e:insert(buffer:line_end(block.close), "\n\n" .. list)
		end
	end)
end

-- Puts what a run gave where it goes: a block making choices writes them,
-- a button or a block a pick runs says what it printed or what went wrong,
-- and any other saves its result under it.
local function deliver(buffer: greed.Buffer, block: Block, outcome: runners.Outcome)
	if block.opts.output == "choices" and not outcome.error then
		save_choices(buffer, block, outcome.output)
	elseif block.opts.output == "choices" or block.opts.button or block.opts.when then
		local said = if outcome.error
			then `error: {outcome.error}`
			else string.match(outcome.output, "^%s*(.-)%s*$") or ""
		if said ~= "" then
			greed.echo(said)
		end
	else
		save(buffer, block, outcome)
	end
end

-- The folder a block runs in: its `dir` option (from the file's folder),
-- or the file's folder, or the project's root.
local function dir_for(buffer: greed.Buffer, block: Block): string
	local path = path_of(buffer)
	local base = if path then string.match(path, "^(.*)/[^/]*$") or "/" else nil
	return core.project.resolve(block.opts.dir or ".", base)
end

-- Says why a block may not run, when it may not; agents' runs have one.
type Check = (block: Block) -> string?

-- How a run goes beyond the usual: `answer` is the answer whose pick ran it.
type How = { answer: string? }

local run_block: (
	buffer: greed.Buffer,
	block: Block,
	chain: { [string]: boolean },
	check: Check?,
	how: How?
) -> boolean

-- The input for `block`: the result of the block its `input` option
-- names, running that first if it has none. Nil and why when it can't.
local function input_for(
	buffer: greed.Buffer,
	block: Block,
	chain: { [string]: boolean },
	check: Check?
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
	-- With `rerun=true`, the input runs every time, not only without a result.
	local result = if block.opts.rerun == "true" then nil else source.result
	if result == nil then
		chain[id] = true
		if not run_block(buffer, source, chain, check) then
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
function run_block(
	buffer: greed.Buffer,
	block: Block,
	chain: { [string]: boolean },
	check: Check?,
	how: How?
): boolean
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
	local run: Running = {
		buffer = buffer,
		fence = buffer:track_range(block.from, buffer:line_end(block.open)),
		status = "■ running",
		stopped = false,
	}
	table.insert(running, run)
	draw(buffer)
	-- Running the block its input comes from moves this one, which the
	-- run's tracked fence follows.
	local input, failed = input_for(buffer, block, chain, check)
	local now = block_at(buffer, where(run) or block.from) or block
	-- Checked on the block as it is now, after any wait for its input.
	failed = failed or (check and check(now))
	if failed then
		finish(run)
		deliver(buffer, now, { output = "", error = failed })
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
				child:kill()
			end
		end)
	end
	-- The page's answers, and the one this run is about: the pick that ran
	-- it, or the question it listens to.
	local answers = markdown.questions.answers(buffer)
	local answer = (how and how.answer) or (now.opts.when and answers[now.opts.when])
	local last = 0
	local ok, outcome = pcall(
		runner,
		{
			code = buffer:slice(now.code_from, now.code_to),
			input = input,
			opts = now.opts,
			dir = dir_for(buffer, now),
			progress = function(output: string)
				if where(run) and greed.now() - last > 150 then
					last = greed.now()
					local _, lines = string.gsub(output, "\n", "")
					show(run, `■ running, {lines} line{if lines == 1 then "" else "s"} so far`)
				end
			end,
			answers = answers,
			answer = answer,
			started = function(child: greed.Child)
				run.child = child
			end,
			live = function(stop: () -> ()): (outcome: runners.Outcome) -> ()
				run.stop = stop
				return function(outcome: runners.Outcome)
					if run.stopped then
						return
					end
					local at = where(run)
					local live = if at and buffer:valid() then block_at(buffer, at) else nil
					if not live then
						stop_live(run)
						return
					end
					save(buffer, live, outcome, OUT_OF_UNDO)
					draw(buffer)
				end
			end,
		} :: runners.Run
	)
	local at = where(run)
	if ok and run.stop and not run.stopped then
		show(run, "● live")
	elseif run.stop then
		stop_live(run)
	else
		finish(run)
	end
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
	deliver(buffer, done, result)
	draw(buffer)
	return true
end

--- Runs `block` in `buffer`, without asking whether its file may, and
--- saves its result under it. Waits until it's done; returns whether it ran.
function M.run(buffer: greed.Buffer, block: Block): boolean
	return run_block(buffer, block, {})
end

--- Runs `block` for an agent: as `M.run`, but only blocks as you let them
--- run (`M.refused`), checked again on each as it starts.
function M.run_for_agent(buffer: greed.Buffer, block: Block): boolean
	return run_block(buffer, block, {}, function(now: Block): string?
		return M.refused(buffer, now)
	end)
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

--- Asks whether what the file at `path` holds may run (`what`, "code
--- blocks" unless said), unless it may already: `y` for now, `a` always.
--- Boards share this, so a file trusted for one is trusted for the other.
function M.allow_file(path: string, what: string?): boolean
	if trusted[path] or allowed_now[path] then
		return true
	end
	local name = core.project.basename(path) or path
	greed.echo(`run {what or "code blocks"} from {name}? y yes, a always for this file, n no`)
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
	return true
end

--- Trusts the file at `path` to run what it holds, as `a` does: for a file
--- you made yourself.
function M.trust(path: string)
	if not trusted[path] then
		trusted[path] = true
		save_trusted()
	end
end

-- Asks whether blocks in `buffer`'s file may run, unless they may already.
local function allow(buffer: greed.Buffer): boolean
	if M.trusted(buffer) then
		return true
	end
	local path = path_of(buffer) :: string
	if not M.allow_file(path) then
		return false
	end
	if trusted[path] then
		approve(buffer, M.runnable(buffer))
	end
	draw(buffer)
	return true
end

greed.command({
	name = "block-run",
	doc = "Run the code block under the cursor and save its output in a result block under it",
	run = function(ctx)
		local block = block_at(ctx.buffer, ctx.view:cursor())
		if block == nil then
			greed.echo("there's no code block here")
		elseif allow(ctx.buffer) then
			approve(ctx.buffer, with_inputs(ctx.buffer, block))
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
		approve(buffer, M.runnable(buffer))
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
		local block = block_at(ctx.buffer, ctx.view:cursor())
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
		local block = block_at(ctx.buffer, ctx.view:cursor())
		for _, run in running do
			local at = where(run)
			if run.buffer == ctx.buffer and block and at == block.from then
				if run.stop then
					stop_live(run)
					return
				end
				run.stopped = true
				local child = run.child
				if child then
					child:kill()
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
			approve(ctx.buffer, M.runnable(ctx.buffer))
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
			trusted[path], allowed_now[path], approved[path] = nil, nil, nil
			save_trusted()
			save_approved()
			draw(ctx.buffer)
		end
	end,
})

--- Runs every `output=choices` block in `buffer`, in order, so the choices
--- they make are as they'd be now. Waits until they're done.
function M.refresh_choices(buffer: greed.Buffer)
	local i = 1
	while true do
		local list: { Block } = {}
		for _, block in M.runnable(buffer) do
			if block.opts.output == "choices" then
				table.insert(list, block)
			end
		end
		local block = list[i]
		if block == nil then
			break
		end
		run_block(buffer, block, {})
		i += 1
	end
end

-- A trusted file's choices are made afresh as it opens: they're what's
-- there now, like the themes there are.
greed.on("buffer.opened", function(event: greed.BufferChanged)
	local buffer = event.buffer
	if M.on(buffer) and M.trusted(buffer) then
		greed.spawn(function()
			M.refresh_choices(buffer)
		end)
	end
end)

-- A pick runs the blocks listening to its question (`when=ID`), with what
-- was picked, once you let the file's blocks run.
-- Running them is this plugin's own doing, as when you run a block, rather
-- than the markdown plugin's that tells of the pick; a plugin that picked
-- for you limits it to what that plugin may.
local function heard(buffer: greed.Buffer, group: markdown.Group)
	local id = group.id
	if id == nil then
		return
	end
	local answer: string? = nil
	for _, option in group.options do
		if option.picked then
			answer = option.value
		end
	end
	local asked = false
	for _, block in M.runnable(buffer) do
		if block.opts.when == id then
			if not asked and not allow(buffer) then
				return
			end
			asked = true
			approve(buffer, { block })
			run_block(buffer, block, {}, nil, { answer = answer })
		end
	end
end

markdown.choices.on_pick(function(buffer, group, by)
	greed.vouch(greed.plugin.within, by, heard, buffer, group)
end)

-- The marks showing `drawing` over `result`'s text: its lines' styles,
-- and its scene over them, for the clients that draw one better. None when
-- the result's text isn't the drawing's, as after an edit.
local function drawing_marks(
	buffer: greed.Buffer,
	result: { from: number, to: number },
	drawing: runners.Drawing
): { greed.Mark }
	-- The result's text starts the line after its opening fence.
	local first = buffer:line_of(result.from) + 1
	while first < buffer:line_count() and string.sub(buffer:line_text(first), 1, 3) ~= "```" do
		first += 1
	end
	first += 1
	local count = #drawing.lines
	if first + count > buffer:line_of(result.to) then
		return {}
	end
	local out: { greed.Mark } = {}
	for k, line in drawing.lines do
		local start = buffer:line_start(first + k - 1)
		local here = buffer:line_text(first + k - 1)
		if string.gsub(here, "%s+$", "") ~= string.gsub(line.text, "%s+$", "") then
			return {}
		end
		for _, mark in line.marks do
			table.insert(
				out,
				{ from = start + mark.from, to = start + mark.to, style = mark.style }
			)
		end
	end
	if scene.drawn() then
		table.insert(out, {
			from = buffer:line_start(first),
			to = buffer:line_end(first + count - 1),
			style = "",
			scene = { id = drawing.scene, cols = drawing.cols, rows = count },
		})
	end
	return out
end

-- A run button after each runnable block's fence, which enter on the fence
-- presses too, in files where blocks show as runnable, and how each running
-- block is doing, which a click stops.
function draw(buffer: greed.Buffer)
	if not buffer:valid() then
		return
	end
	local busy: { [number]: boolean } = {}
	local marks: { greed.Mark } = {}
	for _, run in running do
		local at = where(run)
		if at and run.buffer == buffer then
			busy[at] = true
			table.insert(marks, {
				from = at,
				to = buffer:line_end(buffer:line_of(at)),
				style = "blocks.running",
				text = run.status,
				eol = true,
				action = "block-stop",
			})
		end
	end
	-- A button block shows as its button, and blocks working behind a page
	-- of questions (making choices, hearing picks) as nothing; their code is
	-- folded under the fence, and shows once the cursor goes there.
	local behind: { [number]: boolean } = {}
	if buffer:valid() and buffer:language() == "markdown" then
		for _, block in M.runnable(buffer) do
			local label = block.opts.button
			if label or block.opts.when or block.opts.output == "choices" then
				behind[block.from] = true
				table.insert(marks, {
					from = block.from,
					to = buffer:line_end(block.open),
					style = if label then "ui.button" else "markdown.marker",
					text = if label then `[ {label} ]` else nil,
					conceal = true,
					-- On a page nobody edits, like setup's, a button stays one
					-- under the cursor too.
					reveal = if buffer:readonly() then "never" :: "never" else nil,
					action = if label then "block-run" else nil,
				})
				table.insert(marks, {
					from = block.from,
					to = block.to,
					style = "markdown.marker",
					fold = true,
				})
			end
		end
	end
	for _, d in drawn do
		local at = d.fence:range()
		local block = if at and d.buffer == buffer then block_at(buffer, at) else nil
		local result = block and block.result
		if result then
			for _, mark in drawing_marks(buffer, result, d.drawing) do
				table.insert(marks, mark)
			end
		end
	end
	if M.on(buffer) then
		for _, block in M.runnable(buffer) do
			if not busy[block.from] and not behind[block.from] then
				-- Over the whole fence, so enter anywhere on it presses it, and
				-- the button after it: only the button looks like one, so the
				-- fence reads as it does elsewhere.
				local fence_end = buffer:line_end(block.open)
				table.insert(marks, {
					from = block.from,
					to = fence_end,
					style = "",
					action = "block-run",
				})
				table.insert(marks, {
					from = fence_end,
					to = fence_end,
					style = "blocks.run",
					text = "▶ run",
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
-- A page a plugin made with its text already in it never opens or changes:
-- its buttons are drawn when a view first shows it, as views report their
-- size then.
greed.on("view.resized", function(event: greed.ViewResized)
	draw(event.view:buffer())
end)

require("@self/tools")(M)

greed.keymap.bind({ layer = "leader" }, {
	["m r"] = "block-run",
	["m R"] = "blocks-run-all",
	["m c"] = "block-result-clear",
	["m s"] = "block-stop",
})

return M
