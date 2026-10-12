local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")
local shell = require("@shell")
local log = require("../log")

type Shell = typeof(shell.open())
type Block = typeof(assert(shell.run(shell.open(), "true")))

-- Opens a shell in `dir` and returns it.
local function open(t: test.TestContext, dir: string?): Shell
	-- These go about the shell as text; blocks mode has tests of its own.
	greed.option.set("shell-blocks", false)
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	if dir then
		sh.cwd = dir
	end
	return sh
end

-- Types `line` at the prompt and presses enter; returns the block it made.
local function type_line(t: test.TestContext, sh: Shell, line: string): Block
	log.set_prompt(sh, line, { greed.view() })
	local before = #sh.blocks
	t:keys("enter")
	assert(#sh.blocks == before + 1, `a block for {line}: {#sh.blocks}`)
	return sh.blocks[#sh.blocks]
end

local function finished(t: test.TestContext, block: Block): Block
	t:wait_for(function()
		return block.status ~= "running"
	end)
	return block
end

local function text(): string
	return greed.view():buffer():text()
end

-- The marks of `block` in its namespace.
local function marks(sh: Shell, block: Block): { greed.Mark }
	return sh.buffer:decorations(`shell.block.{block.uid}`)
end

-- The status text shown after `block`'s command.
local function status(sh: Shell, block: Block): string
	for _, mark in marks(sh, block) do
		if mark.eol then
			return mark.text or ""
		end
	end
	return ""
end

test(":shell opens a buffer of blocks with the prompt at the bottom", function(t)
	local dir = t:tempdir()
	local sh = open(t, dir)
	local buffer = greed.view():buffer()
	assert(buffer:kind() == "shell", buffer:kind())
	assert(buffer:language() == "greed-shell", tostring(buffer:language()))
	assert(core.style.is_typing(), greed.mode.get())
	t:keys("e c h o space h i enter")
	local block = finished(t, sh.blocks[1])
	assert(text() == "echo hi\nhi\n", text())
	assert(block.code == 0 and block.status == "done", block.status)
	assert(block.output == "hi\n" and block.stdout == "hi\n", block.output)
	assert(block.cwd == dir)
	assert(string.find(status(sh, block), "✓", 1, true), status(sh, block))
	-- The cursor is back at the empty prompt.
	assert(greed.view():cursor() == buffer:len())
	assert(log.prompt_text(sh) == "")
	-- The prompt shows the folder before the glyph, as decorations.
	local texts = {}
	for _, mark in buffer:decorations("shell.prompt") do
		if mark.text then
			table.insert(texts, mark.text)
		end
	end
	local short = log.short_folder(dir)
	assert(table.concat(texts) == `{short} ❯ `, table.concat(texts, "|"))
	local drawn = table.concat(t:draw(80, 10), "\n")
	assert(string.find(drawn, `{short} ❯ \n`, 1, true), drawn)
end)

test("backspace at the prompt after output ending in a multi-byte character", function(t)
	local sh = open(t)
	finished(t, type_line(t, sh, "echo ⎇ ❯"))
	assert(text() == "echo ⎇ ❯\n⎇ ❯\n", text())
	assert(core.style.is_typing(), greed.mode.get())
	t:keys("x ❯ backspace")
	assert(log.prompt_text(sh) == "x", log.prompt_text(sh))
	t:keys("backspace backspace")
	assert(log.prompt_text(sh) == "", log.prompt_text(sh))
	assert(string.find(text(), "⎇ ❯\n", 1, true), text())
end)

test("a prompt of many lines, like a pasted transcript, runs only once you say so", function(t)
	local sh = open(t, t:tempdir())
	local pasted = "kubectl get pods\nNAME   READY\napi    1/1\ndb     1/1\ncache  1/1\nweb    1/1"
	log.set_prompt(sh, pasted, { greed.view() })
	t:keys("enter")
	local messages = t:messages()
	assert(messages[#messages] == "run these 6 lines as one command? y/n", messages[#messages])
	t:keys("n")
	assert(#sh.blocks == 0, "nothing ran")
	assert(log.prompt_text(sh) == pasted, "and the prompt is as it was")
	t:keys("enter y")
	assert(#sh.blocks == 1, "y runs it")
	-- A few lines run as they are.
	type_line(t, sh, "echo a\necho b")
end)

test("the prompt's folder is short, and a new shell says where help is", function(t)
	local home = assert(greed.fs.dirs().home)
	assert(log.short_folder(home .. "/Development/greed") == "~/D/greed")
	assert(log.short_folder(home .. "/.config/greed") == "~/.c/greed")
	assert(log.short_folder("/usr/local/bin") == "/u/l/bin")
	assert(log.short_folder(home) == "~")
	local sh = open(t, t:tempdir())
	local said = table.concat(t:draw(80, 10), "\n")
	assert(string.find(said, "type help for what works here", 1, true), said)
	finished(t, type_line(t, sh, "true"))
	said = table.concat(t:draw(80, 10), "\n")
	assert(not string.find(said, "type help", 1, true), "gone once something ran: " .. said)
end)

test("help lists the builtins, what a line can hold, the shell and the keys", function(t)
	greed.option.set("shell-fallback", "sh")
	local sh = open(t, t:tempdir())
	local block = finished(t, type_line(t, sh, "help"))
	for _, said in { "cd", "export", "$3 | cmd", "buf:NAME", "@sel", "!cmd", "runs in sh" } do
		assert(string.find(block.output, said, 1, true), `{said}: {block.output}`)
	end
	assert(string.find(block.output, "space r", 1, true), block.output)
	greed.option.set("editing-style", "vscode")
	local vscode = finished(t, assert(shell.run(sh, "help")))
	assert(string.find(vscode.output, "ctrl-space r", 1, true), vscode.output)
	assert(string.find(vscode.output, "vscode style", 1, true), vscode.output)
end)

test("no block decoration styles a command's or its output's text", function(t)
	greed.option.set("shell-max-lines", 4)
	local sh = open(t, t:tempdir())
	local block = finished(t, type_line(t, sh, "printf 'a\\nb\\nc\\nd\\ne\\nf\\n'"))
	assert(block.omitted == 2, tostring(block.omitted))
	local buffer = sh.buffer
	for _, ns in { `shell.block.{block.uid}`, "shell.prompt" } do
		for _, mark in buffer:decorations(ns) do
			assert(mark.from == mark.to, `{ns} styles {buffer:slice(mark.from, mark.to)}`)
		end
	end
	-- The last line's output looks like the others: only its own styles.
	assert(#buffer:decorations(`shell.out.{block.uid}`) == 0, "plain output has no styles")
end)

test("a failing command says how it ended, beside its command", function(t)
	local sh = open(t, t:tempdir())
	local typed = finished(t, type_line(t, sh, "sh -c 'echo out; echo err >&2; exit 3'"))
	assert(typed.status == "failed" and typed.code == 3, `{typed.status} {typed.code}`)
	assert(typed.via == "shell" and typed.runner == "pty", typed.runner)
	-- In a pseudo terminal what it prints comes merged, in order.
	assert(typed.output == "out\nerr\n", typed.output)
	assert(string.find(status(sh, typed), "✗ exit 3", 1, true), status(sh, typed))
	local sign = false
	for _, mark in marks(sh, typed) do
		sign = sign or mark.sign == "✗"
	end
	assert(sign, "a sign beside it")
	-- Through a pipe, as agents run commands, errors come apart and are
	-- styled as errors.
	local line = "sh -c 'echo out; echo err >&2; exit 3'"
	local block = finished(t, assert(shell.run(sh, line, { runner = "pipe" })))
	assert(block.runner == "pipe" and block.code == 3, block.runner)
	assert(block.stdout == "out\n" and block.stderr == "err\n", block.stderr)
	local styled = {}
	for _, mark in sh.buffer:decorations(`shell.out.{block.uid}`) do
		if mark.style == "shell.stderr" then
			table.insert(styled, sh.buffer:slice(mark.from, mark.to))
		end
	end
	assert(#styled == 1 and styled[1] == "err", table.concat(styled, ","))
end)

test("a program that isn't there fails to start", function(t)
	local sh = open(t, t:tempdir())
	local block = finished(t, type_line(t, sh, "no-such-program-here"))
	assert(block.status == "failed" and block.code == 127, `{block.status} {block.code}`)
	-- The shell says why, in the merged output of its terminal.
	assert(string.find(block.output, "not found", 1, true), block.output)
end)

test("plain programs and pipes both go through your shell", function(t)
	greed.option.set("shell-fallback", "sh")
	local sh = open(t, t:tempdir({ ["a.txt"] = "" }))
	local plain = finished(t, type_line(t, sh, "ls"))
	local piped = finished(t, type_line(t, sh, "ls | cat"))
	assert(plain.via == "shell" and piped.via == "shell", plain.via)
	assert(plain.program == "sh" and plain.output == piped.output, plain.output)
	-- A variable set for one program works as in a terminal.
	local one = finished(t, type_line(t, sh, "GREED_ONE=1 printenv GREED_ONE"))
	assert(one.output == "1\n", one.output)
	-- The shell's own builtins still run without it.
	local env = finished(t, type_line(t, sh, "env"))
	assert(env.via == "builtin", env.via)
end)

test("cd, export and unset change the shell for the commands after", function(t)
	local dir = t:tempdir({ ["sub/x.txt"] = "x" })
	local sh = open(t, dir)
	local cd = finished(t, type_line(t, sh, "cd sub"))
	assert(cd.status == "done" and sh.cwd == dir .. "/sub", sh.cwd)
	assert(string.find(status(sh, cd), "→", 1, true), status(sh, cd))
	local pwd = finished(t, type_line(t, sh, "pwd"))
	assert(pwd.output == dir .. "/sub\n", pwd.output)
	finished(t, type_line(t, sh, "cd -"))
	assert(sh.cwd == dir, sh.cwd)
	local bad = finished(t, type_line(t, sh, "cd nowhere"))
	assert(bad.status == "failed" and sh.cwd == dir, bad.output)
	finished(t, type_line(t, sh, "export GREED_SHELL_TEST='a b'"))
	local function var(): string | false | nil
		return sh.env.GREED_SHELL_TEST
	end
	assert(var() == "a b")
	local shown = finished(t, type_line(t, sh, "printenv GREED_SHELL_TEST"))
	assert(shown.output == "a b\n", shown.output)
	local listed = finished(t, type_line(t, sh, "env"))
	assert(listed.output == "GREED_SHELL_TEST=a b\n", listed.output)
	finished(t, type_line(t, sh, "unset GREED_SHELL_TEST"))
	assert(var() == false)
	local gone = finished(t, type_line(t, sh, "printenv GREED_SHELL_TEST"))
	assert(gone.code == 1, tostring(gone.code))
	-- Pagers are off, so output comes back as text.
	local pager = finished(t, type_line(t, sh, "printenv PAGER GIT_PAGER"))
	assert(pager.output == "cat\ncat\n", pager.output)
end)

test("an agent's cd and export show in its block but leave the shell alone", function(t)
	local dir = t:tempdir({ ["sub/x.txt"] = "x" })
	local sh = open(t, dir)
	local cd = assert(shell.run(sh, "cd sub", { by = "agent" }))
	finished(t, cd)
	assert(cd.cwd_after == dir .. "/sub" and sh.cwd == dir, sh.cwd)
	local export = assert(shell.run(sh, "export X=1", { by = "agent" }))
	finished(t, export)
	assert(export.env_changed and export.env_changed.X == "1")
	assert(sh.env.X == nil)
	local glyph = false
	for _, mark in marks(sh, cd) do
		glyph = glyph or mark.text == "◆ "
	end
	assert(glyph, "marked as an agent's")
end)

test("lines with pipes or globs go to a real shell", function(t)
	greed.option.set("shell-fallback", "sh")
	local sh = open(t, t:tempdir({ ["a.log"] = "", ["b.log"] = "" }))
	local block = finished(t, type_line(t, sh, "ls *.log | tr a-z A-Z"))
	assert(block.via == "shell" and block.program == "sh", block.via)
	assert(block.output == "A.LOG\nB.LOG\n", block.output)
end)

test("open, history and clear are the shell's own", function(t)
	local dir = t:tempdir({ ["notes.txt"] = "hello" })
	local sh = open(t, dir)
	finished(t, type_line(t, sh, "echo one"))
	local history = finished(t, type_line(t, sh, "history"))
	assert(string.find(history.output, "1  echo one", 1, true), history.output)
	log.set_prompt(sh, "clear", { greed.view() })
	t:keys("enter")
	assert(#sh.blocks == 0 and text() == "", text())
	log.set_prompt(sh, "open notes.txt", { greed.view() })
	t:keys("enter")
	assert(
		greed.view():buffer():path() == dir .. "/notes.txt",
		tostring(greed.view():buffer():path())
	)
	assert(sh.blocks[1].status == "done")
end)

test("blocks fold under their command and [ p ] p go between them", function(t)
	local sh = open(t, t:tempdir())
	local one = finished(t, type_line(t, sh, "printf 'a\\nb\\n'"))
	local two = finished(t, type_line(t, sh, "echo c"))
	assert(text() == "printf 'a\\nb\\n'\na\nb\necho c\nc\n", text())
	local top, bottom = core.folds.block(sh.buffer, 1)
	assert(top == 0 and bottom == 2, `{top} {bottom}`)
	t:keys("esc")
	t:keys("[ p")
	assert(greed.view():cursor() == sh.buffer:line_start(3), tostring(greed.view():cursor()))
	t:keys("[ p")
	assert(greed.view():cursor() == 0)
	t:keys("g o")
	local range = greed.view():selection().ranges[1]
	assert(
		sh.buffer:slice(range.anchor, range.head + 1) == "a\nb",
		sh.buffer:slice(range.anchor, range.head + 1)
	)
	t:keys("] p ] p")
	assert(log.in_prompt(sh, greed.view():cursor()))
	assert(one.number == 1 and two.number == 2)
end)

test("a block runs again, is edited, copied, and its output opened", function(t)
	local dir = t:tempdir({ ["sub/x.txt"] = "x" })
	local sh = open(t, dir)
	local first = finished(t, type_line(t, sh, "pwd"))
	finished(t, type_line(t, sh, "cd sub"))
	t:keys("esc")
	greed.view():set_cursor(0)
	t:keys("space r")
	local again = finished(t, sh.blocks[#sh.blocks])
	assert(again.output == dir .. "\n", "as it ran: " .. again.output)
	greed.view():set_cursor(0)
	t:keys("space R")
	local here = finished(t, sh.blocks[#sh.blocks])
	assert(here.output == dir .. "/sub\n", "here: " .. here.output)
	greed.view():set_cursor(0)
	t:keys("space y")
	assert(table.concat(greed.clipboard.get() or {}) == dir .. "\n")
	t:keys("space Y")
	assert(table.concat(greed.clipboard.get() or {}) == "pwd")
	greed.view():set_cursor(0)
	t:keys("enter")
	assert(log.prompt_text(sh) == "pwd", log.prompt_text(sh))
	assert(core.style.is_typing(), greed.mode.get())
	t:keys("esc")
	greed.view():set_cursor(0)
	t:keys("space v")
	assert(greed.view():buffer():text() == first.output, greed.view():buffer():text())
end)

test("blocks still running when their shell closes end, as each way of running ends", function(t)
	greed.option.set("shell-fallback", "sh")
	local sh = shell.open({ cwd = t:tempdir(), show = false })
	local running = {
		assert(shell.run(sh, "sleep 30")),
		assert(shell.run(sh, "sleep 30", { runner = "pipe" })),
		assert(shell.run(sh, "watch -n 1 sleep 30")),
	}
	-- A line with table stages runs its programs in the caller.
	greed.spawn(shell.run, sh, "sleep 30 | lines")
	table.insert(running, sh.blocks[#sh.blocks])
	-- Each program's end comes after the shell has gone.
	sh.buffer:close()
	for _, block in running do
		finished(t, block)
		assert(block.status == "killed", `{block.command}: {block.status}`)
	end
end)

test("ctrl-c interrupts the running block, and space x stops one", function(t)
	local sh = open(t, t:tempdir())
	local block = type_line(t, sh, "sleep 30")
	t:keys("ctrl-c")
	finished(t, block)
	assert(block.status == "killed" and block.signal == "INT", `{block.status} {block.signal}`)
	assert(string.find(status(sh, block), "■ INT", 1, true), status(sh, block))
	local other = type_line(t, sh, "sleep 30")
	t:keys("esc space x")
	finished(t, other)
	assert(other.status == "killed", other.status)
end)

test("in the vscode style ctrl-c copies a selection, and interrupts without one", function(t)
	greed.option.set("editing-style", "vscode")
	local sh = open(t, t:tempdir())
	local done = finished(t, type_line(t, sh, "echo copied"))
	local running = type_line(t, sh, "sleep 30")
	local from = log.output_range(sh, done)
	greed.view():set_selection({
		ranges = { { anchor = assert(from), head = assert(from) + 6 } },
		primary = 1,
	})
	t:keys("ctrl-c")
	assert(running.status == "running", "copying leaves it running")
	assert(
		table.concat(greed.clipboard.get() or {}) == "copied",
		table.concat(greed.clipboard.get() or {})
	)
	greed.view():set_cursor(sh.buffer:len())
	t:keys("ctrl-c")
	finished(t, running)
	assert(running.signal == "INT", tostring(running.signal))
end)

test("enter runs the prompt in every style", function(t)
	for _, style in { "helix", "vim", "vscode" } do
		greed.option.set("editing-style", style)
		local sh = open(t, t:tempdir())
		t:keys("e c h o space o k enter")
		assert(#sh.blocks == 1, style)
		finished(t, sh.blocks[1])
		assert(sh.blocks[1].output == "ok\n", `{style}: {sh.blocks[1].output}`)
		-- Outside the prompt, enter types a line break.
		greed.view():set_cursor(0)
		t:keys("enter")
		assert(#sh.blocks == 1, style)
	end
end)

test("long output keeps its first and last lines, and the record spills to a file", function(t)
	greed.option.set("shell-max-lines", 10)
	local sh = open(t, t:tempdir())
	local block = finished(t, type_line(t, sh, "seq 1 100"))
	local lines = string.split(text(), "\n")
	assert(lines[2] == "1" and lines[6] == "5" and lines[7] == "96" and lines[11] == "100", text())
	assert(block.lines == 100 and block.omitted == 90, `{block.lines} {block.omitted}`)
	local said = false
	for _, mark in marks(sh, block) do
		local first = mark.lines and mark.lines[1]
		said = said
			or (
				type(first) == "string"
				and string.find(first, "90 lines not shown", 1, true) ~= nil
			)
	end
	assert(said, "says how many lines it leaves out")
	assert(not block.truncated and #block.output == 292, tostring(#block.output))
	greed.option.set("shell-max-record", 100)
	local big = finished(t, type_line(t, sh, "seq 1 1000"))
	assert(big.truncated and #big.output == 100, tostring(#big.output))
	local spill = assert(big.spill, "spilled")
	local whole = assert(greed.fs.read(spill))
	assert(#whole == 3893 and string.sub(whole, -5) == "1000\n", tostring(#whole))
	-- What's shown stays within the cap either way.
	assert(sh.buffer:line_count() < 40, tostring(sh.buffer:line_count()))
end)

test("a flood of output through a pipe keeps its first and last lines", function(t)
	greed.option.set("shell-max-lines", 10)
	local sh = open(t, t:tempdir())
	local block = finished(t, assert(shell.run(sh, "seq 1 100000", { runner = "pipe" })))
	assert(block.lines == 100000 and block.omitted == 99990, `{block.lines} {block.omitted}`)
	local shown = {}
	for line = 1, 10 do
		table.insert(shown, sh.buffer:line_text(line))
	end
	assert(
		table.concat(shown, " ") == "1 2 3 4 5 99996 99997 99998 99999 100000",
		table.concat(shown, " ")
	)
	assert(string.sub(block.output, -7) == "100000\n")
end)

test("two clients each wrap a block at their own width", function(t)
	local sh = open(t, t:tempdir())
	local long = string.rep("x", 100)
	local block = finished(t, type_line(t, sh, `echo {long}`))
	assert(text() == `echo {long}\n{long}\n`, "one buffer line per line printed")
	local other = t:client("wide")
	local narrow = t:draw(40, 20)
	local wide = other:draw(140, 20)
	local function rows_with_x(rows: { string }): number
		local count = 0
		for _, row in rows do
			if string.find(row, "xxxxxxxxxx", 1, true) then
				count += 1
			end
		end
		return count
	end
	-- The command and its output are each one line at 140 columns, and
	-- three rows each at 40.
	assert(rows_with_x(wide) == 2, table.concat(wide, "\n"))
	assert(rows_with_x(narrow) >= 6, table.concat(narrow, "\n"))
	-- The status is after the command at either width, as a decoration.
	assert(string.find(table.concat(wide, "\n"), "✓", 1, true), table.concat(wide, "\n"))
	assert(block.status == "done")
end)

test("a project can have several shells, each with its own folder", function(t)
	local a = t:tempdir()
	local b = t:tempdir()
	local one = open(t, a)
	local two = open(t, b)
	assert(one.name == "shell" and two.name == "shell 2", two.name)
	local here = finished(t, type_line(t, two, "pwd"))
	assert(here.output == b .. "\n")
	t:keys("esc space o s")
	local floats = table.concat(t:floats(), "\n")
	assert(
		string.find(floats, "shell 2", 1, true) and string.find(floats, "new shell", 1, true),
		floats
	)
end)

test("undo at the prompt takes back only what was typed, while output streams in", function(t)
	local sh = open(t, t:tempdir())
	local block = assert(shell.run(sh, "sh -c 'echo started; read x; echo more; echo lines'", {
		view = greed.view(),
	}))
	t:wait_for(function()
		return string.find(sh.buffer:text(), "started", 1, true) ~= nil
	end)
	-- Typed in one insert, which undo takes back as one step.
	t:keys("esc")
	greed.view():set_cursor(sh.buffer:len())
	t:keys("i e c h o")
	assert(log.prompt_text(sh) == "echo", log.prompt_text(sh))
	-- More output arrives above while the typing is at the prompt.
	assert(assert(block.job).terminal):key("enter")
	finished(t, block)
	assert(string.find(sh.buffer:text(), "more\nlines\n", 1, true), sh.buffer:text())
	assert(log.prompt_text(sh) == "echo", log.prompt_text(sh))
	local blocks = sh.buffer:slice(0, log.prompt_start(sh))
	t:keys("esc")
	t:run("undo")
	assert(log.prompt_text(sh) == "", "the typing went: " .. log.prompt_text(sh))
	assert(sh.buffer:slice(0, log.prompt_start(sh)) == blocks, sh.buffer:text())
	t:run("redo")
	assert(log.prompt_text(sh) == "echo", log.prompt_text(sh))
	-- Running it takes what's typed into a block, and undo doesn't bring it
	-- back to the prompt.
	t:keys("i enter")
	finished(t, sh.blocks[2])
	t:keys("esc")
	t:run("undo")
	assert(log.prompt_text(sh) == "", log.prompt_text(sh))
	assert(sh.blocks[2].command == "echo" and string.find(sh.buffer:text(), "\necho\n\n", 1, true))
end)

test("undo after a run takes back only what was typed since", function(t)
	local sh = open(t, t:tempdir())
	-- A typo taken back with backspace: undoing that would put it back.
	t:keys("e c h o space o n e x backspace enter")
	finished(t, sh.blocks[1])
	t:keys("p esc")
	for _ = 1, 3 do
		t:run("undo")
		local typed = log.prompt_text(sh)
		assert(typed == "", "nothing from before the run: " .. typed)
	end
	assert(sh.blocks[1].command == "echo one", sh.blocks[1].command)
end)

test("each block shows its number beside its command, for $N", function(t)
	local sh = open(t, t:tempdir())
	type_line(t, sh, "echo one")
	local second = finished(t, type_line(t, sh, "echo two"))
	assert(second.number == 2)
	local texts: { string } = {}
	for _, mark in marks(sh, second) do
		if mark.text and not mark.eol then
			table.insert(texts, mark.text)
		end
	end
	assert(table.concat(texts) == "❯ 2 ", table.concat(texts, "|"))
	local drawn = table.concat(t:draw(80, 10), "\n")
	assert(string.find(drawn, "❯ 2 echo two", 1, true), drawn)
end)

test("typing at the prompt is nothing to save: no [+], and :q goes ahead", function(t)
	local sh = open(t, t:tempdir())
	t:keys("e c h o")
	assert(sh.buffer:modified(), "typed")
	local drawn = table.concat(t:draw(80, 6), "\n")
	assert(not string.find(drawn, "[+]", 1, true), drawn)
	t:run("quit")
	assert(t:quitting(), "quit")
end)

test("space o s goes to the only shell, and picks among several", function(t)
	local sh = open(t, t:tempdir())
	t:buffer("|abc")
	t:keys("esc space o s")
	assert(greed.view():buffer() == sh.buffer, "switched to it")
	assert(#t:floats() == 0, "no picker")
	-- From the only shell, the picker offers a new one.
	t:keys("esc space o s")
	assert(#t:floats() > 0, "a picker")
end)

test("open from the shell opens files in the style's own mode", function(t)
	local dir = t:tempdir({ ["notes.txt"] = "hello" })
	local sh = open(t, dir)
	finished(t, type_line(t, sh, "open notes.txt"))
	assert(greed.view():buffer():path() == dir .. "/notes.txt", "opened")
	t:expect_mode(require("@core").style.home())
end)

test("new shell here on a folder opens a shell starting in it", function(t)
	local dir = t:tempdir({ ["sub/x.txt"] = "" })
	for _, action in core.actions.for_kind("folder") do
		if action.name == "new shell here" then
			action.run({ kind = "folder", label = "sub", value = dir .. "/sub" })
		end
	end
	local sh = assert(shell.of(greed.view():buffer()), "a shell")
	assert(sh.cwd == dir .. "/sub", sh.cwd)
end)
