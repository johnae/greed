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

test("esc at the prompt selects the last command; J and K go between commands", function(t)
	local sh = open(t)
	type_line(t, sh, "echo one")
	type_line(t, sh, "echo two")
	t:keys("esc")
	assert(greed.mode.get() == "blocks", greed.mode.get())
	assert(current() == "echo two", current())
	assert(string.find(hint(), "r run again", 1, true), hint())
	t:keys("K")
	assert(current() == "echo one", current())
	t:keys("K")
	assert(current() == "echo one", "the first stays: " .. current())
	t:keys("J")
	assert(current() == "echo two", current())
	t:keys("ctrl-up")
	assert(current() == "echo one", current())
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

test(
	"up and down go through everything in order: a command, its rows, the next command",
	function(t)
		local sh = open(t)
		type_line(t, sh, "cat pods")
		type_line(t, sh, "echo two")
		t:keys("esc g")
		assert(current() == "cat pods", current())
		t:keys("down")
		assert(string.find(current(), "^api"), current())
		t:keys("j j")
		assert(current() == "echo two", "past the last row, the next command: " .. current())
		t:keys("up")
		assert(string.find(current(), "^worker"), "back up, the last row: " .. current())
		t:keys("J")
		assert(current() == "echo two", "J from a row: the next command: " .. current())
	end
)

test("text that names nothing has no rows to step through; a file and line is one", function(t)
	local sh = open(t)
	greed.fs.write(`{sh.cwd}/a.txt`, "one\ntwo\n")
	type_line(t, sh, "printf 'just\\nwords\\n'")
	type_line(t, sh, "printf 'see a.txt:2 here\\n'")
	t:keys("esc g down")
	assert(string.find(current(), "^printf 'see"), "past the words: " .. current())
	t:keys("down")
	assert(string.find(current(), "^see a.txt:2"), current())
	local view = greed.view()
	assert(view:buffer():slice(view:cursor(), view:cursor() + 7) == "a.txt:2", "on the file")
	t:keys("enter")
	assert(greed.view():buffer():path() == `{sh.cwd}/a.txt`, "opened")
end)

test("a float showing a block keeps its own keys: esc closes it", function(t)
	local sh = open(t)
	local block = type_line(t, sh, "cat pods")
	local float = assert(shell.peek.open(sh, block, { focus = true }))
	float:set_cursor(float:buffer():line_start(float:buffer():line_count() - 3))
	t:wait(50)
	assert(greed.mode.get() ~= "blocks", greed.mode.get())
	assert(hint() == "", "no hint in the float: " .. hint())
	t:keys("esc")
	assert(not float:valid(), "closed")
end)

test(
	"output without a last line break, run again in place, leaves the next command on a line of its own",
	function(t)
		local sh = open(t)
		local first = type_line(t, sh, "printf 'a\\nb'")
		type_line(t, sh, "echo next")
		t:keys("esc K r")
		t:wait_for(function()
			return first.status ~= "running" and first.before ~= nil
		end)
		t:wait(50)
		type_line(t, sh, "echo last")
		for n = 0, sh.buffer:line_count() - 1 do
			local line = sh.buffer:line_text(n)
			assert(not string.find(line, ".echo next"), "joined: " .. line)
			assert(not string.find(line, ".echo last"), "joined: " .. line)
		end
	end
)

test("in a shell, the style's normal mode is blocks mode", function(t)
	local sh = open(t)
	type_line(t, sh, "echo one")
	-- As coming back to the shell from a file leaves it.
	greed.mode.set(require("@core").style.home())
	t:wait(50)
	assert(greed.mode.get() == "blocks", greed.mode.get())
	assert(current() == "echo one", current())
end)

test("in blocks mode : opens the command line, and keys that type nothing stay", function(t)
	local sh = open(t)
	type_line(t, sh, "echo one")
	t:keys("esc :")
	assert(greed.view():buffer():kind() == "cmdline", greed.view():buffer():kind())
	t:run("command-line-close")
	t:wait(50)
	assert(greed.mode.get() == "blocks", "back: " .. greed.mode.get())
	t:keys("shift-tab")
	assert(greed.mode.get() == "blocks", "shift-tab folds, it doesn't type: " .. greed.mode.get())
	t:keys("f5")
	assert(greed.mode.get() == "blocks", greed.mode.get())
	assert(shell.log.prompt_text(sh) == "", shell.log.prompt_text(sh))
end)

test("a file opened from a level drilled down to opens in the shell's place", function(t)
	local sh = open(t)
	greed.fs.write(`{sh.cwd}/notes.txt`, "hello\n")
	local main = greed.view()
	type_line(t, sh, "ls -l")
	t:keys("esc")
	local block = assert(shell.run(sh, "echo listed", { view = main }))
	finished(t, block)
	-- As an action on a row would: the block shown a level down from the shell.
	shell.drill.open(sh, block, "listed", main)
	local float = greed.view()
	assert(float ~= main and float:float_spec(), "a float")
	greed.open(`{sh.cwd}/notes.txt`)
	t:wait(50)
	assert(not float:valid(), "the float went")
	assert(main:buffer():path() == `{sh.cwd}/notes.txt`, "the file is where the shell was")
end)

test("the running commands on the strip come after the rest, and s stops one", function(t)
	local sh = open(t)
	local first = assert(shell.run(sh, "sleep 30", { view = greed.view() }))
	local second = assert(shell.run(sh, "sleep 31", { view = greed.view() }))
	type_line(t, sh, "echo done")
	t:wait_for(function()
		return sh.strip ~= nil and #sh.strip.blocks >= 1
	end)
	t:keys("esc G")
	assert(current() == "echo done", current())
	t:keys("J")
	assert(string.find(current(), "sleep 3"), "on the strip: " .. current())
	assert(string.find(hint(), "s stop", 1, true), hint())
	local on = sh.strip and sh.strip.blocks[1]
	t:keys("s")
	t:wait_for(function()
		return on ~= nil and on.status ~= "running"
	end)
	shell.kill(first)
	shell.kill(second)
end)

test("space and the leader's keys work in blocks mode", function(t)
	local sh = open(t)
	local running = assert(shell.run(sh, "sleep 30", { view = greed.view() }))
	type_line(t, sh, "echo one")
	t:keys("esc space o w")
	local kind = greed.view():buffer():kind()
	shell.kill(running)
	assert(kind ~= "shell", "what runs is listed: " .. kind)
end)

-- The lines `view` hides, as a list.
local function hidden_in(view: greed.View): { number }
	local lines = {}
	for _, run in view:hidden_lines() do
		for line = run.from, run.to do
			table.insert(lines, line)
		end
	end
	return lines
end

test(
	"/ in a level drilled down to filters that float alone; the shell shows every line",
	function(t)
		local sh = open(t)
		local main = greed.view()
		local block = type_line(t, sh, "printf 'INFO a\\nERROR b\\nINFO c\\n'")
		shell.drill.open(sh, block, "lines", main)
		local float = greed.view()
		t:keys("/ e r r o r")
		local said = tostring(assert(greed.view():float_spec()).title)
		assert(string.find(said, "1 of 3 lines", 1, true), said)
		t:keys("enter")
		assert(float:filter() == "error", tostring(float:filter()))
		local text = sh.buffer:text()
		for _, line in hidden_in(float) do
			local content = sh.buffer:line_text(line)
			assert(not string.find(content, "ERROR", 1, true), "ERROR stays: " .. content)
		end
		assert(#hidden_in(float) >= 2, "the INFO lines go")
		assert(string.find(text, "INFO a", 1, true), "the shell keeps them")
		local shown_in_main = 0
		for _, run in main:hidden_lines() do
			shown_in_main += run.to - run.from + 1
		end
		assert(shown_in_main == 0, "nothing hidden in the shell")
	end
)

test("going back from a command started to show there stops it; ctrl-z keeps it", function(t)
	local sh = open(t)
	local main = greed.view()
	local first = assert(shell.run(sh, "echo up; sleep 30", { view = main }))
	-- Started, so the interrupt reaches it.
	t:wait_for(function()
		return string.find(sh.buffer:text(), "\nup\n", 1, true) ~= nil
	end)
	shell.drill.open(sh, first, "sleeping", main, false, true)
	t:keys("esc")
	t:wait_for(function()
		return first.status ~= "running"
	end)
	for _, style in { "helix", "vim", "vscode" } do
		greed.option.set("editing-style", style)
		local block = assert(shell.run(sh, "sleep 31", { view = main }))
		shell.drill.open(sh, block, "sleeping", main, false, true)
		t:keys("ctrl-z")
		t:wait(50)
		assert(block.status == "running", `{style}: kept running`)
		assert(greed.view() == main, `{style}: back`)
		shell.kill(block)
	end
	t:keys("a b ctrl-z")
	assert(shell.log.prompt_text(sh) ~= "ab", "at the prompt it still undoes")
end)

test("v shows a command in panes beside, each filtered its own way", function(t)
	local sh = open(t)
	type_line(t, sh, "printf 'INFO a\\nERROR b\\n'")
	local main = greed.view()
	t:keys("esc v")
	local first = greed.view()
	assert(first:float_spec() == nil and first:narrowed() ~= nil, "a pane showing the block")
	main:focus()
	t:wait(50)
	assert(greed.mode.get() == "blocks", `back in the shell: {greed.mode.get()}`)
	t:keys("v")
	local second = greed.view()
	assert(second ~= first and second:float_spec() == nil, "another pane")
	-- On the command line, which the filter skips: the line with the cursor shows.
	for _, view in { first, second } do
		local from = assert((view:narrowed()))
		view:set_cursor(sh.buffer:line_start(from))
	end
	first:set_filter("info", { skip = 1 })
	second:set_filter("error", { skip = 1 })
	local function shows(view: greed.View, word: string): boolean
		for _, line in hidden_in(view) do
			if string.find(sh.buffer:line_text(line), word, 1, true) then
				return false
			end
		end
		return true
	end
	assert(shows(first, "INFO") and not shows(first, "ERROR"), "the first keeps INFO")
	assert(shows(second, "ERROR") and not shows(second, "INFO"), "the second keeps ERROR")
	assert(shows(main, "INFO") and shows(main, "ERROR"), "the shell shows it all")
end)

test("a level's footer stops offering to stop its command once it ends", function(t)
	local sh = open(t)
	local main = greed.view()
	local block = assert(shell.run(sh, "echo up; sleep 0.5", { view = main }))
	shell.drill.open(sh, block, "sleeping", main, false, true)
	local float = greed.view()
	local function footer(): string
		local spec = assert(float:float_spec())
		return tostring(spec.footer)
	end
	assert(string.find(footer(), "ctrl-z", 1, true), footer())
	finished(t, block)
	assert(not string.find(footer(), "ctrl-z", 1, true), footer())
end)
