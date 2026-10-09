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
	local read = shell.live.read
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
	shell.rows.set(sh, block, "COUNT>1", "COUNT", true)
	assert(block.shown and #block.shown.rows == 0, "nothing over one yet")
	greed.fs.write(`{sh.cwd}/rows`, "NAME  COUNT\na     2\nb     5\nc     1\n")
	greed.sleep(1000)
	t:wait_for(function()
		return block.shown ~= nil and #block.shown.rows == 2
	end)
	local from, to = shell.log.output_range(sh, block)
	local shown = sh.buffer:slice(assert(from), assert(to))
	assert(string.find(shown, "b     5\na     2", 1, true), "kept and sorted: " .. shown)
	assert(not string.find(shown, "c     1", 1, true), shown)
	shell.interrupt(block)
end)

test("a pinned watch shows in the prompt as it changes, until it stops", function(t)
	local sh = open(t)
	-- The pinned segment's text, or nil.
	local function pinned(): string?
		local found = sh.segments
		if found == nil then
			return nil
		end
		for _, segment in found do
			if string.sub(segment.text, 1, 3) == "⚑" then
				return segment.text
			end
		end
		return nil
	end
	assert(not shell.live.pin(sh, assert(shell.run(sh, "true"))), "only a watch is pinned")
	greed.fs.write(`{sh.cwd}/rows`, "NAME  COUNT\na     1\nb     1\n")
	local block = assert(shell.run(sh, "watch -n 1 cat rows", { view = greed.view() }))
	t:wait_for(function()
		return block.table ~= nil
	end)
	assert(shell.live.pin(sh, block))
	t:wait_for(function()
		return pinned() == "⚑ 2 rows"
	end)
	greed.fs.write(`{sh.cwd}/rows`, "NAME  COUNT\na     1\nb     1\nc     2\n")
	greed.sleep(1000)
	t:wait_for(function()
		return pinned() == "⚑ 3 rows"
	end)
	-- A filter changes what it shows, and so what the prompt shows.
	shell.rows.set(sh, block, "COUNT>1")
	shell.live.reshown(sh, block)
	t:wait_for(function()
		return pinned() == "⚑ 1 row"
	end)
	assert(shell.live.unpin(sh, block) and not shell.live.unpin(sh, block))
	t:wait_for(function()
		return pinned() == nil
	end)
	assert(shell.live.pin(sh, block))
	shell.interrupt(block)
	t:wait_for(function()
		return block.status ~= "running" and pinned() == nil
	end)
end)
