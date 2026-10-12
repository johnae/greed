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

-- What the decision model is asked, and its answer, while `f` runs.
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

test("auto mode lets the agent look, edit in the project and run what only looks", function(t)
	local dir = t:tempdir({ ["a.txt"] = "x\n" })
	local s: any = { cwd = dir, auto = true }
	local asked = deciding("YES", function()
		assert(auto.allows(s, asking("read")) == "auto: only looks")
		assert(auto.allows(s, asking("edit", { `{dir}/a.txt` })) == "auto: in the project")
		assert(auto.allows(s, asking("edit", { "/etc/hosts" })) == nil, "outside asks")
		assert(auto.allows(s, asking("edit")) == nil, "an edit that doesn't say where asks")
		local safe = auto.allows(s, asking("execute", nil, "rg -n x | head"))
		assert(safe == "auto: only looks, builds or tests", safe)
		assert(auto.allows(s, asking("execute", nil, "rm -rf build")) == nil, "risky asks")
		assert(auto.allows(s, asking("execute")) == nil, "a command it can't see asks")
		assert(auto.allows(s, asking("other")) == nil)
	end)
	assert(#asked == 0, "the decision model wasn't needed")
	s.auto = false
	assert(auto.allows(s, asking("read")) == nil, "off, everything asks")
end)

test("a command auto mode can't tell goes to the decision model, once", function(t)
	local s: any = { cwd = t:tempdir({}), auto = true }
	local asked = deciding("YES - it prints the version", function()
		local why = auto.allows(s, asking("execute", nil, "python3 --version"))
		assert(why == "auto: it prints the version", why)
		auto.allows(s, asking("execute", nil, "python3 --version"))
	end)
	assert(#asked == 1, "asked once for the same command")
	assert(
		string.find(asked[1], "python3 --version", 1, true) and string.find(asked[1], "untrusted")
	)
	deciding("NO, it writes a file", function()
		assert(auto.allows(s, asking("execute", nil, "python3 make.py")) == nil, "no asks you")
	end)
	deciding(nil, function()
		assert(auto.allows(s, asking("execute", nil, "python3 x.py")) == nil, "no model asks you")
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
	local chosen = session.ask(s, "Edit a.txt", "edit", ONCE, { `{s.cwd}/a.txt` })
	assert(chosen == "once", tostring(chosen))
	local last = s.entries[#s.entries]
	assert(last.chosen == "Allow once (auto: in the project)", last.chosen)
end)
