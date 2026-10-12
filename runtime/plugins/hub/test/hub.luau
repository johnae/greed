local test = require("@greed/test")
local hub = require("@hub")

test("the hub is the session hub-session names, else the first of this build by name", function()
	local sessions: any = {
		{ name = "world", build = "b1" },
		{ name = "greed", build = "old" },
		{ name = "cloud", build = "b1" },
	}
	assert(hub.elect(sessions, "b1", nil) == "cloud", "first by name, of this build")
	assert(hub.elect(sessions, "b1", "world") == "world", "the one named")
	assert(
		hub.elect(sessions, "b1", "gone") == "cloud",
		"one named that isn't running doesn't count"
	)
	local old: any = { { name = "greed", build = "old" } }
	assert(hub.elect(old, "b1", nil) == nil, "none of this build")
end)

test("what a watched session prints comes as whole lines, the rest kept for later", function()
	local lines, rest = hub.lines('{"a":1}\n{"b":')
	assert(#lines == 1 and lines[1] == '{"a":1}' and rest == '{"b":', rest)
	local more, left = hub.lines(rest .. "2}\n")
	assert(#more == 1 and more[1] == '{"b":2}' and left == "", tostring(#more))
end)

test("each machine you're attached from is told once, through one of its clients", function()
	local statuses: any = {
		b = { clients = { "gui@laptop", "tui@laptop" } },
		a = { clients = { "tui@laptop" } },
		c = { clients = { "gui@desk" } },
		d = { clients = {} },
	}
	local where = hub.reachable(statuses)
	assert(
		where.laptop.session == "a" and where.laptop.client == "tui@laptop",
		where.laptop.session
	)
	assert(where.desk.session == "c" and where.desk.client == "gui@desk", "the other machine")
	local count = 0
	for _ in where do
		count += 1
	end
	assert(count == 2, `{count} machines`)
end)

test("an agent waiting is told with what it waits on, and once per time it waits", function()
	local agents: { any } = {
		{ id = "terminal:5", label = "claude", status = "waiting", since = 100 },
		{ id = "agent-session:1", label = "Greed", status = "working" },
		{ id = "agent-session:2", label = "Greed 2", status = "waiting", question = "Edit a.txt" },
	}
	local statuses: any = {
		["greed-2"] = { agents = agents },
	}
	local waiting = hub.waiting(statuses)
	assert(#waiting == 2, tostring(#waiting))
	local session = waiting[1]
	assert(
		session.title == "Greed 2 waits for you" and session.body == "Edit a.txt · greed-2",
		session.body
	)
	assert(waiting[2].key == "greed-2|terminal:5|100", waiting[2].key)
	-- Waiting again later is another time to tell.
	statuses["greed-2"].agents[1].since = 200
	assert(hub.waiting(statuses)[2].key == "greed-2|terminal:5|200")
end)

test("hub_notify tells the client of this session it names, and says when there's none", function(t)
	local greed = require("@greed")
	local agent = require("@agent")
	t:buffer("|")
	local name = greed.client.list()[1].name
	local tool: agent.Tool? = nil
	for _, found in agent.tools() do
		if found.name == "hub_notify" then
			tool = found
		end
	end
	local run = (tool :: agent.Tool).run
	assert(
		run({ title = "Claude waits", body = "in greed-2", client = name }, agent.caller())
			== "told"
	)
	local notices = t:notices()
	assert(#notices == 1 and notices[1].title == "Claude waits", tostring(#notices))
	assert(
		run({ title = "x", client = "gui@nowhere" }, agent.caller()) == "no client gui@nowhere here"
	)
end)

test("an agent on another machine is told with the machine, and apart from one here", function()
	local statuses: any = {
		["greed-2"] = {
			agents = { { id = "terminal:5", label = "claude", status = "waiting", since = 100 } },
		},
	}
	local there = hub.waiting(statuses, { id = "ab12", name = "eris" })[1]
	assert(there.key == "ab12|greed-2|terminal:5|100", there.key)
	assert(there.body == "claude · greed-2 on eris", there.body)
	assert(hub.waiting(statuses)[1].key ~= there.key, "the same agent here is another")
end)

test("hub-hosts names more machines to follow", function(t)
	local greed = require("@greed")
	local data = hub.dirs.data
	hub.dirs.data = t:tempdir()
	greed.option.set("hub-hosts", "eris  mini,box")
	local hosts = hub.hosts()
	greed.option.set("hub-hosts", "")
	assert(table.concat(hosts, " ") == "box eris mini", table.concat(hosts, " "))
	assert(#hub.hosts() == 0)
	hub.dirs.data = data
end)

test("another machine's agent is placed on it", function()
	assert(hub.place({ session = "greed-2", agent = {} }) == "greed-2")
	assert(hub.place({ session = "greed-2", agent = {}, machine = "eris" }) == "greed-2 on eris")
end)

test("machines you reached with greed ssh lately are followed, and can be forgotten", function(t)
	local greed = require("@greed")
	local data = hub.dirs.data
	hub.dirs.data = t:tempdir()
	local file = `{hub.dirs.data}/ssh-hosts`
	local now = os.time()
	greed.fs.write(
		file,
		greed.json.encode({ eris = now - 60, old = now - hub.REMEMBER - 60, odd = "x" })
	)
	greed.option.set("hub-hosts", "mini")
	local hosts = hub.hosts()
	assert(table.concat(hosts, " ") == "eris mini", table.concat(hosts, " "))
	hub.forget("eris")
	assert(hub.reached().eris == nil and hub.reached().old ~= nil, "eris forgotten")
	greed.option.set("hub-hosts", "")
	assert(#hub.hosts() == 0, table.concat(hub.hosts(), " "))
	greed.fs.write(file, "not json")
	assert(next(hub.reached()) == nil, "a broken file is no machines")
	hub.dirs.data = data
end)

test("what can't be followed is left alone longer each time, up to half an hour", function()
	assert(hub.backoff(1) == hub.SKIP)
	assert(hub.backoff(2) == 2 * hub.SKIP)
	assert(hub.backoff(3) == 4 * hub.SKIP)
	assert(hub.backoff(20) == hub.SKIP_MOST)
end)
