local test = require("@greed/test")
local greed = require("@greed")
local shell = require("@shell")

type Shell = typeof(shell.open())
type Block = typeof(assert(shell.run(shell.open(), "true")))

local function open(t: test.TestContext): Shell
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = t:tempdir()
	return sh
end

local function finished(t: test.TestContext, block: Block): Block
	t:wait_for(function()
		return block.status ~= "running"
	end)
	return block
end

-- Types `line` at `sh`'s prompt and runs it, as enter does.
local function typed(t: test.TestContext, sh: Shell, line: string): Block
	local count = #sh.blocks
	shell.log.set_prompt(sh, line, { greed.view() })
	t:keys("enter")
	assert(#sh.blocks > count, "nothing ran for " .. line)
	return finished(t, sh.blocks[#sh.blocks])
end

local function ran(t: test.TestContext, sh: Shell, line: string): Block
	return finished(t, assert(shell.run(sh, line, { runner = "pipe" })))
end

test("!! and !$ are the command before and its last word; ^old^new changes it", function(t)
	local sh = open(t)
	typed(t, sh, "echo one two")
	assert(typed(t, sh, "!! three").command == "echo one two three")
	assert(typed(t, sh, "echo !$").command == "echo three")
	assert(typed(t, sh, "^three^four").command == "echo four")
	assert(typed(t, sh, "echo 'a!!b'").command == "echo 'a!!b'", "single quotes keep it")
end)

test("history expansion says why it can't", function()
	local expand = shell.history.expand
	local line, why = expand("!!", nil)
	assert(line == nil and string.find(why or "", "no command before", 1, true), why)
	line, why = expand("^cat^dog", "echo hi")
	assert(line == nil and why == "cat isn't in echo hi", why)
	assert(expand("^ls", "echo hi") == "^ls", "one ^ is a program, not a change")
	assert(expand("^grep ^foo", "echo hi") == "^grep ^foo", "nor is ^NAME with an argument")
	assert(expand("ls -la", nil) == "ls -la", "nothing to expand")
end)

test("^NAME runs the program even where the shell has a builtin or stage", function(t)
	local sh = open(t)
	local parsed = shell.parse.parse("^env")
	assert(parsed.kind == "argv" and parsed.raw and parsed.line == "env", parsed.kind)
	local real = ran(t, sh, "^env")
	assert(string.find(real.stdout, "PATH=", 1, true), "the env program: " .. real.stdout)
	ran(t, sh, "printf 'b\\na\\n'")
	local sorted = ran(t, sh, `${sh.blocks[#sh.blocks].number} | ^sort`)
	assert(sorted.stdout == "a\nb\n", sorted.stdout)
end)

test("aliases read from bash, zsh, fish and nu", function()
	local read = shell.aliases.read
	local bash = read("alias ll='ls -l'\nalias say='echo '\\''hi'\\'''\n", "bash")
	assert(bash.ll == "ls -l" and bash.say == "echo 'hi'", bash.say)
	local zsh = read("g=git\nll='ls -l'\n", "zsh")
	assert(zsh.g == "git" and zsh.ll == "ls -l")
	local fish = read("alias ll 'ls -l'\nalias g git\n", "fish")
	assert(fish.ll == "ls -l" and fish.g == "git")
	local nu = read('[{"name":"e","expansion":"hx"},{"name":"mod x","expansion":"y"}]', "nu")
	assert(nu.e == "hx" and nu["mod x"] == nil)
end)

test("a line starting with an alias runs it, showing what was typed", function(t)
	shell.aliases.use({ hi = "echo hello", hello = "hi there", cd = "echo nope", loop = "loop x" })
	local sh = open(t)
	local block = ran(t, sh, "hi world")
	assert(block.command == "hi world", block.command)
	assert(block.stdout == "hello world\n", block.stdout)
	assert(shell.aliases.expand("hello") == "echo hello there", "an alias of an alias")
	assert(shell.aliases.expand("loop") == "loop x", "one naming itself goes in once")
	assert(shell.aliases.expand("cd /") == "cd /", "the shell's builtins win")
	assert(shell.aliases.expand("^hi") == "^hi", "^ skips it")
	assert(shell.aliases.expand("! hi") == "! echo hello", "after !")
	local agent = finished(t, assert(shell.run(sh, "hi || echo none", { by = "agent" })))
	assert(
		not string.find(agent.stdout, "hello", 1, true),
		"an agent's lines aren't: " .. agent.stdout
	)
	shell.aliases.use(nil)
end)

test("which says what a word runs, first what wins", function(t)
	shell.aliases.use({ ll = "ls -l", ls = "ls --color" })
	local sh = open(t)
	local said = ran(t, sh, "which cd where ll ls nowhere-at-all")
	assert(said.code == 1, "one wasn't found")
	assert(string.find(said.stdout, "cd: the shell's builtin", 1, true), said.stdout)
	assert(string.find(said.stdout, "where: a table stage", 1, true), said.stdout)
	assert(string.find(said.stdout, "ll: your alias for ls -l", 1, true), said.stdout)
	assert(string.find(said.stdout, "ls: /[^\n]*/ls %(%^ls runs it%)"), said.stdout)
	assert(string.find(said.stderr, "nowhere-at-all: not found", 1, true), said.stderr)
	shell.aliases.use(nil)
end)

test("the prompt suggests a command typed before, and right takes it", function(t)
	local sh = open(t)
	typed(t, sh, "echo suggested here")
	local view = greed.view()
	shell.log.set_prompt(sh, "echo sug", { view })
	view:set_cursor(sh.buffer:len())
	t:wait_for(function()
		return shell.suggest.suggestion(sh) == "gested here"
	end)
	local marks = sh.buffer:decorations("shell.suggestion")
	assert(#marks == 1 and marks[1].text == "gested here", "shown after the cursor")
	t:keys("right")
	assert(shell.log.prompt_text(sh) == "echo suggested here", shell.log.prompt_text(sh))
	assert(shell.suggest.suggestion(sh) == nil, "nothing more to suggest")
	-- Elsewhere, right moves as it always does.
	shell.log.set_prompt(sh, "echo zzz", { view })
	view:set_cursor(sh.buffer:len() - 1)
	t:keys("right")
	assert(view:cursor() == sh.buffer:len())
end)
