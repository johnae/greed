local test = require("@greed/test")
local greed = require("@greed")
local acp = require("@acp")
local models: any = require("@models")
local auto = require("../auto")
local session = require("../session")

local ONCE = session.ONCE

-- A question of `kind`, touching `locations`, running `command`.
local function asking(kind: string, locations: { string }?, command: string?): any
	return {
		title = "something",
		kind = kind,
		locations = locations,
		command = command,
		options = ONCE,
		answer = greed.signal(),
	}
end

-- What the decision model is asked while `f` runs, `answer` its reply.
local function deciding(answer: string?, f: () -> ()): { string }
	local asked: { string } = {}
	local before = models.ask
	models.ask = function(role: string, request: any): (string?, string?)
		assert(role == auto.ROLE, role)
		table.insert(asked, request.messages[1].content)
		return answer, if answer then nil else "no model"
	end
	local ok, err: any = pcall(f)
	models.ask = before
	assert(ok, err)
	return asked
end

-- A session in auto mode in a folder of its own, having been asked `said`.
local function session_in(t: test.TestContext, said: string?): any
	local entries = if said then { { kind = "user", text = said } } else {}
	return { cwd = t:tempdir({ ["a.txt"] = "x\n" }), auto = true, entries = entries }
end

test("auto mode lets the agent look, edit in the project and run what only looks", function(t)
	local s = session_in(t)
	local asked = deciding("ALLOW", function()
		local function says(permission: any): string
			local verdict, why = auto.decide(s, permission)
			return `{verdict}: {why}`
		end
		assert(says(asking("read")) == "allow: auto: only looks")
		assert(says(asking("edit", { `{s.cwd}/a.txt` })) == "allow: auto: in the project")
		assert(auto.decide(s, asking("edit", { "/etc/hosts" })) == nil, "outside asks you")
		assert(auto.decide(s, asking("edit")) == nil, "an edit that doesn't say where asks you")
		local safe = says(asking("execute", nil, "rg -n x | head"))
		assert(safe == "allow: auto: only looks, builds or tests", safe)
		assert(auto.decide(s, asking("execute")) == nil, "a command it can't see asks you")
		assert(auto.decide(s, asking("other")) == nil)
	end)
	assert(#asked == 0, "the decision model wasn't needed")
	s.auto = false
	assert(auto.decide(s, asking("read")) == nil, "off, everything asks you")
end)

test("the decision model judges other commands, risky ones too, by what you asked", function(t)
	local s = session_in(t, "clean out /tmp/blahbleh, it's junk")
	local asked = deciding("ALLOW - the user asked to clean it", function()
		local verdict, why = auto.decide(s, asking("execute", nil, "rm -rf /tmp/blahbleh"))
		assert(verdict == "allow" and why == "auto: the user asked to clean it", why)
		auto.decide(s, asking("execute", nil, "rm -rf /tmp/blahbleh"))
	end)
	assert(#asked == 1, "asked once for the same command")
	local content = asked[1]
	assert(string.find(content, "clean out /tmp/blahbleh, it's junk", 1, true), content)
	assert(string.find(content, "risky: it deletes files", 1, true), content)
	assert(string.find(content, "untrusted", 1, true), "the command goes as data")
	deciding("BLOCK, it reaches outside the task", function()
		local verdict, why = auto.decide(s, asking("execute", nil, "python3 make.py"))
		assert(verdict == "block" and why == "auto: it reaches outside the task", why)
	end)
	deciding(nil, function()
		assert(auto.decide(s, asking("execute", nil, "python3 x.py")) == nil, "no model asks you")
	end)
end)

test("your rules go to the decision model", function(t)
	local s = session_in(t)
	greed.option.set("agent-auto-rules", "deleting under /tmp is fine")
	local asked = deciding("ALLOW", function()
		auto.decide(s, asking("execute", nil, "python3 x.py"))
	end)
	greed.option.set("agent-auto-rules", "")
	assert(string.find(asked[1], "rules: deleting under /tmp is fine", 1, true), asked[1])
end)

test("some commands always ask you, and the decision model never sees them", function(t)
	local s = session_in(t)
	local asked = deciding("ALLOW", function()
		for _, command in
			{
				"sudo ls",
				"git push --force origin main",
				"rm -rf ~",
				"rm -rf /",
				"rm -rf $HOME/",
				"rm -rf /home",
				"dd if=/dev/zero of=/dev/sda",
				"make && sudo make install",
			}
		do
			assert(auto.hard(command), command)
			assert(auto.decide(s, asking("execute", nil, command)) == nil, command)
		end
	end)
	assert(#asked == 0, "never asked")
	assert(auto.hard("rm -rf /tmp/blahbleh") == nil and auto.hard("git push") == nil)
end)

test("after three blocks in a row you're asked, until you answer", function(t)
	local s = session_in(t)
	local asked = deciding("BLOCK no", function()
		for i = 1, auto.BLOCKS do
			assert(auto.decide(s, asking("execute", nil, `python3 x{i}.py`)) == "block")
		end
		assert(auto.decide(s, asking("execute", nil, "python3 more.py")) == nil, "asks you")
	end)
	assert(#asked == auto.BLOCKS, "the model wasn't asked the fourth time")
	s.auto_blocks = 0
	deciding("BLOCK no", function()
		assert(auto.decide(s, asking("execute", nil, "python3 again.py")) == "block")
	end)
end)

test("in auto mode an agent's question is answered for you, saying why", function(t)
	local FAKE: acp.Agent = {
		name = "fake",
		title = "Fake",
		commands = { { "sh", `{greed.plugin.dirs().acp}/test/fake-agent.sh` } },
	}
	local s: any = assert(acp.start(FAKE, t:tempdir({ ["a.txt"] = "one\n" })))
	acp.show(s)
	t:wait_for(function()
		return s.status == "idle"
	end)
	t:keys("alt-a")
	assert(s.auto == true, "alt-a switched it on")
	t:wait(50)
	local text = greed.view():buffer():text()
	assert(string.find(text, " · auto ", 1, true), "the box says so: " .. text)
	local chosen, _, why = session.ask(s, "Edit a.txt", "edit", ONCE, { `{s.cwd}/a.txt` })
	assert(chosen == "once" and why == "auto: in the project", tostring(chosen))
	local last = s.entries[#s.entries]
	assert(last.chosen == "Allow once (auto: in the project)", last.chosen)
	-- A block picks the agent's reject, and an answer of yours resets the count.
	deciding("BLOCK not asked for", function()
		local no = session.ask(s, "Run python3 x.py", "execute", ONCE, nil, nil, "python3 x.py")
		assert(no == "no", tostring(no))
	end)
	assert(s.entries[#s.entries].chosen == "Reject (auto: not asked for)")
	assert(s.auto_blocks == 1)
end)
