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

-- The decision model's answers: likely harmless and asked for, likely
-- harmful, and unsure of both.
local HARMLESS = { harmful = 0.05, asked = 0.9 }
local HARMFUL = { harmful = 0.9, asked = 0.1 }
local UNSURE = { harmful = 0.5, asked = 0.4 }

-- The states the decision model is given while `f` runs, as JSON, and
-- `answers` its answers (nil: no model).
local function deciding(answers: { [string]: number }?, f: () -> ()): { string }
	local given: { string } = {}
	local before = models.decide
	models.decide = function(role: string, state: any, questions: any): (any, string?)
		assert(role == auto.ROLE, role)
		assert(questions.harmful and questions.asked, "both questions asked")
		table.insert(given, greed.json.encode(state))
		return answers, if answers then nil else "no model"
	end
	local ok, err: any = pcall(f)
	models.decide = before
	assert(ok, err)
	return given
end

-- A session in auto mode in a folder of its own, having been asked `said`.
local function session_in(t: test.TestContext, said: string?): any
	local entries = if said then { { kind = "user", text = said } } else {}
	return { cwd = t:tempdir({ ["a.txt"] = "x\n" }), auto = true, entries = entries }
end

test("auto mode lets the agent look, edit in the project and run what only looks", function(t)
	local s = session_in(t)
	local given = deciding(HARMLESS, function()
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
	assert(#given == 0, "the decision model wasn't needed")
	s.auto = false
	assert(auto.decide(s, asking("read")) == nil, "off, everything asks you")
end)

test("the decision model judges other commands, risky ones too, by what you asked", function(t)
	local s = session_in(t, "clean out /tmp/blahbleh, it's junk")
	local given = deciding(HARMLESS, function()
		local verdict, why = auto.decide(s, asking("execute", nil, "rm -rf /tmp/blahbleh"))
		assert(verdict == "allow" and why == "auto: harmless (95%)", why)
		auto.decide(s, asking("execute", nil, "rm -rf /tmp/blahbleh"))
	end)
	assert(#given == 1, "asked once for the same command")
	local state = given[1]
	assert(string.find(state, "clean out /tmp/blahbleh, it's junk", 1, true), state)
	assert(string.find(state, "deletes files", 1, true), state)
	assert(string.find(state, "untrusted", 1, true), "the command goes as data")
	deciding(HARMFUL, function()
		local verdict, why = auto.decide(s, asking("execute", nil, "python3 make.py"))
		assert(verdict == "block" and why == "auto: may do harm you didn't ask for (90%)", why)
	end)
	deciding({ harmful = 0.5, asked = 0.8 }, function()
		local verdict, why = auto.decide(s, asking("execute", nil, "python3 clean.py"))
		assert(verdict == "allow" and why == "auto: you asked for it (80%)", why)
	end)
	deciding(UNSURE, function()
		assert(auto.decide(s, asking("execute", nil, "python3 x.py")) == nil, "unsure asks you")
	end)
	deciding(nil, function()
		assert(auto.decide(s, asking("execute", nil, "python3 y.py")) == nil, "no model asks you")
	end)
end)

test("your rules go to the decision model", function(t)
	local s = session_in(t)
	greed.option.set("agent-auto-rules", "deleting under /tmp is fine")
	local given = deciding(HARMLESS, function()
		auto.decide(s, asking("execute", nil, "python3 x.py"))
	end)
	greed.option.set("agent-auto-rules", "")
	assert(string.find(given[1], "deleting under /tmp is fine", 1, true), given[1])
end)

test("some commands always ask you, and the decision model never sees them", function(t)
	local s = session_in(t)
	local given = deciding(HARMLESS, function()
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
	assert(#given == 0, "never asked")
	assert(auto.hard("rm -rf /tmp/blahbleh") == nil and auto.hard("git push") == nil)
end)

test("after three blocks in a row you're asked, until you answer", function(t)
	local s = session_in(t)
	local given = deciding(HARMFUL, function()
		for i = 1, auto.BLOCKS do
			assert(auto.decide(s, asking("execute", nil, `python3 x{i}.py`)) == "block")
		end
		assert(auto.decide(s, asking("execute", nil, "python3 more.py")) == nil, "asks you")
	end)
	assert(#given == auto.BLOCKS, "the model wasn't asked the fourth time")
	s.auto_blocks = 0
	deciding(HARMFUL, function()
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
	-- A block picks the agent's reject.
	deciding(HARMFUL, function()
		local no = session.ask(s, "Run python3 x.py", "execute", ONCE, nil, nil, "python3 x.py")
		assert(no == "no", tostring(no))
	end)
	local blocked = s.entries[#s.entries].chosen
	assert(blocked == "Reject (auto: may do harm you didn't ask for (90%))", blocked)
	assert(s.auto_blocks == 1)
end)
