local test = require("@greed/test")
local greed = require("@greed")
local shell = require("@shell")

type Shell = typeof(shell.open())
type Block = typeof(assert(shell.run(shell.open(), "true")))

local function open(t: test.TestContext): Shell
	greed.option.set("shell-fallback", "sh")
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = t:tempdir({ ["pods"] = "NAME    STATUS\napi     Running\nworker  Failed\n" })
	return sh
end

local function finished(t: test.TestContext, block: Block): Block
	t:wait_for(function()
		return block.status ~= "running"
	end)
	return block
end

-- Types `line` at the prompt and runs it; the block it made, finished.
local function type_line(t: test.TestContext, sh: Shell, line: string): Block
	shell.log.set_prompt(sh, line, { greed.view() })
	t:keys("enter")
	return finished(t, sh.blocks[#sh.blocks])
end

-- The text of the line the cursor is on.
local function current(): string
	local view = greed.view()
	local buffer = view:buffer()
	return buffer:line_text(buffer:line_of(view:cursor()))
end

-- What the selected line's hint says, if one shows.
local function hint(): string
	for _, mark in greed.view():buffer():decorations("shell.selected") do
		if mark.lines then
			return tostring(mark.lines[1])
		end
	end
	return ""
end

test("esc at the prompt selects the last command; up and down go between commands", function(t)
	local sh = open(t)
	type_line(t, sh, "echo one")
	type_line(t, sh, "echo two")
	t:keys("esc")
	assert(greed.mode.get() == "blocks", greed.mode.get())
	assert(current() == "echo two", current())
	assert(string.find(hint(), "r run again", 1, true), hint())
	t:keys("up")
	assert(current() == "echo one", current())
	t:keys("k")
	assert(current() == "echo one", "the first stays: " .. current())
	t:keys("j")
	assert(current() == "echo two", current())
	t:keys("g")
	assert(current() == "echo one", current())
end)

test("right goes into a command's rows, down along them, left back out", function(t)
	local sh = open(t)
	type_line(t, sh, "cat pods")
	t:keys("esc right")
	assert(string.find(current(), "^api"), current())
	assert(string.find(hint(), "what it does", 1, true), hint())
	t:keys("down")
	assert(string.find(current(), "^worker"), current())
	t:keys("left")
	assert(current() == "cat pods", current())
end)

test("typing in blocks mode goes back to the prompt with what's typed", function(t)
	local sh = open(t)
	type_line(t, sh, "echo one")
	t:keys("esc x")
	assert(greed.mode.get() ~= "blocks", greed.mode.get())
	assert(shell.log.prompt_text(sh) == "x", shell.log.prompt_text(sh))
	assert(hint() == "", "no selection shows: " .. hint())
	t:keys("esc i")
	assert(greed.mode.get() ~= "blocks" and greed.view():cursor() == sh.buffer:len())
end)

test("enter changes a command at the prompt, and running it runs it in its place", function(t)
	local sh = open(t)
	local one = type_line(t, sh, "echo one")
	type_line(t, sh, "echo two")
	t:keys("esc up enter")
	assert(shell.log.prompt_text(sh) == "echo one", shell.log.prompt_text(sh))
	assert(sh.editing == one, "editing it")
	shell.log.set_prompt(sh, "echo uno", { greed.view() })
	t:keys("enter")
	finished(t, one)
	assert(#sh.blocks == 2, "no new block: " .. #sh.blocks)
	assert(one.command == "echo uno" and one.output == "uno\n", one.output)
	assert(one.before and one.before.output == "one\n", "what it showed is kept")
	assert(sh.editing == nil, "done editing")
end)

test("r runs a command again in its place, and b shows what it showed before", function(t)
	local sh = open(t)
	greed.fs.write(`{sh.cwd}/n`, "first\n")
	local block = type_line(t, sh, "cat n")
	greed.fs.write(`{sh.cwd}/n`, "second\n")
	t:keys("esc r")
	t:wait_for(function()
		return block.output == "second\n"
	end)
	assert(#sh.blocks == 1 and block.output == "second\n", block.output)
	assert(block.before and block.before.output == "first\n")
	assert(
		string.find(hint(), "b before", 1, true),
		`{hint()} mode {greed.mode.get()} line {current()}`
	)
	t:keys("b")
	assert(string.find(greed.view():buffer():text(), "first", 1, true), "shown in a float")
end)

test("the cursor put in a command's output while typing selects what it's on", function(t)
	local sh = open(t)
	type_line(t, sh, "cat pods")
	local buffer = sh.buffer
	local line: number? = nil
	for n = 0, buffer:line_count() - 1 do
		if string.find(buffer:line_text(n), "^worker") then
			line = n
		end
	end
	greed.view():set_cursor(buffer:line_start(assert(line)) + 2)
	-- Told once a frame.
	t:wait(50)
	assert(greed.mode.get() == "blocks", greed.mode.get())
	assert(string.find(current(), "^worker"), current())
end)

test("with shell-blocks off, esc goes to the style's own mode", function(t)
	local sh = open(t)
	greed.option.set("shell-blocks", false)
	type_line(t, sh, "echo one")
	t:keys("esc")
	assert(greed.mode.get() ~= "blocks", greed.mode.get())
end)

test("emptying the prompt stops changing the command, so what's typed next is new", function(t)
	local sh = open(t)
	type_line(t, sh, "echo one")
	t:keys("esc enter")
	assert(sh.editing ~= nil, "editing")
	shell.log.set_prompt(sh, "", { greed.view() })
	t:wait(20)
	assert(sh.editing == nil, "not editing any more")
	type_line(t, sh, "echo two")
	assert(#sh.blocks == 2, "a new block")
end)

test("d shows what changed since the run before, line by line", function(t)
	local sh = open(t)
	greed.fs.write(`{sh.cwd}/n`, "same\nfirst\n")
	local block = type_line(t, sh, "cat n")
	greed.fs.write(`{sh.cwd}/n`, "same\nsecond\n")
	t:keys("esc r")
	t:wait_for(function()
		return block.output == "same\nsecond\n"
	end)
	t:keys("d")
	local shown = greed.view():buffer():text()
	assert(string.find(shown, "  same\n- first\n+ second\n", 1, true), shown)
end)

test("blocks mode works the same in every style", function(t)
	for _, style in { "helix", "vim", "vscode" } do
		greed.option.set("editing-style", style)
		local sh = open(t)
		type_line(t, sh, "echo one")
		t:keys("esc")
		assert(greed.mode.get() == "blocks", `{style}: {greed.mode.get()}`)
		assert(current() == "echo one", `{style}: {current()}`)
		t:keys("x")
		assert(shell.log.prompt_text(sh) == "x", `{style}: {shell.log.prompt_text(sh)}`)
	end
end)

test("r on an earlier command stays on it as it runs, so d compares that one", function(t)
	local sh = open(t)
	greed.fs.write(`{sh.cwd}/n`, "web 20\ndb 50\n")
	local first = type_line(t, sh, "cat n")
	type_line(t, sh, "echo hello")
	greed.fs.write(`{sh.cwd}/n`, "web 25\ndb 50\n")
	t:keys("esc up r")
	t:wait_for(function()
		return first.output == "web 25\ndb 50\n"
	end)
	t:wait(50)
	assert(current() == "cat n", current())
	t:keys("d")
	local shown = greed.view():buffer():text()
	assert(string.find(shown, "- web 20\n+ web 25\n  db 50\n", 1, true), shown)
end)
