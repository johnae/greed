local test = require("@greed/test")
local greed = require("@greed")
local service = require("@service")

-- What the tests put in place of the session, starting and the socket,
-- put back after each.
local saved: { [string]: any } = {
	session = service.session,
	start = service.start,
	connect = service.connect,
	send = service.send,
	TRIES = service.TRIES,
	RETRY = service.RETRY,
	AGAIN = service.AGAIN,
}

local function restore()
	for key, value in saved do
		(service :: any)[key] = value
	end
end

local function as(session: string)
	service.session = function(): string?
		return session
	end
end

-- Each test's own service name, as nothing defined goes between tests.
local count = 0
local function fresh(): string
	count += 1
	return `counter{count}`
end

-- Links standing in for `greed mcp` to the owner's session: requests are
-- answered here as the owner's socket would, notifications come back.
type Fake = { heard: (string, any) -> (), exited: (string) -> (), link: any }
local links: { [number]: Fake } = {}
local connection = 0
local started: { string } = {}

local function fake_socket()
	service.start = function(session: string): (boolean?, string?)
		table.insert(started, session)
		return true, nil
	end
	service.connect = function(_, heard, exited)
		connection += 1
		local id = connection
		local link = { open = true }
		function link.request(_, method: string, params: any): (any, string?)
			if not link.open then
				return nil, "closed"
			end
			local ok, result = pcall(service.answer, method, params, id)
			if ok then
				return result
			end
			return nil, tostring(result)
		end
		function link.close(_)
			link.open = false
			links[id] = nil
			service.closed(id)
		end
		links[id] = { heard = heard, exited = exited, link = link }
		return link :: any
	end
	service.send = function(id: number, method: string, params: any): boolean
		local fake = links[id]
		if fake then
			greed.spawn(fake.heard, method, params)
		end
		return fake ~= nil
	end
end

-- The owner's session going away under every link.
local function owner_went()
	for id, fake in links do
		links[id] = nil
		fake.link.open = false
		service.closed(id)
		fake.exited("gone")
	end
end

-- Runs `f` as a task, as commands do, and waits for it to end.
local function run(t: any, f: () -> ())
	local done = false
	greed.spawn(function()
		f()
		done = true
	end)
	t:wait_for(function()
		return done
	end, 5000)
end

-- A counter's owner, offered as `name`'s, counting who asked.
local function counter(name: string): (any, { string? })
	local count = 0
	local callers: { string? } = {}
	local offer: service.Offer
	offer = service.offer(name, {
		version = 1,
		handle = function(method: string, params: any, caller: service.Caller): (any, string?)
			table.insert(callers, caller.session)
			if method == "get" then
				return { count = count }
			elseif method == "add" then
				count += params.by
				offer:notify("count", { count = count })
				return { count = count }
			end
			return nil, `no {method}`
		end,
	})
	return offer, callers
end

test("in the owner's session a view reaches it directly, and hears what it listens to", function(t)
	local name = fresh()
	as(service.session_of(name))
	local _, callers = counter(name)
	local heard: { number } = {}
	local resets = 0
	local view = service.use(name, {
		version = 1,
		topics = { "count" },
		on = function(topic: string, params: any)
			assert(topic == "count", topic)
			table.insert(heard, params.count)
		end,
		reset = function()
			resets += 1
		end,
	})
	assert(view:state() == "ready", "ready at once, with nothing to connect to")
	run(t, function()
		local got = view:request("add", { by = 2 })
		assert(got.count == 2, "the owner's answer")
		local none, why = view:request("nope")
		assert(none == nil and why == "no nope", tostring(why))
	end)
	t:wait(10)
	assert(view:state() == "ready")
	assert(resets == 1, "reset once it reached the owner")
	assert(#heard == 1 and heard[1] == 2, "heard the change")
	assert(callers[1] == service.session_of(name), "the owner knows who asked")
	view:ignore("count")
	run(t, function()
		view:request("add", { by = 1 })
	end)
	t:wait(10)
	assert(#heard == 1, "nothing once it ignores it")
	view:close()
	restore()
end)

test(
	"in the owner's session a view made before the offer hears from it once it's offered",
	function(t)
		local name = fresh()
		as(service.session_of(name))
		local heard: { number } = {}
		local view = service.use(name, {
			version = 1,
			topics = { "count" },
			on = function(_, params: any)
				table.insert(heard, params.count)
			end,
		})
		assert(view:state() == "idle", "nothing offered yet")
		local offer = counter(name)
		assert(view:state() == "ready")
		offer:notify("count", { count = 7 })
		t:wait(10)
		assert(#heard == 1 and heard[1] == 7, "heard without asking first")
		view:close()
		restore()
	end
)

test(
	"from another session a view starts the owner's session, asks it and hears its changes",
	function(t)
		fake_socket()
		local name = fresh()
		as(service.session_of(name))
		local _, callers = counter(name)
		as("project")
		local heard: { number } = {}
		local resets = 0
		local view = service.use(name, {
			version = 1,
			topics = { "count" },
			on = function(_, params: any)
				table.insert(heard, params.count)
			end,
			reset = function()
				resets += 1
			end,
		})
		run(t, function()
			local got = view:request("add", { by = 5 })
			assert(got and got.count == 5, "the owner's answer over the socket")
			local _, why = view:request("nope")
			assert(why == "no nope", tostring(why))
		end)
		t:wait(10)
		assert(table.find(started, service.session_of(name)), "started the owner's session")
		assert(view:state() == "ready")
		assert(resets == 1, "reset once")
		assert(#heard == 1 and heard[1] == 5, "heard the change over the socket")
		assert(callers[1] == "project", "the owner knows which session asked")
		view:close()
		restore()
	end
)

test("an owner that never answers leaves the view unreachable, saying why", function(t)
	local name = fresh()
	as("project")
	service.TRIES = 2
	service.RETRY = 1
	service.start = function(): (boolean?, string?)
		return nil, "the editor didn't start: boom"
	end
	local view = service.use(name, { version = 1 })
	local why: string?
	run(t, function()
		local _, said = view:request("get")
		why = said
	end)
	assert(why == "the editor didn't start: boom", tostring(why))
	local state, since, said = view:state()
	assert(state == "unreachable" and since ~= nil and said == why, state)
	view:close()
	restore()
end)

test("an owner still loading is asked again until it offers", function(t)
	fake_socket()
	service.RETRY = 1
	local name = fresh()
	as("project")
	local view = service.use(name, { version = 1 })
	local got: any
	run(t, function()
		greed.spawn(function()
			-- The owner's session listens before its plugins offer anything.
			greed.sleep(5)
			as(service.session_of(name))
			counter(name)
			as("project")
		end)
		got = view:request("get")
	end)
	assert(got and got.count == 0, "answered once offered")
	view:close()
	restore()
end)

test("an owner of another version says which to restart", function(t)
	fake_socket()
	local name = fresh()
	as(service.session_of(name))
	counter(name)
	as("project")
	local newer = service.use(name, { version = 2 })
	local why: string?
	run(t, function()
		local _, said = newer:request("get")
		why = said
	end)
	assert(why and string.find(why, `:service-restart {name}`, 1, true), tostring(why))
	newer:close()
	local older = service.use(name, { version = 0 })
	run(t, function()
		local _, said = older:request("get")
		why = said
	end)
	assert(why and string.find(why, "this session is older", 1, true), tostring(why))
	older:close()
	restore()
end)

test("a view that listens connects again once the owner comes back, and fetches again", function(t)
	fake_socket()
	service.AGAIN = 1
	local name = fresh()
	as(service.session_of(name))
	counter(name)
	as("project")
	local resets = 0
	local view = service.use(name, {
		version = 1,
		topics = { "count" },
		reset = function()
			resets += 1
		end,
	})
	run(t, function()
		view:request("get")
	end)
	t:wait(10)
	assert(resets == 1)
	owner_went()
	local state, _, why = view:state()
	assert(state == "unreachable" and why == `the {name} service went`, tostring(why))
	t:wait_for(function()
		return view:state() == "ready" and resets == 2
	end, 5000)
	view:close()
	restore()
end)

test("a service is defined once, and offered only in its own session", function()
	local name = fresh()
	service.define({ name = name, start = "use" })
	local ok, err = pcall(function()
		service.define({ name = name, start = "always" })
	end)
	assert(not ok and string.find(tostring(err), `called {name} already`, 1, true), tostring(err))
	assert(table.find(service.defined(), name))
	as("project")
	assert(not service.owner(name))
	local offered, why = pcall(service.offer, name, {
		version = 1,
		handle = function()
			return nil
		end,
	})
	assert(not offered and string.find(tostring(why), "in its own session", 1, true), tostring(why))
	as(service.session_of(name))
	assert(service.owner(name))
	-- Not a session at all, there's nothing else to reach.
	service.session = function(): string?
		return nil
	end
	assert(service.owner(name), "owns everything")
	restore()
end)

test("a service's session is the name with .service after it", function()
	assert(service.session_of("chat") == "chat.service")
end)

test("nothing starts with Greed until you name it, set up or not", function(t)
	assert(greed.option.get("services-at-start") == "", "none named by default")
	local config = assert(greed.fs.dirs().config)
	greed.fs.write(`{config}/mail.toml`, "")
	local before = greed.option.get("notes-folder")
	greed.option.set("notes-folder", t:tempdir({ ["today.md"] = "# Today\n" }))
	local started: { string } = {}
	for _, name in { "mail", "chat", "hoard" } do
		if service.starts_with_greed(name) then
			table.insert(started, name)
		end
	end
	greed.option.set("services-at-start", "mail hoard")
	local named = service.starts_with_greed("mail") and service.starts_with_greed("hoard")
	greed.option.set("services-at-start", "")
	greed.fs.remove(`{config}/mail.toml`)
	greed.option.set("notes-folder", before)
	assert(#started == 0, table.concat(started, " "))
	assert(named, "named, they would")
end)

test("searching everything starts nothing and says nothing of what isn't set up", function()
	local asked: { string } = {}
	as("myproject")
	service.start = function(session: string): (boolean?, string?)
		table.insert(asked, session)
		return nil, "not in a test"
	end
	local ok, err = pcall(function()
		local _, troubles = require("@core").everywhere.search("lunch")
		assert(#troubles == 0, table.concat(troubles, " | "))
	end)
	restore()
	assert(ok, tostring(err))
	assert(#asked == 0, "started " .. table.concat(asked, " "))
end)
