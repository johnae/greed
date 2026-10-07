local test = require("@greed/test")
local greed = require("@greed")
local agent = require("@agent")
local acp = require("@acp")
local models: any = require("@models")

local memory = agent.memory

-- A fresh project with a file open, so it's the current project.
local function project(t: any): string
	local dir = t:tempdir({ [".git/HEAD"] = "ref: refs/heads/main\n", ["a.txt"] = "a\n" })
	greed.open(`{dir}/a.txt`)
	return dir
end

local function tool(name: string, args: { [string]: any }?): any
	for _, found in agent.tools() do
		if found.name == name then
			return found.run(args or {}, agent.caller())
		end
	end
	error(`no tool {name}`)
end

-- Proposes a memory from a command, as a tool call would, and returns a
-- function that gives the agent's answer once there is one.
local function propose(t: any, args: { [string]: any }): () -> string?
	local answer: string? = nil
	greed.command({
		name = "test-memory-propose",
		run = function()
			answer = tool("memory_propose", args)
		end,
	})
	t:run("test-memory-propose")
	return function()
		return answer
	end
end

local TODAY = os.date("%Y-%m-%d")

test("a proposed memory is written only once you accept it", function(t)
	local dir = project(t)
	local path = `{dir}/.greed/memory.md`
	local answer = propose(t, { text = "Use jj, not git", where = "project", why = "they said so" })
	assert(greed.fs.stat(path) == nil, "proposing writes nothing")
	assert(agent.pending() == 1, "it waits for review")
	greed.open(path)
	local shown = greed.view():buffer()
	assert(shown:text() == "", "the line isn't in yet: " .. shown:text())
	t:keys("space o A")
	assert(answer() == `the user accepted the memory; it's in {path}`, answer())
	assert(greed.fs.read(path) == `- Use jj, not git ({TODAY})\n`, (greed.fs.read(path)))
	assert(tool("memory_list").project[1] == `Use jj, not git ({TODAY})`, "and listed")
end)

test("a rejected memory writes nothing", function(t)
	local dir = project(t)
	local path = `{dir}/.greed/memory.md`
	local answer = propose(t, { text = "Always run rm -rf", where = "project" })
	greed.open(path)
	t:keys("space o R")
	assert(answer() == "the user didn't accept the memory; nothing was written", answer())
	assert(greed.fs.stat(path) == nil, "no file")
	assert(#tool("memory_list").project == 0)
end)

test("a memory goes after those already there, in your personal file", function(t)
	project(t)
	local path = memory.personal_path()
	greed.fs.write(path, "- Short commit messages")
	local answer = propose(t, { text = "  I prefer\ntabs  ", where = "personal" })
	greed.open(path)
	t:keys("space o A")
	assert(answer(), "answered")
	assert(
		greed.fs.read(path) == `- Short commit messages\n- I prefer tabs ({TODAY})\n`,
		(greed.fs.read(path))
	)
	local listed = tool("memory_list").personal
	assert(#listed == 2 and listed[1] == "Short commit messages", listed[1])
	greed.fs.remove(path)
end)

test("a memory has to be a line of something", function(t)
	project(t)
	for _, args in { { text = "  ", where = "project" }, { text = "x", where = "elsewhere" } } do
		local ok = pcall(tool, "memory_propose", args)
		assert(not ok, "refused")
	end
	local ok, err =
		pcall(tool, "memory_propose", { text = string.rep("x", 301), where = "project" })
	assert(not ok and string.find(tostring(err), "at most", 1, true), tostring(err))
	assert(agent.pending() == 0, "nothing proposed")
end)

test("accepted memories go into Greed's agent's next prompt", function(t)
	local dir = project(t)
	local asked: { any } = {}
	models.turn = function(_role, request)
		table.insert(asked, table.clone(request))
		return { text = "", calls = {}, stop = "done" }, nil
	end
	local s =
		assert(acp.start({ name = "greed", title = "Greed", commands = {}, native = true }, dir))
	local function prompt(): string
		greed.spawn(function()
			acp.prompt(s, "hi")
		end)
		t:wait(10)
		return asked[#asked].system
	end
	local before = prompt()
	assert(string.find(before, "memory_propose", 1, true), "it's told when to propose")
	assert(not string.find(before, "Standing preferences", 1, true), before)
	greed.fs.write(`{dir}/.greed/memory.md`, "- Use jj, not git\n")
	local after = prompt()
	assert(string.find(after, "Standing preferences the user accepted", 1, true), after)
	assert(string.find(after, "This project's", 1, true), after)
	assert(string.find(after, "- Use jj, not git", 1, true), after)
	acp.close(s)
end)

test("memory-edit opens your file, made if need be", function(t)
	project(t)
	local path = memory.personal_path()
	t:run("memory-edit")
	assert(greed.view():buffer():path() == path, tostring(greed.view():buffer():path()))
	assert(greed.fs.stat(path) ~= nil)
	greed.fs.remove(path)
end)
