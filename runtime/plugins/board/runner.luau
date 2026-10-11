-- ```` ```shell ```` blocks in Markdown run in the Greed shell, as a
-- board's cards do: table stages and `| chart` work there, a chart shows in
-- colour (and as an image where the client draws one), and `every=N` runs
-- the line again every N seconds, keeping its result up to date until
-- it's stopped (space m s). A card on a board is such a block in a grid.

local greed = require("@greed")
local shell = require("@shell")
local blocks = require("@blocks")
local chart = require("@chart")

type Shell = shell.Shell
type Block = shell.Block
type Outcome = blocks.Outcome

-- The shell the blocks run in, out of sight, opened when one first runs.
local hidden: Shell? = nil

local function shell_for(dir: string): Shell
	local sh = hidden
	if sh and sh.buffer:valid() then
		return sh
	end
	local opened = shell.open({ name = "blocks", cwd = dir, show = false })
	hidden = opened
	return opened
end

-- The blocks of runs that are done, oldest first. A chart's image lasts
-- as long as its block, so the latest few stay.
local KEEP = 20
local kept: { Block } = {}

local function keep(sh: Shell, block: Block)
	table.insert(kept, block)
	while #kept > KEEP do
		shell.log.remove(sh, table.remove(kept, 1) :: Block)
	end
end

-- What `block` shows of its output, as the shell shows it.
local function shown(sh: Shell, block: Block): string
	local from, to = shell.log.output_range(sh, block)
	if from == nil or to == nil then
		return ""
	end
	return sh.buffer:slice(from, to)
end

-- What `block` gave, as a code block's result.
local function outcome_of(sh: Shell, block: Block): Outcome
	return { output = shown(sh, block), exit = block.code, drawing = chart.drawing(block) }
end

-- The live blocks, and what each tells of new output.
local live: { [Block]: () -> () } = {}

shell.log.on_update(function(block: Block)
	local tell = live[block]
	if tell then
		tell()
	end
end)

-- The lines of `code` to run, without blank lines and comments.
local function lines_of(code: string): { string }
	local out: { string } = {}
	for _, line in string.split(code, "\n") do
		if string.match(line, "%S") and not string.match(line, "^%s*#") then
			table.insert(out, line)
		end
	end
	return out
end

-- Runs `line` every `every` seconds in a watch, giving back what it shows
-- the first time and keeping the result up to date after.
local function run_live(run: blocks.Run, sh: Shell, line: string, every: number): Outcome
	local block = shell.run(sh, `watch -n {every} {line}`, { cwd = run.dir })
	if block == nil then
		return { output = "", error = "the shell didn't run it" }
	end
	local watched = block :: Block
	-- Until it shows something, or ends.
	local first = greed.signal()
	live[watched] = function()
		if shown(sh, watched) ~= "" then
			first:send(true)
		end
	end
	greed.spawn(function()
		watched.done:wait()
		first:send(false)
	end)
	first:wait()
	local update = run.live(function()
		live[watched] = nil
		shell.kill(watched)
		shell.log.remove(sh, watched)
	end)
	local last = shown(sh, watched)
	live[watched] = function()
		local now = shown(sh, watched)
		if now ~= last then
			last = now
			update(outcome_of(sh, watched))
		end
	end
	return outcome_of(sh, watched)
end

blocks.runner("shell", function(run: blocks.Run): Outcome
	local lines = lines_of(run.code)
	local sh = shell_for(run.dir)
	local every = tonumber(run.opts.every)
	if every then
		if #lines ~= 1 then
			return { output = "", error = "every=N runs one line" }
		end
		return run_live(run, sh, lines[1], math.max(every, 0.1))
	end
	local parts: { string } = {}
	local last: Block? = nil
	for _, line in lines do
		local block = shell.run(sh, line, { cwd = run.dir })
		if block == nil then
			return { output = table.concat(parts, "\n"), error = `the shell didn't run {line}` }
		end
		shell.wait(block)
		keep(sh, block)
		table.insert(parts, shown(sh, block))
		last = block
		if block.status ~= "done" then
			break
		end
	end
	local ran = last
	return {
		output = table.concat(parts, "\n"),
		exit = if ran then ran.code else nil,
		-- The chart of the last line, when it's alone.
		drawing = if ran and #parts == 1 then chart.drawing(ran) else nil,
	}
end)

return {}
