local test = require("@greed/test")
local greed = require("@greed")
local shell = require("@shell")

type Shell = typeof(shell.open())
type Block = typeof(assert(shell.run(shell.open(), "true")))

local function open(t: test.TestContext, dir: string): Shell
	-- These go about the shell as text; blocks mode has tests of its own.
	greed.option.set("shell-blocks", false)
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = dir
	return sh
end

local function run(t: test.TestContext, sh: Shell, line: string): Block
	shell.log.set_prompt(sh, line, { greed.view() })
	t:keys("enter")
	local block = sh.blocks[#sh.blocks]
	t:wait_for(function()
		return block.status ~= "running"
	end)
	return block
end

-- Puts `text` at the prompt, typing, with the cursor at its end.
local function prompt(sh: Shell, text: string)
	shell.log.set_prompt(sh, text, { greed.view() })
end

local function at_prompt(sh: Shell): string
	return shell.log.prompt_text(sh)
end

local function history_file(): string
	return `{assert(greed.fs.dirs().data)}/shell/history.jsonl`
end

test("commands typed are kept in the data folder, an agent's aren't", function(t)
	local dir = t:tempdir()
	local sh = open(t, dir)
	run(t, sh, "echo one")
	local block = assert(shell.run(sh, "echo agent", { by = "agent" }))
	t:wait_for(function()
		return block.status ~= "running"
	end)
	run(t, sh, "echo two")
	local text = assert(greed.fs.read(history_file()))
	local lines = string.split(string.gsub(text, "\n$", ""), "\n")
	assert(#lines == 2, text)
	local first = greed.json.decode(lines[1])
	assert(first.command == "echo one" and first.cwd == dir, lines[1])
	assert(greed.json.decode(lines[2]).command == "echo two", lines[2])
end)

test("up and down go through the commands starting with what's typed", function(t)
	local sh = open(t, t:tempdir())
	run(t, sh, "echo one")
	run(t, sh, "ls")
	run(t, sh, "echo two")
	run(t, sh, "echo one")
	prompt(sh, "ec")
	t:keys("up")
	assert(at_prompt(sh) == "echo one", at_prompt(sh))
	t:keys("up")
	assert(at_prompt(sh) == "echo two", "each command once: " .. at_prompt(sh))
	t:keys("up")
	assert(at_prompt(sh) == "echo two", "nothing older: " .. at_prompt(sh))
	t:keys("down")
	assert(at_prompt(sh) == "echo one", at_prompt(sh))
	t:keys("down")
	assert(at_prompt(sh) == "ec", "back to what was typed: " .. at_prompt(sh))
	-- From an empty prompt, every command, newest first.
	prompt(sh, "")
	t:keys("up up up")
	assert(at_prompt(sh) == "ls", at_prompt(sh))
	-- Typing starts a new walk from what's there.
	t:keys("backspace up")
	assert(at_prompt(sh) == "ls", at_prompt(sh))
	t:keys("up")
	assert(at_prompt(sh) == "ls", "only ls starts with l: " .. at_prompt(sh))
end)

test("up and down away from the prompt's edge lines move the cursor as usual", function(t)
	local sh = open(t, t:tempdir())
	run(t, sh, "echo one")
	prompt(sh, "two")
	-- In a block's output.
	greed.view():set_cursor(sh.buffer:line_start(1))
	t:keys("up")
	assert(greed.view():cursor() == 0, tostring(greed.view():cursor()))
	assert(at_prompt(sh) == "two", at_prompt(sh))
	-- On the first of two lines at the prompt, down goes to the second.
	prompt(sh, "first\nsecond")
	greed.view():set_cursor(shell.log.prompt_start(sh))
	t:keys("down")
	assert(at_prompt(sh) == "first\nsecond", at_prompt(sh))
	assert(sh.buffer:line_of(greed.view():cursor()) == sh.buffer:line_count() - 1)
end)

test("the history from earlier sessions is there in a new shell", function(t)
	greed.fs.write(
		history_file(),
		'{"command":"make build","cwd":"/","time":1}\n{"command":"make test","cwd":"/","time":2}\n'
	)
	local sh = open(t, t:tempdir())
	t:keys("up")
	assert(at_prompt(sh) == "make test", at_prompt(sh))
	t:keys("up")
	assert(at_prompt(sh) == "make build", at_prompt(sh))
end)

test("ctrl-r picks a command typed before", function(t)
	local sh = open(t, t:tempdir())
	run(t, sh, "echo apple")
	run(t, sh, "echo banana")
	prompt(sh, "")
	t:keys("ctrl-r")
	local floats = table.concat(t:floats(), "\n")
	assert(string.find(floats, "echo apple", 1, true), floats)
	t:keys("a p p l e enter")
	assert(at_prompt(sh) == "echo apple", at_prompt(sh))
	assert(greed.view():buffer() == sh.buffer)
end)
