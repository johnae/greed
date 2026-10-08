local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")
local shell = require("@shell")

type Shell = typeof(shell.open())
type Block = typeof(assert(shell.run(shell.open(), "true")))

-- Opens a shell in `dir` and returns it.
local function open(t: test.TestContext, dir: string?): Shell
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	if dir then
		sh.cwd = dir
	end
	return sh
end

-- Types `line` at the prompt and presses enter; returns the block it made.
local function type_line(t: test.TestContext, sh: Shell, line: string): Block
	shell.log.set_prompt(sh, line, { greed.view() })
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
	assert(shell.log.prompt_text(sh) == "")
	-- The prompt shows the folder, as a decoration.
	local prompt = buffer:decorations("shell.prompt")
	local shown = false
	for _, mark in prompt do
		shown = shown or (mark.eol == true and mark.text == core.project.tilde(dir))
	end
	assert(shown, "the folder after the prompt")
end)

test("a failing command says how it ended, beside its command", function(t)
	local sh = open(t, t:tempdir())
	local typed = finished(t, type_line(t, sh, "sh -c 'echo out; echo err >&2; exit 3'"))
	assert(typed.status == "failed" and typed.code == 3, `{typed.status} {typed.code}`)
	assert(typed.via == "argv" and typed.runner == "pty", typed.runner)
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
	assert(#block.stderr > 0, "says why")
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
	shell.log.set_prompt(sh, "clear", { greed.view() })
	t:keys("enter")
	assert(#sh.blocks == 0 and text() == "", text())
	shell.log.set_prompt(sh, "open notes.txt", { greed.view() })
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
	assert(shell.log.in_prompt(sh, greed.view():cursor()))
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
	assert(shell.log.prompt_text(sh) == "pwd", shell.log.prompt_text(sh))
	assert(core.style.is_typing(), greed.mode.get())
	t:keys("esc")
	greed.view():set_cursor(0)
	t:keys("space v")
	assert(greed.view():buffer():text() == first.output, greed.view():buffer():text())
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
	local from = shell.log.output_range(sh, done)
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
