local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")
local shell = require("@shell")

type Shell = typeof(shell.open())

local function open(t: test.TestContext, dir: string): Shell
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = dir
	return sh
end

local function at_prompt(sh: Shell): string
	return shell.log.prompt_text(sh)
end

-- Puts `text` at the prompt and asks what could complete it, with tab
-- while typing.
local function complete(t: test.TestContext, sh: Shell, text: string): string
	shell.log.set_prompt(sh, text, { greed.view() })
	greed.mode.set(core.style.typing_mode())
	t:keys("tab")
	return table.concat(t:floats(), "\n")
end

test("tab completes programs on PATH and builtins for a command's first word", function(t)
	local dir = t:tempdir({ ["bin/greedtestprog"] = "", ["bin/other"] = "" })
	local sh = open(t, dir)
	shell.run(sh, `export PATH={dir}/bin`)
	local menu = complete(t, sh, "greedtest")
	assert(string.find(menu, "greedtestprog", 1, true), menu)
	t:keys("enter")
	assert(at_prompt(sh) == "greedtestprog", "enter takes it, without running: " .. at_prompt(sh))
	assert(#sh.blocks == 1)
	local builtins = complete(t, sh, "expo")
	assert(string.find(builtins, "export", 1, true), builtins)
end)

test("tab completes files and folders from the shell's folder", function(t)
	local dir = t:tempdir({ ["subdir/inner.txt"] = "", ["other.txt"] = "" })
	local sh = open(t, dir)
	local menu = complete(t, sh, "cat subd")
	assert(string.find(menu, "subdir/", 1, true), menu)
	t:keys("enter")
	assert(at_prompt(sh) == "cat subdir/", at_prompt(sh))
	local inner = complete(t, sh, "cat subdir/in")
	assert(string.find(inner, "subdir/inner.txt", 1, true), inner)
	t:keys("enter")
	assert(at_prompt(sh) == "cat subdir/inner.txt", at_prompt(sh))
end)

test("tab completes variables, earlier blocks and open files", function(t)
	local dir = t:tempdir({ ["notes.md"] = "hi" })
	local sh = open(t, dir)
	shell.run(sh, "export GREED_COMPLETE_ME=1")
	local vars = complete(t, sh, "echo $GREED_COMPLETE")
	assert(string.find(vars, "$GREED_COMPLETE_ME", 1, true), vars)
	t:keys("enter")
	assert(at_prompt(sh) == "echo $GREED_COMPLETE_ME", at_prompt(sh))
	t:keys("esc")
	local blocks = complete(t, sh, "echo $1")
	assert(
		string.find(blocks, "$1", 1, true) and string.find(blocks, "export GREED", 1, true),
		blocks
	)
	t:keys("esc")
	greed.load(dir .. "/notes.md")
	local bufs = complete(t, sh, "cat buf:no")
	assert(string.find(bufs, "buf:notes.md", 1, true), bufs)
end)

test("output streaming above the prompt leaves the completion menu working", function(t)
	local dir = t:tempdir({ ["subdir/inner.txt"] = "" })
	local sh = open(t, dir)
	local block = assert(shell.run(sh, "sh -c 'echo started; read x; echo more; echo lines'", {
		view = greed.view(),
	}))
	t:wait_for(function()
		return string.find(sh.buffer:text(), "started", 1, true) ~= nil
	end)
	local menu = complete(t, sh, "cat subd")
	assert(string.find(menu, "subdir/", 1, true), menu)
	local term = assert(assert(block.job).terminal)
	term:key("enter")
	t:wait_for(function()
		return block.status ~= "running"
	end)
	assert(#t:floats() == 1, "the menu stays open")
	t:keys("enter")
	assert(at_prompt(sh) == "cat subdir/", at_prompt(sh))
end)
