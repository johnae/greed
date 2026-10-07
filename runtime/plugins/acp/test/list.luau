local test = require("@greed/test")
local greed = require("@greed")
local acp = require("@acp")
local vcs = require("@vcs")

local FAKE: acp.Agent = {
	name = "fake",
	title = "Fake",
	commands = { { "sh", `{greed.plugin.dirs().acp}/test/fake-agent.sh` } },
}

acp.register(FAKE)

-- A session of the fake agent in `root`, its transcript shown and ready.
local function start(t: test.TestContext, root: string): any
	local s = assert(acp.start(FAKE, root))
	acp.show(s)
	t:wait_for(function()
		return s.status == "idle"
	end)
	t:wait(30)
	return s
end

-- Types `text` in the box of the transcript in view and sends it, then
-- waits for the agent's turn to end, or for it to ask something.
local function send(t: test.TestContext, s: any, text: string)
	local view = greed.view()
	local pos = view:buffer():len()
	view:set_selection({ ranges = { { anchor = pos, head = pos } }, primary = 1 })
	local keys = {}
	for char in string.gmatch(text, ".") do
		table.insert(keys, if char == " " then "space" else char)
	end
	t:keys(`i {table.concat(keys, " ")} esc alt-enter`)
	t:wait_for(function()
		return s.status == "idle" or s.status == "waiting" or s.status == "exited"
	end)
	t:wait(30)
end

-- The list's buffer, while it's open.
local function list_buffer(): greed.Buffer
	for _, buffer in greed.buffers() do
		if buffer:kind() == "agents" then
			return buffer
		end
	end
	error("the list isn't open")
end

-- The list's session lines, as shown.
local function rows(): { string }
	local lines = string.split(list_buffer():text(), "\n")
	return table.move(lines, 4, #lines, 1, {})
end

-- The views showing the transcript of `s`.
local function views_of(s: any): { greed.View }
	for _, buffer in greed.buffers() do
		if acp.of(buffer) == s then
			return buffer:views()
		end
	end
	return {}
end

local function close_all()
	for _, s in acp.sessions() do
		acp.close(s)
	end
end

test(
	"the list shows each session: the agent, what it was asked, status, time and tokens",
	function(t)
		local dir = t:tempdir({ ["a.txt"] = "a\n" })
		local first = start(t, dir)
		send(t, first, "usage")
		local second = start(t, dir)
		send(t, second, "edit a.txt")
		acp.list(dir)
		assert(greed.view():buffer():kind() == "agents")
		local lines = rows()
		assert(#lines == 2, table.concat(lines, "\n"))
		assert(
			string.find(lines[1], "^  Fake 2  edit a%.txt  waiting for you  just now$"),
			"the newest first: " .. lines[1]
		)
		assert(
			string.find(
				lines[2],
				"^  Fake    usage       idle             just now  14%.2k tokens$"
			),
			lines[2]
		)
		t:keys("q")
		assert(greed.view():buffer():kind() == "agent-transcript", "q closes it")
		close_all()
	end
)

test("a working session spins in the list with effects on, and stays still without", function(t)
	local dir = t:tempdir({})
	local s = start(t, dir)
	local view = greed.view()
	local pos = view:buffer():len()
	view:set_selection({ ranges = { { anchor = pos, head = pos } }, primary = 1 })
	t:keys("i w a i t esc alt-enter")
	acp.list(dir)
	local list = greed.view():buffer()
	assert(string.find(rows()[1], "● working", 1, true), rows()[1])
	t:wait(100)
	assert(#list:decorations("agents-spin") == 0, "still without effects")
	greed.option.set("effects", true)
	acp.list(dir)
	list = greed.view():buffer()
	t:wait_for(function()
		local spin = list:decorations("agents-spin")[1]
		return spin ~= nil and spin.text ~= nil and spin.text ~= "●"
	end)
	greed.option.set("effects", false)
	acp.stop(s)
	close_all()
end)

test("enter shows a session; one that exited is taken up again in its place", function(t)
	local dir = t:tempdir({})
	local s = start(t, dir)
	send(t, s, "hello")
	local transcript = greed.view()
	acp.stop(s)
	acp.list(dir)
	assert(string.find(rows()[1], "^  Fake  hello  exited"), rows()[1])
	t:keys("g g j j j enter")
	local again = acp.sessions()[1]
	assert(#acp.sessions() == 1 and again ~= s, "taken up in its place")
	t:wait_for(function()
		return again.status == "idle"
	end)
	assert(again.name == "Fake", again.name)
	assert(greed.view() == transcript, "where it was shown")
	assert(acp.of(transcript:buffer()) == again)
	t:wait(30)
	assert(string.find(transcript:buffer():text(), "an earlier answer", 1, true), "taken up")
	close_all()
end)

test("r takes up sessions without showing them, and leaves running ones be", function(t)
	local dir = t:tempdir({})
	local s = start(t, dir)
	send(t, s, "hello")
	acp.stop(s)
	local running = start(t, dir)
	acp.list(dir)
	local list = greed.view()
	t:keys("g g j j j m m r")
	assert(greed.view() == list, "the list stays")
	local sessions = acp.sessions()
	assert(
		#sessions == 2 and sessions[1] == running and sessions[2] ~= s,
		"only the one that exited"
	)
	t:wait_for(function()
		return sessions[2].status == "idle"
	end)
	assert(
		string.find(table.concat(rows(), "\n"), "exited", 1, true) == nil,
		table.concat(rows(), "\n")
	)
	t:keys("q")
	close_all()
end)

test("m marks several, and p shows them as panes side by side", function(t)
	local dir = t:tempdir({})
	t:buffer("|hello")
	t:draw(120, 30)
	local first = start(t, dir)
	local second = start(t, dir)
	acp.list(dir)
	t:keys("g g j j j m")
	assert(string.find(rows()[1], "^%* Fake 2"), rows()[1])
	assert(string.find(rows()[2], "^  Fake "), "the cursor moved on: " .. rows()[2])
	t:keys("m p")
	local panes = greed.tab.current().panes
	assert(#panes == 3, `{#panes} panes`)
	for _, s: any in { first, second } do
		local views = views_of(s)
		assert(#views == 1 and views[1]:is_pane(), "moved out of the panel into a pane")
		assert(s.status == "idle", s.status)
	end
	close_all()
end)

test(
	"space i m moves a transcript to a pane, a float, a tab and a panel; it keeps working",
	function(t)
		local dir = t:tempdir({})
		t:buffer("|hello")
		t:draw(120, 30)
		local s = start(t, dir)
		local function only_view(): greed.View
			local views = views_of(s)
			assert(#views == 1, `{#views} views`)
			assert(greed.view() == views[1], "focused")
			return views[1]
		end
		t:keys("space i m p")
		assert(only_view():is_pane(), "a pane")
		send(t, s, "hello")
		assert(string.find(greed.view():buffer():text(), "Hello there", 1, true), "it answers")
		t:keys("space i m w")
		assert(only_view():float_spec() ~= nil, "a float")
		assert((only_view():float_spec() :: any).title == "Fake")
		send(t, s, "usage")
		assert(s.tokens == 14200, tostring(s.tokens))
		t:keys("space i m t")
		local tab = greed.tab.current()
		assert(#greed.tab.list() == 2 and tab.name == "Fake", "a tab of its own")
		assert(only_view() == tab.panes[1])
		send(t, s, "hello")
		t:keys("space i m s")
		local panel = only_view()
		assert(not panel:is_pane() and panel:float_spec() == nil, "a panel")
		assert(#greed.tab.list() == 1, "the tab it left went with it")
		send(t, s, "hello")
		local _, replies = string.gsub(panel:buffer():text(), "Hello there", "")
		assert(replies == 3, `{replies} replies`)
		assert(#acp.sessions() == 1 and s.status == "idle", "the same session all along")
		close_all()
	end
)

test("the agent-show commands move the transcript too, and say so outside one", function(t)
	local dir = t:tempdir({})
	local s = start(t, dir)
	t:run("agent-show-float")
	assert(views_of(s)[1]:float_spec() ~= nil)
	t:run("agent-show-pane")
	assert(views_of(s)[1]:is_pane())
	t:run("agent-show-panel")
	local views = views_of(s)
	assert(#views == 1 and not views[1]:is_pane() and views[1]:float_spec() == nil)
	t:buffer("|a file")
	t:run("agent-show-float")
	assert(#views_of(s) == 1 and views_of(s)[1]:float_spec() == nil, "nothing moved")
	close_all()
end)

test("a second session's float is added beside the first", function(t)
	local dir = t:tempdir({})
	local first = start(t, dir)
	local second = start(t, dir)
	acp.show(first, "float")
	acp.show(second, "float")
	assert(views_of(first)[1]:float_spec() ~= nil and views_of(second)[1]:float_spec() ~= nil)
	assert(#require("@panes").floats.list() == 2)
	close_all()
end)

test("closing a transcript's view leaves the session running; x closes the session", function(t)
	local dir = t:tempdir({})
	local s = start(t, dir)
	send(t, s, "hello")
	greed.view():close()
	assert(#views_of(s) == 0)
	t:wait(50)
	assert(s.status == "idle" and #acp.sessions() == 1, "still running")
	acp.list(dir)
	t:keys("g g j j j enter")
	assert(#views_of(s) == 1, "shown again")
	assert(string.find(greed.view():buffer():text(), "Hello there", 1, true), "as it was")
	-- Even with its buffer closed, as :bc would, it shows again.
	local buffer = greed.view():buffer()
	greed.view():close()
	buffer:close()
	acp.show(s)
	assert(acp.of(greed.view():buffer()) == s)
	assert(string.find(greed.view():buffer():text(), "Hello there", 1, true), "as it was")
	acp.list(dir)
	t:keys("g g j j j x n")
	assert(#acp.sessions() == 1, "n keeps it")
	t:keys("x y")
	local status: string = s.status
	assert(#acp.sessions() == 0 and status == "exited", "y closes it")
	assert(string.find(rows()[1] or "", "No sessions yet", 1, true), rows()[1])
end)

test("/ narrows the list as you type, and esc puts back the filter there was", function(t)
	local dir = t:tempdir({})
	send(t, start(t, dir), "hello")
	send(t, start(t, dir), "usage")
	acp.list(dir)
	assert(#rows() == 2)
	t:keys("/ u s a")
	assert(#rows() == 1 and string.find(rows()[1], "usage", 1, true), rows()[1])
	t:keys("enter")
	assert(
		string.find(list_buffer():text(), "^Agent sessions   / usa\n") ~= nil,
		"it says the filter"
	)
	t:keys("/ backspace backspace backspace x esc")
	assert(#rows() == 1 and string.find(rows()[1], "usage", 1, true), "back to usa")
	t:keys("/ backspace backspace backspace q q q enter")
	assert(rows()[1] == "Nothing matches the filter.", rows()[1])
	t:keys("/ backspace backspace backspace enter")
	assert(#rows() == 2)
	t:keys("q")
	close_all()
end)

test("jj workspaces and git worktrees of one repository are one repository", function(t)
	if greed.which("jj") == nil or greed.which("git") == nil then
		return
	end
	local dir = t:tempdir({ ["main/a.txt"] = "a\n", ["plain/a.txt"] = "a\n" })
	local main = `{dir}/main`
	local jj = t:vcs("jj", main)
	jj("git", "init")
	jj("workspace", "add", "../other")
	local identity = vcs.repo.identity
	assert(identity(main) == `{main}/.jj/repo`, identity(main))
	assert(identity(`{dir}/other`) == identity(main), identity(`{dir}/other`))
	assert(identity(`{dir}/plain`) == `{dir}/plain`, "outside a repository, the folder")
	local repo = `{dir}/git`
	greed.fs.mkdir(repo)
	local git = t:vcs("git", repo)
	git("init", "-q")
	git("commit", "-q", "--allow-empty", "-m", "first")
	git("worktree", "add", "-q", "../tree")
	assert(identity(repo) == `{repo}/.git`, identity(repo))
	assert(identity(`{dir}/tree`) == identity(repo), identity(`{dir}/tree`))
end)

test("two workspaces of a repository share their sessions, the one you're in first", function(t)
	if greed.which("jj") == nil then
		return
	end
	local dir = t:tempdir({ ["main/a.txt"] = "a\n" })
	local main, other = `{dir}/main`, `{dir}/other`
	local jj = t:vcs("jj", main)
	jj("git", "init")
	jj("workspace", "add", "../other")
	local here = start(t, main)
	send(t, here, "hello")
	acp.stop(here)
	assert(#acp.saved(other) == 1 and acp.saved(other)[1].root == main, "kept for both")
	-- The fake agent calls every session s1, so this one is kept in its place.
	local there = start(t, other)
	send(t, there, "usage")
	acp.list(main)
	local lines = rows()
	assert(#lines == 2, table.concat(lines, "\n"))
	assert(
		string.find(lines[1], "^  Fake    hello  exited"),
		"this workspace's first: " .. lines[1]
	)
	assert(string.find(lines[2], "^  Fake 2  usage .* in other$"), lines[2])
	t:keys("q")
	acp.list(other)
	lines = rows()
	assert(string.find(lines[1], "^  Fake 2  usage"), lines[1])
	assert(string.find(lines[2], "in main$"), lines[2])
	-- An agent that keeps its sessions by folder can't move with h.
	t:keys("g g j j j j h")
	local messages = t:messages()
	assert(
		messages[#messages] == "can't take up Fake here: Fake keeps its sessions by folder",
		messages[#messages]
	)
	-- Taken up from the other workspace, it works in its own.
	t:keys("g g j j j j enter")
	local again = acp.of(greed.view():buffer())
	assert(again and again.root == main and again.cwd == main, "in its own workspace")
	close_all()
end)

test("Greed's own sessions kept per project folder move to their repository's", function(t)
	if greed.which("jj") == nil then
		return
	end
	local dir = t:tempdir({ ["main/a.txt"] = "a\n" })
	local main, other = `{dir}/main`, `{dir}/other`
	local jj = t:vcs("jj", main)
	jj("git", "init")
	jj("workspace", "add", "../other")
	local base = `{assert(greed.fs.dirs().data)}/agent-sessions`
	local function write_old(root: string, id: string)
		local name = string.match(root, "[^/]+$")
		local old = `{base}/{name}-{string.sub(greed.hash.sha256(root), 1, 12)}`
		local entry = { agent = "greed", root = root, session_id = id, title = id, time = 1 }
		greed.fs.write(`{old}/index.json`, greed.json.encode(greed.json.array({ entry })))
		greed.fs.write(`{old}/{id}.json`, "{}")
		return old
	end
	local old_main = write_old(main, "one")
	local old_other = write_old(other, "two")
	local kept = acp.saved(other)
	assert(#kept == 2, `{#kept} kept`)
	assert(not greed.fs.stat(old_main) and not greed.fs.stat(old_other), "moved")
	local ids = {}
	for _, entry in kept do
		ids[entry.session_id] = entry.root
	end
	assert(ids.one == main and ids.two == other, "each with the folder it ran in")
	assert(#acp.saved(main) == 2, "the same for every workspace")
end)

test("a kept session shows as saved; enter takes it up, x forgets it without asking", function(t)
	local dir = t:tempdir({})
	local file = `{assert(greed.fs.dirs().cache)}/agents.json`
	local function keep(id: string, title: string, ago: number)
		local text = greed.fs.read(file)
		local all = if text then greed.json.decode(text) else {}
		local entry =
			{ agent = "fake", root = dir, session_id = id, title = title, time = os.time() - ago }
		table.insert(all, entry)
		greed.fs.write(file, greed.json.encode(greed.json.array(all)))
	end
	keep("old1", "an earlier task", 7200)
	keep("old2", "another one", 3 * 86400)
	acp.list(dir)
	local lines = rows()
	assert(#lines == 2, table.concat(lines, "\n"))
	assert(string.find(lines[1], "^  Fake  an earlier task  saved  2 h ago$"), lines[1])
	assert(string.find(lines[2], "^  Fake  another one      saved  3 days ago$"), lines[2])
	t:keys("g g j j j j x")
	assert(#rows() == 1 and string.find(rows()[1], "an earlier task", 1, true), "forgotten at once")
	assert(not string.find(greed.fs.read(file) or "", "old2", 1, true), "and not kept")
	t:keys("g g j j j enter")
	local s = assert(acp.of(greed.view():buffer()), "taken up and shown")
	t:wait_for(function()
		return s.status == "idle"
	end)
	t:wait(30)
	assert(s.session_id == "old1", tostring(s.session_id))
	assert(string.find(greed.view():buffer():text(), "an earlier answer", 1, true), "told again")
	close_all()
end)

test("f in the list forks the session under the cursor and shows the fork", function(t)
	local dir = t:tempdir({})
	local s = start(t, dir)
	send(t, s, "hello")
	acp.list(dir)
	t:keys("g g j j j f")
	local fork = acp.of(greed.view():buffer())
	assert(fork and fork ~= s and #acp.sessions() == 2, "forked")
	t:wait_for(function()
		return fork.status == "idle"
	end)
	t:wait(30)
	assert(
		string.find(greed.view():buffer():text(), "forked from Fake", 1, true),
		"with all said so far"
	)
	close_all()
end)
