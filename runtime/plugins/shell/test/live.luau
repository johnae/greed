local test = require("@greed/test")
local greed = require("@greed")
local shell = require("@shell")
local live = require("../live")
local log = require("../log")
local shell_rows = require("../rows")

type Shell = typeof(shell.open())
type Block = typeof(assert(shell.run(shell.open(), "true")))

local function open(t: test.TestContext): Shell
	-- These go about the shell as text; blocks mode has tests of its own.
	greed.option.set("shell-blocks", false)
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = t:tempdir()
	return sh
end

-- The text of `block`'s output lines styled `style`.
local function styled(sh: Shell, block: Block, style: string): { string }
	local out: { string } = {}
	for _, mark in sh.buffer:decorations(`shell.out.{block.uid}`) do
		if mark.style == style then
			table.insert(out, sh.buffer:slice(mark.from, mark.to))
		end
	end
	return out
end

test("watch reads its seconds and its command", function()
	local read = live.read
	local function check(typed: string, command: string, seconds: number)
		local line, every = read(typed)
		assert(line == command and every == seconds, `{typed}: {line} every {every}`)
	end
	check("watch kubectl get pods", "kubectl get pods", 2)
	check("watch -n 5 -d ls | wc -l", "ls | wc -l", 5)
	-- Never faster than half a second.
	check("watch --interval=0.1 date", "date", 0.5)
	check("watch 'ls | wc -l'", "ls | wc -l", 2)
	local none, _, why = read("watch")
	assert(none == nil and string.find(why or "", "watch COMMAND", 1, true))
	assert(read("watching") == nil and read("^watch ls") == nil)
end)

test("a watch shows what its command printed last, the changes marked", function(t)
	local sh = open(t)
	greed.fs.write(`{sh.cwd}/rows`, "NAME  COUNT\na     1\nb     1\n")
	local block = assert(shell.run(sh, "watch -n 1 cat rows", { view = greed.view() }))
	t:wait_for(function()
		return string.find(block.output, "a     1", 1, true) ~= nil
	end)
	assert(block.status == "running" and block.watching == "cat rows")
	assert(block.table and #block.table.rows == 2, "its table follows along")
	assert(#styled(sh, block, "shell.changed") == 0, "nothing changed the first time")
	greed.fs.write(`{sh.cwd}/rows`, "NAME  COUNT\na     2\nb     1\nc     1\n")
	-- A test's clock only moves while its body waits on time.
	greed.sleep(1000)
	t:wait_for(function()
		return string.find(block.output, "a     2", 1, true) ~= nil
	end)
	local changed = styled(sh, block, "shell.changed")
	assert(
		#changed == 2 and changed[1] == "a     2" and changed[2] == "c     1",
		table.concat(changed, "|")
	)
	assert(string.find(block.note or "", "2 changed", 1, true), tostring(block.note))
	local text = sh.buffer:text()
	assert(not string.find(text, "a     1", 1, true), "what it printed before is gone")
	assert(shell.interrupt(block))
	t:wait_for(function()
		return block.status ~= "running"
	end)
	assert(block.note == "stopped", tostring(block.note))
	assert(string.find(block.output, "c     1", 1, true), "it keeps what it showed last")
	-- Table stages after its programs run each time too.
	local busy = assert(shell.run(sh, "watch cat rows | where COUNT > 1", { view = greed.view() }))
	t:wait_for(function()
		return busy.output ~= ""
	end)
	assert(busy.table and #busy.table.rows == 1 and busy.table.rows[1].NAME == "a", busy.output)
	shell.interrupt(busy)
end)

test("a watch's rows are things; an agent can't watch", function(t)
	local sh = open(t)
	greed.fs.write(`{sh.cwd}/notes.txt`, "hi\n")
	greed.fs.write(`{sh.cwd}/other.txt`, "same\n")
	local block = assert(shell.run(sh, "watch -n 1 ls -l", { view = greed.view() }))
	t:wait_for(function()
		return block.called ~= nil
	end)
	assert(block.called and block.called.many == "files")
	-- Rows starting alike are told apart by what they are: only the file
	-- that changed is marked.
	local runs = block.note
	greed.fs.write(`{sh.cwd}/notes.txt`, "hello there\n")
	greed.sleep(1000)
	t:wait_for(function()
		return block.note ~= runs and string.find(block.output, "notes.txt", 1, true) ~= nil
	end)
	local changed = styled(sh, block, "shell.changed")
	assert(
		#changed == 1 and string.find(changed[1], "notes.txt", 1, true),
		table.concat(changed, "|")
	)
	shell.interrupt(block)
	local agent = assert(shell.run(sh, "watch ls", { by = "agent", runner = "pipe" }))
	t:wait_for(function()
		return agent.status ~= "running"
	end)
	assert(agent.status == "failed" and string.find(agent.stderr, "until it's stopped", 1, true))
end)

test("a filter or a sort on a watch stays as it shows what's new", function(t)
	local sh = open(t)
	greed.fs.write(`{sh.cwd}/rows`, "NAME  COUNT\na     1\nb     1\n")
	local block = assert(shell.run(sh, "watch -n 1 cat rows", { view = greed.view() }))
	t:wait_for(function()
		return block.table ~= nil
	end)
	shell_rows.set(sh, block, "COUNT>1", "COUNT", true)
	assert(block.shown and #block.shown.rows == 0, "nothing over one yet")
	greed.fs.write(`{sh.cwd}/rows`, "NAME  COUNT\na     2\nb     5\nc     1\n")
	greed.sleep(1000)
	t:wait_for(function()
		return block.shown ~= nil and #block.shown.rows == 2
	end)
	local from, to = log.output_range(sh, block)
	local shown = sh.buffer:slice(assert(from), assert(to))
	assert(string.find(shown, "b     5\na     2", 1, true), "kept and sorted: " .. shown)
	assert(not string.find(shown, "c     1", 1, true), shown)
	shell.interrupt(block)
end)

test("each after a watch runs for every row each time", function(t)
	local sh = open(t)
	greed.fs.write(`{sh.cwd}/rows`, "NAME  COUNT\na     1\nb     2\n")
	local block =
		assert(shell.run(sh, "watch -n 1 cat rows | where COUNT > 1 | each echo hi {NAME}", {
			view = greed.view(),
		}))
	t:wait_for(function()
		return block.output ~= ""
	end)
	local first: string = block.stdout
	assert(first == "hi b\n", block.output)
	greed.fs.write(`{sh.cwd}/rows`, "NAME  COUNT\na     3\nb     2\n")
	greed.sleep(1000)
	t:wait_for(function()
		return block.stdout == "hi a\nhi b\n"
	end)
	shell.interrupt(block)
end)

test("a watch says which rows changed and how, leaving out what ticks by itself", function(t)
	local sh = open(t)
	local rows = `{sh.cwd}/rows`
	greed.fs.write(
		rows,
		"NAME  STATUS   RESTARTS     AGE\napi   Running  0            3m\nweb   Running  1 (2m ago)   5m\n"
	)
	local block = assert(shell.run(sh, "watch -n 1 cat rows", { view = greed.view() }))
	t:wait_for(function()
		return block.table ~= nil
	end)
	-- Ages and "(N ago)" moving on aren't a change.
	greed.fs.write(
		rows,
		"NAME  STATUS   RESTARTS     AGE\napi   Running  0            4m\nweb   Running  1 (3m ago)   6m\n"
	)
	greed.sleep(1000)
	t:wait_for(function()
		return string.find(block.output, "4m", 1, true) ~= nil
	end)
	assert(block.change == nil, tostring(block.change))
	assert(string.find(block.note or "", "0 changed", 1, true), tostring(block.note))
	greed.fs.write(
		rows,
		"NAME  STATUS   RESTARTS     AGE\napi   Error    0            4m\nweb   Running  1 (3m ago)   6m\n"
	)
	greed.sleep(1000)
	t:wait_for(function()
		return block.change ~= nil
	end)
	local change: string = block.change or ""
	assert(string.find(change, "^api: STATUS Running → Error · "), change)
	greed.fs.write(
		rows,
		"NAME  STATUS   RESTARTS     AGE\napi   Error    0            4m\ndb    Pending  0            1s\n"
	)
	greed.sleep(1000)
	t:wait_for(function()
		return string.find(block.change or "", "new db", 1, true) ~= nil
	end)
	assert(string.find(block.change or "", "^new db %+1 more"), tostring(block.change))
	-- A notification each time can be asked for, and stopped again.
	local view = greed.view()
	local from = log.range(block)
	view:set_cursor(assert(from))
	t:run("shell-notify")
	local on: boolean? = block.notify
	assert(on == true)
	t:run("shell-notify")
	local off: boolean? = block.notify
	assert(off == false)
	shell.interrupt(block)
end)

test("a watch changed to another command shows it in the same block, its filter gone", function(t)
	local sh = open(t)
	greed.fs.write(`{sh.cwd}/pods`, "NAME  STATUS\napi   Running\n")
	greed.fs.write(`{sh.cwd}/deploys`, "NAME  READY\nweb   1/1\n")
	local block = assert(shell.run(sh, "watch -n 1 cat pods", { view = greed.view() }))
	t:wait_for(function()
		return block.table ~= nil
	end)
	shell_rows.set(sh, block, "api")
	local number, uid, count = block.number, block.uid, #sh.blocks
	local same = shell.change(sh, block, "watch -n 1 cat deploys")
	assert(same == block, "the same block")
	t:wait_for(function()
		return string.find(block.output, "web", 1, true) ~= nil
	end)
	assert(block.number == number and block.uid == uid and #sh.blocks == count, "in its place")
	assert(block.command == "watch -n 1 cat deploys" and block.watching == "cat deploys")
	assert(block.status == "running" and block.shown == nil, "running, unfiltered")
	local from, to = log.output_range(sh, block)
	local shown = sh.buffer:slice(assert(from), assert(to))
	assert(not string.find(shown, "api", 1, true), shown)
	assert(string.find(sh.buffer:text(), "watch -n 1 cat deploys", 1, true), "its header says so")
	shell.interrupt(block)
end)

test("a finished block changed runs in its place; space C asks what to", function(t)
	local sh = open(t)
	local block = assert(shell.run(sh, "echo one", { view = greed.view() }))
	local function finished()
		t:wait_for(function()
			return block.status ~= "running"
		end)
	end
	finished()
	local count = #sh.blocks
	shell.change(sh, block, "echo two")
	finished()
	assert(#sh.blocks == count and block.status == "done", block.status)
	assert(
		string.find(block.output, "two", 1, true) and not string.find(block.output, "one", 1, true)
	)
	assert(not string.find(sh.buffer:text(), "echo one", 1, true), sh.buffer:text())
	-- From the block, space C puts its command in a prompt to change.
	local from = log.range(block)
	greed.view():set_cursor(assert(from))
	t:keys("esc space C")
	t:keys("backspace backspace backspace t h r e e enter")
	finished()
	assert(block.command == "echo three" and #sh.blocks == count, block.command)
	assert(string.find(block.output, "three", 1, true), block.output)
end)
