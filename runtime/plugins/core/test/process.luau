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
