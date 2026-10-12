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

-- The decision model's answers: safe, unsafe, and unsure.
local SAFE = { safe = 0.95 }
local UNSAFE = { safe = 0.1 }
local UNSURE = { safe = 0.5 }

-- The states the decision model is given while `f` runs, as JSON, and
-- `answers` its answers (nil: no model).
local function deciding(answers: { [string]: number }?, f: () -> ()): { string }
	local given: { string } = {}
	local before = models.decide
	models.decide = function(role: string, state: any, questions: any): (any, string?)
		assert(role == auto.ROLE, role)
		assert(questions.safe, "asked whether it's safe")
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
	local given = deciding(SAFE, function()
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
	local given = deciding(SAFE, function()
		local verdict, why = auto.decide(s, asking("execute", nil, "rm -rf /tmp/blahbleh"))
		assert(verdict == "allow" and why == "auto: safe to run (95%)", why)
		auto.decide(s, asking("execute", nil, "rm -rf /tmp/blahbleh"))
	end)
	assert(#given == 1, "asked once for the same command")
	local state = given[1]
	assert(string.find(state, "clean out /tmp/blahbleh, it's junk", 1, true), state)
	deciding(UNSAFE, function()
		local verdict, why = auto.decide(s, asking("execute", nil, "python3 make.py"))
		assert(verdict == "block" and why == "auto: not safe to run unasked (90%)", why)
	end)
	deciding(UNSURE, function()
		assert(auto.decide(s, asking("execute", nil, "python3 x.py")) == nil, "unsure asks you")
	end)
	deciding(nil, function()
		assert(auto.decide(s, asking("execute", nil, "python3 y.py")) == nil, "no model asks you")
	end)
end)

test(
	"your newest message goes apart, and after a new one a command is asked about again",
	function(t)
		local s = session_in(t, "make a folder")
		table.insert(s.entries, { kind = "user", text = "now delete it" })
		local given = deciding(SAFE, function()
			auto.decide(s, asking("execute", nil, "rm -rf /tmp/x"))
			auto.decide(s, asking("execute", nil, "rm -rf /tmp/x"))
			table.insert(s.entries, { kind = "user", text = "and again" })
			auto.decide(s, asking("execute", nil, "rm -rf /tmp/x"))
		end)
		assert(#given == 2, `asked {#given} times`)
		local state = greed.json.decode(given[1])
		assert(state.user_asks_now == "now delete it", given[1])
		assert(state.user_asked_before[1] == "make a folder", given[1])
	end
)

test("your rules go to the decision model", function(t)
	local s = session_in(t)
	greed.option.set("agent-auto-rules", "deleting under /tmp is fine")
	local given = deciding(SAFE, function()
		auto.decide(s, asking("execute", nil, "python3 x.py"))
	end)
	greed.option.set("agent-auto-rules", "")
	assert(string.find(given[1], "deleting under /tmp is fine", 1, true), given[1])
end)

test("some commands always ask you, and the decision model never sees them", function(t)
	local s = session_in(t)
	local given = deciding(SAFE, function()
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
	local given = deciding(UNSAFE, function()
		for i = 1, auto.BLOCKS do
			assert(auto.decide(s, asking("execute", nil, `python3 x{i}.py`)) == "block")
		end
		assert(auto.decide(s, asking("execute", nil, "python3 more.py")) == nil, "asks you")
	end)
	assert(#given == auto.BLOCKS, "the model wasn't asked the fourth time")
	s.auto_blocks = 0
	deciding(UNSAFE, function()
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
	assert(string.find(text, "Fake · auto · ", 1, true), "the box says so: " .. text)
	local chosen, _, why = session.ask(s, "Edit a.txt", "edit", ONCE, { `{s.cwd}/a.txt` })
	assert(chosen == "once" and why == "auto: in the project", tostring(chosen))
	local last = s.entries[#s.entries]
	assert(last.chosen == "Allow once (auto: in the project)", last.chosen)
	-- A block picks the agent's reject.
	deciding(UNSAFE, function()
		local no = session.ask(s, "Run python3 x.py", "execute", ONCE, nil, nil, "python3 x.py")
		assert(no == "no", tostring(no))
	end)
	local blocked = s.entries[#s.entries].chosen
	assert(blocked == "Reject (auto: not safe to run unasked (90%))", blocked)
	assert(s.auto_blocks == 1)
	-- New sessions start as you switched the last one, after a restart too.
	assert(greed.option.get("agent-auto") == true, "new sessions start in auto")
	local kept = `{greed.fs.dirs().data}/agent-auto`
	assert(greed.fs.read(kept) == "auto\n", tostring((greed.fs.read(kept))))
	t:keys("alt-a")
	assert(not s.auto and greed.option.get("agent-auto") == false, "and back to manual")
	assert(greed.fs.read(kept) == "manual\n")
	t:wait(50)
	text = greed.view():buffer():text()
	assert(string.find(text, "Fake · manual · ", 1, true), "the box says so: " .. text)
end)
