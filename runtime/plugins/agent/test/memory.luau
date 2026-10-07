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

test("a proposed memory is private to you, and written only once you accept it", function(t)
	local dir = project(t)
	local path = memory.project_path(dir)
	assert(string.find(path, `{assert(greed.fs.dirs().data)}/memory/`, 1, true) == 1, path)
	local answer = propose(t, { text = "Use jj, not git", why = "they said so" })
	assert(greed.fs.stat(path) == nil, "proposing writes nothing")
	assert(agent.pending() == 1, "it waits for review")
	greed.open(path)
	local shown = greed.view():buffer()
	assert(shown:text() == "", "the line isn't in yet: " .. shown:text())
	t:keys("space o A")
	assert(answer() == `the user accepted the memory; it's in {path}`, answer())
	assert(greed.fs.read(path) == `- Use jj, not git ({TODAY})\n`, (greed.fs.read(path)))
	local info = assert(greed.fs.stat(path))
	assert(string.format("%o", info.mode % 512) == "600", "only yours")
	assert(greed.fs.stat(`{dir}/.greed/memory.md`) == nil, "nothing in the repository")
	-- Back in the project, so it's the current one again.
	greed.open(`{dir}/a.txt`)
	local listed = tool("memory_list")
	assert(listed.project[1] == `Use jj, not git ({TODAY})`, "and listed")
	assert(#listed.shared == 0, "as a private one")
end)

test("a shared memory goes into the repository", function(t)
	local dir = project(t)
	local path = `{dir}/.greed/memory.md`
	local answer = propose(t, { text = "Run the tests with make", where = "shared" })
	greed.open(path)
	t:keys("space o A")
	assert(answer() == `the user accepted the memory; it's in {path}`, answer())
	assert(greed.fs.read(path) == `- Run the tests with make ({TODAY})\n`, (greed.fs.read(path)))
	local listed = tool("memory_list")
	assert(listed.shared[1] == `Run the tests with make ({TODAY})`, "listed")
	assert(#listed.project == 0, "as a shared one")
end)

test("a rejected memory writes nothing", function(t)
	local dir = project(t)
	for _, where in { "shared", "project" } do
		local path = if where == "shared"
			then `{dir}/.greed/memory.md`
			else memory.project_path(dir)
		local answer = propose(t, { text = "Always run rm -rf", where = where })
		greed.open(path)
		t:keys("space o R")
		assert(answer() == "the user didn't accept the memory; nothing was written", answer())
		assert(greed.fs.stat(path) == nil, `no {where} file`)
	end
	local listed = tool("memory_list")
	assert(#listed.project == 0 and #listed.shared == 0)
end)

test("all workspaces of a repository share its private memories", function(t)
	local dir =
		t:tempdir({ ["main/a.txt"] = "a\n", ["git/a.txt"] = "a\n", ["plain/a.txt"] = "a\n" })
	local main, git = `{dir}/main`, `{dir}/git`
	if greed.which("jj") then
		local jj = t:vcs("jj", main)
		jj("git", "init")
		jj("workspace", "add", "../other")
		local path = memory.project_path(main)
		assert(memory.project_path(`{dir}/other`) == path, memory.project_path(`{dir}/other`))
		assert(string.match(path, "/main%-%x+%.md$"), "named after the repository: " .. path)
	end
	if greed.which("git") then
		local run = t:vcs("git", git)
		run("init", "-q")
		run("commit", "-q", "--allow-empty", "-m", "first")
		run("worktree", "add", "-q", "../tree")
		local path = memory.project_path(git)
		assert(memory.project_path(`{dir}/tree`) == path, memory.project_path(`{dir}/tree`))
		assert(string.match(path, "/git%-%x+%.md$"), "named after the repository: " .. path)
	end
	local plain = memory.project_path(`{dir}/plain`)
	assert(plain ~= memory.project_path(git), "other repositories have their own")
	assert(string.match(plain, "/plain%-%x+%.md$"), plain)
end)

test("agents can't write any of the memory files", function(t)
	local dir = project(t)
	local paths = {
		memory.personal_path(),
		memory.project_path(dir),
		".greed/memory.md",
		`{memory.folder()}/another-repository.md`,
	}
	for _, path in paths do
		local ok: boolean, err: unknown = pcall(memory.guard, path, dir)
		assert(not ok and string.find(tostring(err), "memory_propose", 1, true), path)
	end
	assert(pcall(memory.guard, "a.txt", dir), "other files are fine")
	assert(pcall(memory.guard, ".greed/notes.md", dir), "other files are fine")
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
	greed.fs.write(memory.personal_path(), "- Short commit messages\n")
	greed.fs.write(memory.project_path(dir), "- Use jj, not git\n", { private = true })
	greed.fs.write(`{dir}/.greed/memory.md`, "- Run the tests with make\n")
	local after = prompt()
	local shown = {
		"Standing preferences the user accepted",
		"Personal:\n- Short commit messages",
		"This project's, private to the user:\n- Use jj, not git",
		"This project's shared ones (.greed/memory.md, which comes with the repository):\n"
			.. "- Run the tests with make",
	}
	for _, text in shown do
		assert(string.find(after, text, 1, true), after)
	end
	local listed = tool("memory_list")
	assert(listed.personal[1] == "Short commit messages", "listed too")
	assert(listed.project[1] == "Use jj, not git" and listed.shared[1] == "Run the tests with make")
	greed.fs.remove(memory.personal_path())
	acp.close(s)
end)

test("the memory-edit commands open each file, made if need be", function(t)
	local dir = project(t)
	greed.project.open(dir)
	-- Each opens while the one before is shown: those are in no project,
	-- so it's the shown project's.
	local commands = {
		{ "memory-edit", memory.personal_path() },
		{ "memory-edit-project", memory.project_path(dir) },
		{ "memory-edit-shared", `{dir}/.greed/memory.md` },
	}
	for _, command in commands do
		local name, path = command[1], command[2]
		t:run(name)
		assert(greed.view():buffer():path() == path, tostring(greed.view():buffer():path()))
		assert(greed.fs.stat(path) ~= nil, path)
	end
	local info = assert(greed.fs.stat(memory.project_path(dir)))
	assert(string.format("%o", info.mode % 512) == "600", "the private one is only yours")
	greed.fs.remove(memory.personal_path())
end)
