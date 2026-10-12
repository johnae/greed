local test = require("@greed/test")
local greed = require("@greed")

test("programs run with input, in a folder, and say how they exited", function(t)
	local done = greed.process.run(
		{ "sh", "-c", "cat; echo out; echo err >&2; exit 3" },
		{ stdin = "in\n" }
	)
	assert(done and done.code == 3, "the exit code")
	assert(done.stdout == "in\nout\n", done.stdout)
	assert(done.stderr == "err\n", done.stderr)
	local dir = t:tempdir()
	local here = greed.process.run({ "pwd" }, { cwd = dir })
	assert(here and string.find(here.stdout, dir, 1, true), here and here.stdout)
	local missing, err = greed.process.run({ "no-such-program-here" })
	assert(missing == nil and err, "a program that can't start")
end)

test("in a command a program runs without holding up the editor", function(t)
	local got = nil
	greed.command({
		name = "process-test",
		run = function()
			local done = greed.process.run({ "echo", "from a command" })
			got = done and done.stdout
		end,
	})
	t:run("process-test")
	assert(got == "from a command\n", tostring(got))
end)

test("greed.spawn runs code that waits, and returns at once", function(t)
	local said = nil
	greed.spawn(function(word: string)
		local done = greed.process.run({ "echo", word })
		said = done and done.stdout
	end, "hi")
	assert(said == nil, "spawn returned before the program ran")
	t:wait(100)
	assert(said == "hi\n", tostring(said))
end)

test("a spawned program is talked to over its input and output until it exits", function(t)
	local child, err = greed.process.spawn({ "sh", "-c", "echo ready; echo oops >&2; cat; exit 4" })
	assert(child, err)
	assert(child.pid > 0)
	assert(child:read() == "ready\n", "it reads what the program printed")
	assert(child:write("one\n"))
	assert(child:read() == "one\n", "and what it echoed back")
	child:close()
	local rest = ""
	while true do
		local piece = child:read()
		if piece == nil then
			break
		end
		rest ..= piece
	end
	assert(rest == "", "nothing more: " .. rest)
	assert(child:wait() == 4, "the exit code")
	assert(child:read() == nil, "reading after the end gives nil")
	assert(not child:write("late"), "its input is closed")
	assert(child:stderr() == "oops\n", child:stderr())
end)

test("a spawned program's last error output is there once it has exited", function(t)
	local child, err = greed.process.spawn({
		"sh",
		"-c",
		"i=0; while [ $i -lt 2000 ]; do echo line $i >&2; i=$((i+1)); done; echo last words >&2",
	})
	assert(child, err)
	while child:read() ~= nil do
	end
	assert(child:wait() == 0, "the exit code")
	local said = child:stderr()
	assert(string.sub(said, -#"last words\n") == "last words\n", string.sub(said, -100))
end)

test("a spawned program can be killed, and one that can't start says why", function(t)
	local child = greed.process.spawn({ "sleep", "30" })
	assert(child)
	child:kill()
	assert(child:wait() == nil, "a signal ended it")
	local missing, err = greed.process.spawn({ "no-such-program-here" })
	assert(missing == nil and err, "a program that can't start")
end)

test("output arrives while the editor goes on, for code waiting in a command", function(t)
	local child = greed.process.spawn({ "sh", "-c", "sleep 0.1; echo late" })
	assert(child)
	local got = nil
	greed.spawn(function()
		got = child:read()
	end)
	assert(got == nil, "it waits")
	t:wait_for(function()
		return got ~= nil
	end)
	assert(got == "late\n", tostring(got))
end)

-- Every piece `child` prints until it exits, with where each came from.
local function read_all(child: greed.Child): { { piece: string, from: string } }
	local pieces = {}
	while true do
		local piece, from = child:read()
		if piece == nil then
			return pieces
		end
		table.insert(pieces, { piece = piece, from = from or "?" })
	end
end

-- The pieces from `from` joined, in the order they came.
local function joined(pieces: { { piece: string, from: string } }, from: string): string
	local parts = {}
	for _, p in pieces do
		if p.from == from then
			table.insert(parts, p.piece)
		end
	end
	return table.concat(parts)
end

test("error output can arrive with the rest, each piece saying where it came from", function(t)
	-- It waits for a line between its outputs, so they come in this order.
	local script = "echo a; read x; echo b >&2; read x; echo c"
	local child, err = greed.process.spawn({ "sh", "-c", script }, { stderr = "stream" })
	assert(child, err)
	local function next_piece(): string
		local piece, from = child:read()
		return `{from}: {piece}`
	end
	local first = next_piece()
	assert(first == "stdout: a\n", first)
	child:write("\n")
	local second = next_piece()
	assert(second == "stderr: b\n", second)
	child:write("\n")
	local third = next_piece()
	assert(third == "stdout: c\n", third)
	assert(child:read() == nil, "nothing more")
	assert(child:wait() == 0)
	assert(child:stderr() == "b\n", "and it's kept too")
end)

test("both outputs arrive in their own order when streamed", function(t)
	local script = "echo a; echo b >&2; echo c; echo d >&2"
	local child = assert(greed.process.spawn({ "sh", "-c", script }, { stderr = "stream" }))
	local pieces = read_all(child)
	assert(joined(pieces, "stdout") == "a\nc\n", joined(pieces, "stdout"))
	assert(joined(pieces, "stderr") == "b\nd\n", joined(pieces, "stderr"))
end)

test("by default error output is only kept, and read gives what it printed", function(t)
	local child = assert(greed.process.spawn({ "sh", "-c", "echo a; echo b >&2; echo c" }))
	local pieces = read_all(child)
	assert(joined(pieces, "stdout") == "a\nc\n", joined(pieces, "stdout"))
	assert(joined(pieces, "stderr") == "", "no error output from read")
	assert(child:stderr() == "b\n", child:stderr())
	local code, signal = child:wait()
	assert(code == 0 and signal == nil, `{code} {signal}`)
end)

test("a program in a group of its own is signalled with what it started", function(t)
	-- The sleep ignores INT, so it outlives the shell and holds its output
	-- open; it says so once it does.
	local script = "(trap '' INT; echo started; exec sleep 100) & wait"
	local child = assert(greed.process.spawn({ "sh", "-c", script }, { group = true }))
	assert(child:read() == "started\n", "the sleep is running")
	assert(child:signal("INT"), "sent")
	local code, signal = child:wait()
	assert(code == nil and signal == "INT", `{code} {signal}`)
	-- The sleep is still in the group, and goes with it.
	assert(child:signal("KILL"), "what's left of the group is reached")
	local ok, err = pcall(function()
		child:signal("NOPE")
	end)
	assert(not ok and string.find(tostring(err), "isn't a signal", 1, true), tostring(err))
end)

test("a program on its own is signalled by name and says which ended it", function(t)
	local child = assert(greed.process.spawn({ "sleep", "30" }))
	assert(child:signal("term"), "names are any case, without SIG")
	local code, signal = child:wait()
	assert(code == nil and signal == "TERM", `{code} {signal}`)
	assert(not child:signal("SIGTERM"), "once it's gone nothing is sent")
end)

test("a variable can be left out of what a program inherits", function(t)
	-- `env` lists what it got; found by its full path, as there's no PATH.
	local found = assert(greed.process.run({ "sh", "-c", "command -v env" }))
	local env = (string.gsub(found.stdout, "%s+$", ""))
	local vars: { [string]: string | false } = { PATH = false, GREED_TEST_A = "1" }
	local child = assert(greed.process.spawn({ env }, { env = vars }))
	local listed = "\n" .. joined(read_all(child), "stdout")
	assert(string.find(listed, "\nGREED_TEST_A=1\n", 1, true), listed)
	assert(not string.find(listed, "\nPATH=", 1, true), listed)
end)

test("spawn refuses options it can't use", function(t)
	local spawn = greed.process.spawn :: any
	local ok, err = pcall(spawn, { "true" }, { env = { A = 1 } })
	assert(not ok and string.find(tostring(err), "env.A", 1, true), tostring(err))
	local ok2, err2 = pcall(spawn, { "true" }, { stderr = "merge" })
	assert(not ok2 and string.find(tostring(err2), "stream", 1, true), tostring(err2))
end)

test("a program printing more than is read waits for the reading", function(t)
	-- 20 MB, then a word on its error output once all of it went out.
	local script = "head -c 20000000 /dev/zero; echo done >&2"
	local child = assert(greed.process.spawn({ "sh", "-c", script }))
	-- Real time, with its output arriving meanwhile.
	greed.process.run({ "sleep", "0.5" })
	assert(child:stderr() == "", "it waits while its output isn't read")
	local total = 0
	while true do
		local piece = child:read()
		if piece == nil then
			break
		end
		total += #piece
	end
	assert(total == 20000000, `all of it arrives: {total}`)
	assert(child:wait() == 0)
	assert(child:stderr() == "done\n", child:stderr())
end)

test("a group that's all gone isn't signalled", function(t)
	local child = assert(greed.process.spawn({ "true" }, { group = true }))
	assert(child:wait() == 0)
	assert(not child:signal("KILL"), "nothing of it is left to reach")
end)

test("a run whose caller fails while it waits doesn't keep the editor busy", function(t)
	local failed: string? = nil
	greed.spawn(function()
		local ok, err = pcall(function()
			greed.process.run({ "sleep", "5" }, {
				on_start = function(child)
					child:kill()
					error("gave up", 0)
				end,
			})
		end)
		failed = if ok then nil else tostring(err)
	end)
	t:wait_for(function()
		return failed ~= nil
	end)
	assert(failed == "gave up", tostring(failed))
end)
