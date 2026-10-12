local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")
local shell = require("@shell")

type Shell = typeof(shell.open())
type Block = typeof(assert(shell.run(shell.open(), "true")))

local function open(t: test.TestContext): Shell
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = t:tempdir()
	return sh
end

local function type_line(t: test.TestContext, sh: Shell, line: string): Block
	shell.log.set_prompt(sh, line, { greed.view() })
	t:keys("enter")
	return sh.blocks[#sh.blocks]
end

local function finished(t: test.TestContext, block: Block): Block
	t:wait_for(function()
		return block.status ~= "running"
	end)
	return block
end

-- The terminal `block` runs in.
local function terminal_of(block: Block): greed.Terminal
	local job = assert(block.job, "running")
	return assert(job.terminal, "in a pseudo terminal")
end

-- Waits until `block`'s program wants a terminal of its own, then lets the
-- moment the shell waits to be sure go by.
local function settles(t: test.TestContext, block: Block)
	local term = terminal_of(block)
	t:wait_for(function()
		local modes = term:modes()
		return modes.alternate or not modes.canonical or not modes.echo
	end)
	t:wait(250)
end

local function status(sh: Shell, block: Block): string
	for _, mark in sh.buffer:decorations(`shell.block.{block.uid}`) do
		if mark.eol then
			return mark.text or ""
		end
	end
	return ""
end

test("typed commands run in a pseudo terminal, with their colors", function(t)
	local sh = open(t)
	local block = finished(t, type_line(t, sh, "printf '\\033[31mred\\033[0m plain\\n'"))
	assert(block.runner == "pty", block.runner)
	assert(block.output == "red plain\n", block.output)
	local styled = {}
	for _, mark in sh.buffer:decorations(`shell.out.{block.uid}`) do
		table.insert(styled, `{sh.buffer:slice(mark.from, mark.to)}={mark.style}`)
	end
	assert(table.concat(styled, ",") == "red==fg:red", table.concat(styled, ","))
	-- A program sees a terminal.
	local tty = finished(t, type_line(t, sh, "sh -c 'test -t 1 && echo tty'"))
	assert(tty.output == "tty\n", tty.output)
end)

test("a line longer than the screen stays one line", function(t)
	t:draw(40, 20)
	local sh = open(t)
	local block = finished(t, type_line(t, sh, "printf '%0150d\\n' 0"))
	local long = string.rep("0", 150)
	assert(block.output == long .. "\n", block.output)
	assert(sh.buffer:line_text(1) == long, sh.buffer:line_text(1))
	assert(sh.buffer:line_count() == 3, tostring(sh.buffer:line_count()))
end)

test("lines that scroll off the screen are kept as they come", function(t)
	t:draw(80, 10)
	local sh = open(t)
	local block = finished(t, type_line(t, sh, "seq 1 500"))
	assert(block.lines == 500, tostring(block.lines))
	local lines = string.split(block.output, "\n")
	assert(lines[1] == "1" and lines[500] == "500" and #lines == 501, tostring(#lines))
	assert(sh.buffer:line_text(500) == "500")
end)

test("a full screen program is handed to a terminal and comes back", function(t)
	local sh = open(t)
	local view = greed.view()
	local script = "printf '\\033[?1049h'; read x; printf '\\033[?1049l'; echo back; exit 4"
	local block = type_line(t, sh, `sh -c "{script}"`)
	settles(t, block)
	assert(view:buffer():kind() == "terminal", view:buffer():kind())
	assert(greed.mode.get() == "terminal", greed.mode.get())
	-- What's typed goes to the program now.
	t:keys("enter")
	finished(t, block)
	t:wait_for(function()
		return view:buffer() == sh.buffer
	end)
	assert(block.handed and block.code == 4, `{block.handed} {block.code}`)
	local said = status(sh, block)
	assert(string.find(said, "↗ exit 4", 1, true), said)
	assert(string.find(block.output, "back", 1, true), block.output)
	-- Back at the prompt, typing.
	assert(core.style.is_typing(), greed.mode.get())
	assert(view:cursor() == sh.buffer:len())
end)

test("a program reading keys raw is handed to a terminal", function(t)
	local sh = open(t)
	local view = greed.view()
	local script = "stty raw -echo; dd bs=1 count=1 >/dev/null 2>&1; stty sane; echo got it"
	local block = type_line(t, sh, `sh -c '{script}'`)
	settles(t, block)
	assert(view:buffer():kind() == "terminal", view:buffer():kind())
	t:keys("x")
	finished(t, block)
	t:wait_for(function()
		return view:buffer() == sh.buffer
	end)
	assert(block.handed and block.status == "done", block.status)
	assert(string.find(block.output, "got it", 1, true), block.output)
end)

test(
	"a program quiet after a question may be waiting for input, and ctrl-t types into it",
	function(t)
		local sh = open(t)
		local view = greed.view()
		local block = type_line(t, sh, "sh -c 'printf \"name? \"; read x; echo got $x'")
		assert(not block.waiting)
		t:wait_for(function()
			return (block.waiting :: boolean?) == true
		end)
		local said = status(sh, block)
		assert(string.find(said, "waiting for input", 1, true), said)
		assert(view:buffer() == sh.buffer, "a line mode program isn't handed over on its own")
		t:keys("ctrl-t")
		assert(view:buffer():kind() == "terminal", view:buffer():kind())
		t:keys("h i enter")
		finished(t, block)
		assert(string.find(block.output, "got hi", 1, true), block.output)
		t:wait_for(function()
			return view:buffer() == sh.buffer
		end)
	end
)

test("a program quiet at the start of a line isn't said to wait as soon", function(t)
	local sh = open(t)
	-- As likely fetching something, as kubectl is.
	local block = type_line(t, sh, "sh -c 'echo fetching; sleep 30'")
	t:wait(1100)
	assert(block.status == "running" and not block.waiting, "not waiting yet")
	shell.kill(block)
end)

test("a line typed with ! runs in a terminal right away", function(t)
	local sh = open(t)
	local view = greed.view()
	local block = type_line(t, sh, "!sh -c 'read x; echo got $x'")
	assert(block.command == "!sh -c 'read x; echo got $x'", block.command)
	assert(view:buffer():kind() == "terminal", view:buffer():kind())
	t:keys("o k enter")
	finished(t, block)
	assert(block.handed and string.find(block.output, "got ok", 1, true), block.output)
end)

test("ctrl-c interrupts a program in a pseudo terminal", function(t)
	local sh = open(t)
	local block = type_line(t, sh, "sh -c 'echo started; sleep 30'")
	t:wait_for(function()
		return string.find(sh.buffer:text(), "started", 1, true) ~= nil
	end)
	t:keys("ctrl-c")
	finished(t, block)
	assert(block.status == "killed" and block.signal == "INT", `{block.status} {block.signal}`)
	assert(not block.handed)
end)

test("only the client that ran a block sizes its terminal", function(t)
	t:draw(70, 20)
	local sh = open(t)
	local block = type_line(t, sh, "sh -c 'read x; stty size'")
	local term = terminal_of(block)
	local other = t:client("other")
	other:draw(120, 40)
	t:draw(60, 15)
	local rows, cols = greed.view():size()
	term:key("enter")
	finished(t, block)
	-- After the line break `read` echoed.
	assert(block.output == `\n{rows} {cols}\n`, `{block.output} for {rows} {cols}`)
end)
