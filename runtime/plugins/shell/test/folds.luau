local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")
local shell = require("@shell")

type Shell = typeof(shell.open())
type Block = typeof(assert(shell.run(shell.open(), "true")))

local log = shell.log

-- A shell in a folder with scripts that print lines, slowly or not, and
-- one that fails.
local function open(t: test.TestContext): Shell
	-- These go about the shell as text; blocks mode has tests of its own.
	greed.option.set("shell-blocks", false)
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = t:tempdir({
		["lines.sh"] = "for i in 1 2 3 4 5 6; do echo line$i; done\n",
		["slow.sh"] = "for i in 1 2 3 4 5 6; do echo line$i; sleep 0.1; done\n",
		["fail.sh"] = "for i in 1 2 3 4 5 6; do echo oops$i; done\nexit 3\n",
	})
	return sh
end

local function done(t: test.TestContext, sh: Shell, line: string): Block
	local block = assert(shell.run(sh, line, { view = greed.view() }))
	t:wait_for(function()
		return block.status ~= "running"
	end)
	return block
end

-- The first line of `block`, where its command is.
local function top(sh: Shell, block: Block): number
	local from = log.range(block)
	return sh.buffer:line_of(assert(from))
end

local function folded(sh: Shell, block: Block): boolean
	return core.folds.starts(sh.buffer, top(sh, block))
end

local function shown(t: test.TestContext): string
	return table.concat(t:draw(60, 24), "\n")
end

test("a folded block stays folded while it prints, and counts what it hides", function(t)
	local sh = open(t)
	local block = assert(shell.run(sh, "sh slow.sh", { view = greed.view() }))
	t:wait_for(function()
		return string.find(sh.buffer:text(), "line2", 1, true) ~= nil
	end)
	local first, last = core.folds.block(sh.buffer, top(sh, block))
	core.folds.fold(sh.buffer, assert(first), last)
	t:wait_for(function()
		return block.status ~= "running"
	end)
	local text = shown(t)
	assert(not string.find(text, "line6", 1, true), "what came after is folded too: " .. text)
	assert(string.find(text, "⋯ 6 lines", 1, true), "it counts all of it: " .. text)
end)

test("with shell-fold-lines, a long block folds itself as it ends, unless it failed", function(t)
	greed.option.set("shell-fold-lines", 3)
	local sh = open(t)
	local long = done(t, sh, "sh lines.sh")
	assert(folded(sh, long), "six lines fold")
	local failed = done(t, sh, "sh fail.sh")
	assert(not folded(sh, failed), "a failure stays open, to read")
	greed.option.set("shell-fold-lines", 0)
	local open_again = done(t, sh, "sh lines.sh")
	assert(not folded(sh, open_again), "0 never folds")
end)

test(
	"with shell-fold-older, a new command folds the finished blocks above, not failed ones",
	function(t)
		greed.option.set("shell-fold-older", true)
		local sh = open(t)
		local first = done(t, sh, "sh lines.sh")
		assert(not folded(sh, first), "not until a command runs after it")
		local failed = done(t, sh, "sh fail.sh")
		assert(folded(sh, first), "the older one folded")
		local last = done(t, sh, "sh lines.sh")
		assert(not folded(sh, failed), "a failure stays open")
		assert(not folded(sh, last), "the newest stays open")
		greed.option.set("shell-fold-older", false)
	end
)

test("the mouse resting on a folded block peeks at it, and moving away closes the peek", function(t)
	local sh = open(t)
	local block = done(t, sh, "sh lines.sh")
	local first, last = core.folds.block(sh.buffer, top(sh, block))
	core.folds.fold(sh.buffer, assert(first), last)
	local main = greed.view()
	local rows = t:draw(60, 24)
	local row = 0
	for i, text in rows do
		if string.find(text, "sh lines.sh", 1, true) then
			row = i - 1
		end
	end
	t:mouse("move", 4, row)
	t:wait(700)
	local floats = table.concat(t:floats(), "\n")
	assert(string.find(floats, "line6", 1, true), "it peeks: " .. floats)
	assert(greed.view() == main, "the cursor stays where it was")
	t:draw(60, 24)
	-- Below the float, which covers the lines under the block.
	t:mouse("move", 4, row + 12)
	t:wait(50)
	assert(#t:floats() == 0, "moving away closed it")
end)

test("tab on a block folds it and again unfolds it; shift-tab folds them all", function(t)
	local sh = open(t)
	local one = done(t, sh, "sh lines.sh")
	local two = done(t, sh, "sh lines.sh")
	t:keys("esc")
	local from = log.range(one)
	greed.view():set_cursor(assert(from))
	t:keys("tab")
	assert(folded(sh, one) and not folded(sh, two), "tab folds the block under the cursor")
	t:keys("tab")
	assert(not folded(sh, one), "again unfolds it")
	t:keys("shift-tab")
	assert(folded(sh, one) and folded(sh, two), "shift-tab folds them all")
end)
