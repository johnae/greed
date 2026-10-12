local test = require("@greed/test")
local greed = require("@greed")
local shell = require("@shell")
local peek = require("../peek")
local rows = require("../rows")

type Shell = typeof(shell.open())
type Block = typeof(assert(shell.run(shell.open(), "true")))

local log = require("../log")

local function open(t: test.TestContext): Shell
	-- These go about the shell as text; blocks mode has tests of its own.
	greed.option.set("shell-blocks", false)
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = t:tempdir()
	greed.fs.write(`{sh.cwd}/rows`, "NAME  COUNT\na     1\nb     2\n")
	return sh
end

-- Runs `line` in `sh` and waits for it to finish.
local function done(t: test.TestContext, sh: Shell, line: string): Block
	local block = assert(shell.run(sh, line, { view = greed.view() }))
	t:wait_for(function()
		return block.status ~= "running"
	end)
	return block
end

-- A watch in `sh`, once it has shown its table.
local function watching(t: test.TestContext, sh: Shell): Block
	local block = assert(shell.run(sh, "watch -n 1 cat rows", { view = greed.view() }))
	t:wait_for(function()
		return block.table ~= nil
	end)
	return block
end

-- The text of the strip's lines.
local function strip_text(sh: Shell): string
	local strip = sh.strip
	return if strip then strip.text else ""
end

test("a running block that scrolled up has a line above the prompt", function(t)
	local sh = open(t)
	local watch = watching(t, sh)
	assert(sh.strip == nil, "the last block shows its own status")
	log.set_prompt(sh, "ls -l", { greed.view() })
	done(t, sh, "echo one")
	assert(strip_text(sh) == "watch -n 1 cat rows\n", strip_text(sh))
	-- Blocks still go above it, and what's typed stays at the prompt.
	log.set_prompt(sh, "ls -l", { greed.view() })
	local two = done(t, sh, "echo two")
	local _, two_ends = log.range(two)
	assert(two_ends == log.blocks_end(sh), "the last block ends where the strip starts")
	local text = sh.buffer:text()
	assert(string.find(text, "two\nwatch %-n 1 cat rows\n$"), text)
	log.set_prompt(sh, "ls -l", { greed.view() })
	-- The line stands for its block.
	local at = log.blocks_end(sh)
	assert(log.strip_block(sh, at) == watch and log.block_for(sh, at) == watch)
	assert(log.block_at(sh, at) == nil and log.strip_block(sh, at - 1) == nil)
	greed.view():set_cursor(at)
	t:run("shell-interrupt")
	t:wait_for(function()
		return watch.status ~= "running"
	end)
	t:wait_for(function()
		return sh.strip == nil
	end)
	assert(log.prompt_text(sh) == "ls -l", log.prompt_text(sh))
	assert(not string.find(sh.buffer:text(), "two\nwatch", 1, true))
end)

test("the strip says what a watch shows and how long the rest have run", function(t)
	local sh = open(t)
	local watch = watching(t, sh)
	local sleeper = assert(shell.run(sh, "sleep 30", { view = greed.view() }))
	done(t, sh, "echo one")
	assert(sh.strip and #sh.strip.blocks == 2 and sh.strip.blocks[1] == watch)
	local said: { string } = {}
	for _, mark in sh.buffer:decorations("shell.strip") do
		if mark.text then
			table.insert(said, mark.text)
		end
	end
	local all = table.concat(said, "|")
	assert(string.find(all, `◐ {watch.number} `, 1, true), all)
	assert(string.find(all, "2 rows", 1, true), all)
	assert(string.find(all, `◐ {sleeper.number} `, 1, true), all)
	shell.interrupt(sleeper)
	shell.interrupt(watch)
	t:wait_for(function()
		return sh.strip == nil
	end)
end)

test("enter on a strip line opens its block in a float, and esc closes it", function(t)
	local sh = open(t)
	local watch = watching(t, sh)
	done(t, sh, "echo one")
	local main = greed.view()
	main:set_cursor(log.blocks_end(sh))
	t:run("shell-enter")
	local float = greed.view()
	assert(float ~= main and float:float_spec() ~= nil, "a float opened")
	assert(peek.of(float) == watch)
	-- It shows the block and none of the shell around it, the prompt below
	-- included, and the cursor can't leave it.
	local from, to = log.range(watch)
	local first, last = float:narrowed()
	assert(first == sh.buffer:line_of(assert(from)), `{first}`)
	assert(last == sh.buffer:line_of(assert(to) - 1), `{last}`)
	assert(assert(last) < sh.buffer:line_of(sh.buffer:len()), "not the prompt")
	t:keys("G")
	assert(log.block_at(sh, float:cursor()) == watch, "G stays in the block")
	-- In it, what's at the cursor is the block, so filtering it works.
	assert(log.block_at(sh, float:cursor()) == watch)
	rows.set(sh, watch, "COUNT>1")
	assert(watch.shown and #watch.shown.rows == 1)
	t:run("shell-unfilter")
	assert(not float:valid(), "esc closed it")
	assert(watch.shown and watch.shown.filter == "COUNT>1", "the filter stays")
	-- A live block keeps it as it shows what's new.
	greed.sleep(1000)
	t:wait_for(function()
		return string.find(watch.note or "", "every", 1, true) ~= nil
	end)
	assert(watch.shown and watch.shown.filter == "COUNT>1")
	shell.interrupt(watch)
end)

test("a block's float closes when the block is cleared away", function(t)
	local sh = open(t)
	local one = done(t, sh, "echo one")
	local float = assert(peek.open(sh, one))
	assert(peek.of(float) == one)
	t:run("shell-clear")
	assert(not float:valid(), "its float closed with it")
end)

test("ctrl-c at the prompt says which blocks still run", function(t)
	local sh = open(t)
	local first = assert(shell.run(sh, "sleep 30", { view = greed.view() }))
	local second = assert(shell.run(sh, "sleep 31", { view = greed.view() }))
	t:messages()
	greed.view():set_cursor(sh.buffer:len())
	t:run("shell-interrupt")
	t:wait_for(function()
		return second.status ~= "running"
	end)
	local said = table.concat(t:messages(), "|")
	assert(
		string.find(said, `stopped {second.number} · still running: {first.number}`, 1, true),
		said
	)
	shell.interrupt(first)
end)

test("stop lists what runs, and stops blocks by number or all of them", function(t)
	local sh = open(t)
	local first = assert(shell.run(sh, "sleep 30", { view = greed.view() }))
	local second = assert(shell.run(sh, "sleep 31", { view = greed.view() }))
	local listed = done(t, sh, "stop")
	assert(listed.stdout == `{first.number}  sleep 30\n{second.number}  sleep 31\n`, listed.stdout)
	local one = done(t, sh, `stop {first.number} 99`)
	assert(
		one.code == 1 and string.find(one.stderr, "99 isn't a running block", 1, true),
		one.stderr
	)
	t:wait_for(function()
		return first.status ~= "running"
	end)
	assert(second.status == "running")
	done(t, sh, "stop all")
	t:wait_for(function()
		return second.status ~= "running"
	end)
	local none = done(t, sh, "stop")
	assert(none.stdout == "nothing else is running\n", none.stdout)
end)

test("space o w lists what runs in every shell: enter peeks, ctrl-x stops", function(t)
	local sh = open(t)
	t:run("pick-running")
	assert(#t:floats() == 0, "nothing to pick")
	local first = assert(shell.run(sh, "sleep 40 && echo one", { view = greed.view() }))
	local second = assert(shell.run(sh, "sleep 31 && echo two", { view = greed.view() }))
	t:keys("esc space o w")
	assert(#t:floats() > 0, "a picker")
	-- Words to pick by: digits could match how long each has run.
	t:keys("t w o")
	-- Beside it, the block as its shell shows it.
	t:wait_for(function()
		for _, text in t:floats() do
			if string.find(text, "^sleep 31 && echo two\n") then
				return true
			end
		end
		return false
	end)
	t:keys("enter")
	local float = greed.view()
	assert(peek.of(float) == second, "enter opened the block in a float")
	t:keys("esc")
	t:keys("space o w")
	t:keys("o n e ctrl-x")
	t:wait_for(function()
		return first.status ~= "running"
	end)
	assert(second.status == "running")
	shell.interrupt(second)
end)

test("floats opened on purpose stay, one for each block, while you work elsewhere", function(t)
	local sh = open(t)
	local one = watching(t, sh)
	local two = watching(t, sh)
	local main = greed.view()
	local first = assert(peek.open(sh, one))
	main:focus()
	local second = assert(peek.open(sh, two))
	assert(first:valid() and second:valid(), "both stay open")
	assert(first:float_spec() and assert(first:float_spec()).tab, "a float of the tab")
	-- Each follows its own block.
	assert(peek.of(first) == one and peek.of(second) == two)
	-- Opening the first again goes to it rather than making another.
	main:focus()
	assert(peek.open(sh, one) == first and greed.view() == first)
	-- The tab's float layouts take them in.
	if greed.plugin.dirs().panes then
		assert(#require("@panes").floats.all() >= 2, "the panes plugin arranges them")
	end
	-- esc closes the one it's in, and the other stays.
	t:run("shell-unfilter")
	assert(not first:valid() and second:valid())
	peek.close(second)
	shell.interrupt(one)
	shell.interrupt(two)
end)

test(
	"a block's float keeps the cursor on whole characters, at a block ending in one of several bytes",
	function(t)
		local sh = open(t)
		local block = done(t, sh, "printf 'one\\n─╯'")
		local float = assert(peek.open(sh, block))
		-- Past the block's end, the float brings the cursor back onto its last
		-- character as it follows the block, `╯` here.
		float:set_cursor(sh.buffer:len())
		peek.follow(block)
		local cursor = float:cursor()
		assert(sh.buffer:slice(cursor, sh.buffer:next_char(cursor)) ~= "", "on a character")
		assert(log.block_at(sh, cursor) == block, "in the block")
		peek.close(float)
	end
)
