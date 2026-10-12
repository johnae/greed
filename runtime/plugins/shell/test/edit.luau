local test = require("@greed/test")
local greed = require("@greed")
local agent = require("@agent")
local shell = require("@shell")
local edit = require("../edit")

type Shell = typeof(shell.open())

local function open(t: test.TestContext): Shell
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = t:tempdir()
	return sh
end

local function ran(t: test.TestContext, sh: Shell, line: string, by: string?): any
	local block = assert(shell.run(sh, line, { by = by, runner = "pipe" }))
	t:wait_for(function()
		return block.status ~= "running"
	end)
	return block
end

test("a block you run opens files to edit in Greed; an agent's doesn't", function(t)
	local sh = open(t)
	local mine = ran(t, sh, "printenv GREED_BLOCK EDITOR GIT_EDITOR")
	local lines = string.split(mine.stdout, "\n")
	assert(lines[1] == tostring(mine.uid), mine.stdout)
	assert(string.find(lines[2], " edit %-%-wait$"), mine.stdout)
	assert(lines[3] == lines[2], "git's own variable too: " .. mine.stdout)
	local agents = ran(t, sh, "printenv EDITOR || echo none", "agent")
	assert(not string.find(agents.stdout, "edit --wait", 1, true), agents.stdout)
	greed.option.set("shell-editor", false)
	local off = ran(t, sh, "printenv EDITOR || echo none")
	assert(not string.find(off.stdout, "edit --wait", 1, true), off.stdout)
	-- What you export wins.
	greed.option.set("shell-editor", true)
	sh.env.EDITOR = "vi"
	local exported = ran(t, sh, "printenv EDITOR")
	assert(exported.stdout == "vi\n", exported.stdout)
end)

test("shell_edit is for greed edit only: agents aren't offered it and can't call it", function(t)
	local offered = false
	for _, tool in agent.offered(agent.caller()) do
		offered = offered or tool.name == "shell_edit"
	end
	assert(not offered, "not offered to agents")
	local result = agent.call("shell_edit", { paths = { "/tmp/x" } }, agent.caller())
	assert(result.isError and string.find(result.content[1].text, "no tool"), "refused")
end)

test("a file opens where the block ran, and the shell comes back after :q", function(t)
	local sh = open(t)
	local block = ran(t, sh, "true")
	local view = greed.view()
	local path = sh.cwd .. "/COMMIT_EDITMSG"
	greed.fs.write(path, "msg\n")
	local got: { outcome: string? } = {}
	greed.spawn(function()
		got.outcome = edit.open({ path }, { block = block.uid, wait = true })
	end)
	t:wait_for(function()
		return view:buffer():path() == path
	end)
	t:keys("g l a ! esc")
	t:run("save-quit")
	t:wait_for(function()
		return got.outcome ~= nil
	end)
	assert(got.outcome == "done", tostring(got.outcome))
	local written = greed.fs.read(path)
	assert(written == "msg!\n", tostring(written))
	assert(view:buffer() == sh.buffer, "the shell shows again")
	assert(greed.buffer_for(path) == nil, "a file that wasn't open closes")
end)

test(":cq stops the program, and a file open before stays open", function(t)
	local sh = open(t)
	local block = ran(t, sh, "true")
	local path = sh.cwd .. "/notes.txt"
	greed.fs.write(path, "notes\n")
	local before = greed.load(path)
	local got: { outcome: string? } = {}
	greed.spawn(function()
		got.outcome = edit.open({ path }, { block = block.uid, wait = true })
	end)
	t:wait_for(function()
		return greed.view():buffer() == before
	end)
	t:run("quit-abort")
	t:wait_for(function()
		return got.outcome ~= nil
	end)
	assert(got.outcome == "aborted", tostring(got.outcome))
	assert(before:valid(), "stays open")
	assert(greed.view():buffer() == sh.buffer, "the shell shows again")
end)
