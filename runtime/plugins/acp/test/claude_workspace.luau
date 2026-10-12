local test = require("@greed/test")
local greed = require("@greed")
local acp = require("@acp")

-- Stands in for Claude Code: writes the arguments it was given, one a
-- line, to `args` in the folder it runs in, then waits. Written aside and
-- moved there, so it's never read half written.
local FAKE = 'printf "%s\\n" "$@" > args.part\nmv args.part args\nexec sleep 30\n'

-- What the stand-in in `dir` was given, once it has run.
local function given(t: test.TestContext, dir: string): string
	t:wait_for(function()
		return greed.fs.read(`{dir}/args`) ~= nil
	end)
	return greed.fs.read(`{dir}/args`) or ""
end

test("Claude Code in a workspace runs in a terminal there, listed with the sessions", function(t)
	if greed.which("jj") == nil then
		return
	end
	local fake = t:tempdir({ ["claude.sh"] = FAKE })
	greed.option.set("claude-command", `sh {fake}/claude.sh`)
	local dir = t:repo("jj", { ["a.txt"] = "a\n" })
	greed.open(`{dir}/a.txt`)
	t:run("claude-workspace", { "fix", "the", "parser" })
	local s = acp.sessions()[1]
	assert(s and s.agent == "claude-terminal", "a session for it")
	local ws = assert(s.workspace, "with a workspace")
	assert(s.cwd == ws.path and greed.fs.stat(ws.path), ws.path)
	local args = given(t, ws.path)
	assert(string.find(args, "--append-system-prompt", 1, true), args)
	assert(string.find(args, `jj workspace {ws.name}`, 1, true), "told how it works: " .. args)
	assert(string.find(args, "fix the parser", 1, true), "asked first: " .. args)
	assert(#s.entries == 1, "titled by what it was asked")

	t:run("agent-list")
	local listed = greed.view():buffer():text()
	assert(string.find(listed, "Claude Code  fix the parser", 1, true), listed)
	assert(string.find(listed, `workspace {ws.name}`, 1, true), listed)

	-- Stopped, it's taken up again in its workspace with --continue.
	acp.stop(s)
	assert(s.status == "exited", s.status)
	greed.fs.remove(`{ws.path}/args`)
	local again, err = acp.resume({
		agent = "claude-terminal",
		root = dir,
		workspace = ws,
		session_id = ws.name,
		title = "fix the parser",
		time = os.time(),
	})
	assert(again, err)
	assert(string.find(given(t, ws.path), "--continue", 1, true), "continued")

	acp.close(again)
	acp.close(s)
	assert(not greed.fs.stat(ws.path), "closing removes its workspace")
end)

test("Claude Code in a workspace needs a repository", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a\n" })
	greed.open(`{dir}/a.txt`)
	t:run("claude-workspace")
	assert(#acp.sessions() == 0, "nothing started")
	local messages = t:messages()
	assert(
		string.find(messages[#messages], "isn't in a jj or git repository", 1, true),
		messages[#messages]
	)
end)
