local test = require("@kern/test")
local kern = require("@kern")

test("programs run with input, in a folder, and say how they exited", function(t)
	local done = kern.process.run(
		{ "sh", "-c", "cat; echo out; echo err >&2; exit 3" },
		{ stdin = "in\n" }
	)
	assert(done and done.code == 3, "the exit code")
	assert(done.stdout == "in\nout\n", done.stdout)
	assert(done.stderr == "err\n", done.stderr)
	local dir = t:tempdir()
	local here = kern.process.run({ "pwd" }, { cwd = dir })
	assert(here and string.find(here.stdout, dir, 1, true), here and here.stdout)
	local missing, err = kern.process.run({ "no-such-program-here" })
	assert(missing == nil and err, "a program that can't start")
end)

test("in a command a program runs without holding up the editor", function(t)
	local got = nil
	kern.command({
		name = "process-test",
		run = function()
			local done = kern.process.run({ "echo", "from a command" })
			got = done and done.stdout
		end,
	})
	t:run("process-test")
	assert(got == "from a command\n", tostring(got))
end)

test("kern.spawn runs code that waits, and returns at once", function(t)
	local said = nil
	kern.spawn(function(word: string)
		local done = kern.process.run({ "echo", word })
		said = done and done.stdout
	end, "hi")
	assert(said == nil, "spawn returned before the program ran")
	t:wait(100)
	assert(said == "hi\n", tostring(said))
end)
