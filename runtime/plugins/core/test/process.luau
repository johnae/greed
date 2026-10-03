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
