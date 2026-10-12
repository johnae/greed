local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")
local agent = require("@agent")

local function tool(name: string): agent.Tool
	for _, found in agent.tools() do
		if found.name == name then
			return found
		end
	end
	error(`no tool {name}`)
end

local function run(name: string, args: { [string]: any }?): any
	return tool(name).run(args or {}, agent.caller())
end

-- A kind of ticket for the tests, with an action that records it ran.
local closed: string? = nil
local function tickets()
	local function ticket(key: string): core.Object
		return { kind = "ticket", id = `ticket:{key}`, label = `ticket {key}`, value = key }
	end
	core.objects.kind({
		name = "ticket",
		doc = "A ticket",
		list = function()
			return { ticket("A-1"), ticket("A-2"), ticket("B-1") }
		end,
		get = function(key)
			return if key == "A-1" or key == "A-2" or key == "B-1" then ticket(key) else nil
		end,
		inspect = function(key)
			return { status = if closed == key then "closed" else "open", view = greed.view() }
		end,
		relations = function(key)
			return { blocks = if key == "A-1" then { ticket("A-2") } else {} }
		end,
	})
	core.actions.action({
		kind = "ticket",
		name = "close",
		doc = "Close it",
		run = function(target)
			closed = target.value
		end,
	})
end

test("the object tools are always offered, and act asks first", function()
	for _, name in { "objects", "inspect", "act" } do
		assert(tool(name).group == nil, `{name} is in no group`)
	end
	assert(not agent.asks(tool("objects")) and not agent.asks(tool("inspect")))
	assert(agent.asks(tool("act")), "act does more than read")
end)

test(
	"objects lists the kinds, a kind's objects with a filter, and an object's relations",
	function()
		tickets()
		local kinds = run("objects")
		local counts = {}
		for _, kind in kinds.kinds do
			counts[kind.kind] = kind.count
		end
		assert(counts.ticket == 3 and counts.buffer ~= nil, greed.json.encode(counts))
		local some = run("objects", { kind = "ticket", filter = "a-", limit = 1 })
		assert(#some.objects == 1 and some.total == 2, greed.json.encode(some))
		assert(some.objects[1].id == "ticket:A-1")
		local related = run("objects", { related_to = "ticket:A-1" })
		assert(related.blocks.objects[1].id == "ticket:A-2", greed.json.encode(related))
	end
)

test("inspect gives an object's state as plain data, its relations and actions", function()
	tickets()
	local seen = run("inspect", { id = "ticket:A-1" })
	assert(seen.state.status == "open" and type(seen.state.view) == "string", "handles as text")
	assert(seen.related.blocks.total == 1)
	assert(seen.actions[1].name == "close" and seen.actions[1].doc == "Close it")
	local ok, err = pcall(run, "inspect", { id = "ticket:Z-9" })
	assert(not ok and string.find(tostring(err), "no object ticket:Z-9", 1, true), tostring(err))
end)

test(
	"act runs an action on the object and gives back its state; it names the actions there are",
	function()
		tickets()
		local done = run("act", { id = "ticket:B-1", action = "close" })
		assert(closed == "B-1" and done.state.status == "closed", greed.json.encode(done.state))
		local ok, err = pcall(run, "act", { id = "ticket:B-1", action = "fly" })
		assert(not ok and string.find(tostring(err), "it has close", 1, true), tostring(err))
	end
)

test("act on several ids reviews a destroying action once, and says which the user ran", function(t)
	tickets()
	local deleted: { string } = {}
	core.actions.action({
		kind = "ticket",
		name = "delete",
		danger = true,
		run = function(target)
			table.insert(deleted, target.value)
		end,
	})
	t:buffer("|x")
	local result: any = nil
	greed.spawn(function()
		result = run("act", { ids = { "ticket:A-1", "ticket:A-2" }, action = "delete" })
	end)
	local review = table.concat(t:floats(), "\n")
	assert(string.find(review, "delete  ticket A-1", 1, true), review)
	-- The user keeps A-1 and deletes A-2.
	t:keys("space enter")
	t:wait_for(function()
		return result ~= nil
	end)
	assert(#deleted == 1 and deleted[1] == "A-2", table.concat(deleted, ","))
	assert(result.on[1] == "ticket:A-2" and result.declined[1] == "ticket:A-1")
end)

test("a risky tool call waits for the user's yes, and says so when it doesn't get it", function(t)
	local ran: { string } = {}
	agent.tool({
		name = "frob",
		description = "Frobs",
		kind = "execute",
		danger = function(args)
			return if args.hard then "frobs hard" else nil
		end,
		run = function(args)
			table.insert(ran, if args.hard then "hard" else "soft")
			return "frobbed"
		end,
	})
	t:buffer("|x")
	local soft = agent.call("frob", { hard = false }, agent.caller())
	assert(not soft.isError and ran[1] == "soft", "a safe call runs")
	local result: any = nil
	greed.spawn(function()
		result = agent.call("frob", { hard = true }, agent.caller())
	end)
	local review = table.concat(t:floats(), "\n")
	assert(string.find(review, "frobs hard", 1, true), review)
	t:keys("esc")
	t:wait_for(function()
		return result ~= nil
	end)
	assert(result.isError and #ran == 1, agent.as_text(result))
	greed.spawn(function()
		result = agent.call("frob", { hard = true }, agent.caller())
	end)
	t:keys("enter")
	t:wait_for(function()
		return #ran == 2
	end)
	assert(ran[2] == "hard")
end)

test("agents find commands by what they do and run one, its arguments checked", function(t)
	local greeted: string? = nil
	greed.command({
		name = "test-greet",
		doc = "Greets someone by name",
		args = {
			{ name = "who", type = "string" },
			{ name = "times", type = "number", optional = true },
		},
		run = function(ctx)
			greeted = `{ctx.values.who} x{ctx.values.times or 1}`
		end,
	})
	local found = run("commands", { query = "greets someone" })
	assert(type(found) == "table" and found[1].name == "test-greet", greed.json.encode(found))
	assert(
		found[1].usage == "test-greet WHO [TIMES]" or string.find(found[1].usage, "WHO", 1, true),
		found[1].usage
	)
	assert(found[1].args[2] == "times number optional", greed.json.encode(found[1].args))
	run("run_command", { name = "test-greet", args = { "you", "2" } })
	assert(greeted == "you x2", tostring(greeted))
	local ok, err = pcall(run, "run_command", { name = "test-greet", args = { "you", "lots" } })
	assert(not ok and string.find(tostring(err), "isn't a number", 1, true), tostring(err))
	local danger = assert(tool("run_command").danger)
	assert(danger({ name = "quit-session" }) ~= nil, "quitting asks")
	assert(danger({ name = "test-greet" }) == nil)
end)

-- A file pane, and beside it an agent's chat pane that has focus.
local function chat_beside_file(t: any): (greed.View, greed.View)
	local dir = t:tempdir({ ["a.txt"] = "a\n", ["b.txt"] = "b\n" })
	greed.open(dir .. "/a.txt")
	local file = greed.view():split("down", greed.load(dir .. "/b.txt"))
	file:focus()
	t:wait(0)
	local chat = file:split("right", greed.create_buffer("agent-transcript", ""))
	chat:focus()
	t:wait(0)
	return file, chat
end

test("run_command acts on the file pane you were in, not the agent's chat", function(t)
	local file, chat = chat_beside_file(t)
	run("run_command", { name = "pane-close" })
	assert(not file:valid(), "the file pane closed")
	assert(chat:valid() and greed.view() == chat, "the chat stays, and keeps focus")
end)

test("run_command runs in the view given by id", function(t)
	local file, chat = chat_beside_file(t)
	local other = greed.tab.current().panes[1]
	assert(other ~= file and other ~= chat)
	run("run_command", { name = "pane-close", view = `view:{other:id()}` })
	assert(not other:valid() and file:valid() and chat:valid())
	local ok, err = pcall(run, "run_command", { name = "pane-close", view = "buffer:1" })
	assert(not ok and string.find(tostring(err), "view", 1, true), tostring(err))
end)

test("act closes a view by its id, and a buffer, refusing over unsaved changes", function(t)
	local file, chat = chat_beside_file(t)
	local float = greed.float(greed.create_buffer("scratch", "output"))
	chat:focus()
	run("act", { id = `view:{float:id()}`, action = "close" })
	assert(not float:valid() and chat:valid(), "the float closed")
	run("act", { id = `view:{file:id()}`, action = "close" })
	assert(not file:valid() and chat:valid(), "the pane closed")
	local buffer = greed.view():buffer()
	local edited = greed.tab.current().panes[1]:buffer()
	edited:edit(function(e)
		e:insert(0, "x")
	end)
	local ok, err = pcall(run, "act", { id = `buffer:{edited:id()}`, action = "close" })
	assert(not ok and string.find(tostring(err), "unsaved changes", 1, true), tostring(err))
	assert(edited:valid() and buffer:valid())
end)

test("commands matches each word of the query, those matching most first", function()
	greed.command({ name = "test-zork-frob", doc = "Zorks the frob", run = function() end })
	greed.command({ name = "test-zork", doc = "Zorks it", run = function() end })
	local found = run("commands", { query = "frob zork" })
	assert(type(found) == "table", tostring(found))
	assert(
		found[1].name == "test-zork-frob" and found[2].name == "test-zork",
		greed.json.encode(found)
	)
	assert(type(run("commands", { query = "zzqx wwqy" })) == "string", "nothing found")
end)

test("run_command says the view it ran in and, when they changed, the views now", function(t)
	local file, chat = chat_beside_file(t)
	local said = run("run_command", { name = "pane-close" })
	assert(string.find(said, `ran pane-close in view:{file:id()} b.txt (pane)`, 1, true), said)
	assert(string.find(said, "views now: ", 1, true), said)
	assert(string.find(said, `view:{chat:id()} agent-transcript (pane)`, 1, true), said)
	local views = assert(string.match(said, "views now: (.*)$"))
	assert(not string.find(views, `view:{file:id()} `, 1, true), said)
	greed.command({ name = "test-quiet", doc = "Does nothing", run = function() end })
	said = run("run_command", { name = "test-quiet" })
	assert(not string.find(said, "views now", 1, true), said)
end)

test("run_command's question names the view a closing command would run in", function(t)
	local file = chat_beside_file(t)
	local danger = assert(tool("run_command").danger)
	local why = assert(danger({ name = "pane-close" }))
	assert(string.find(why, `view:{file:id()} b.txt (pane)`, 1, true), why)
end)

test("objects lists panels too, and act names what it ran on and the views now", function(t)
	t:buffer("|x")
	local panel = greed.panel(greed.create_buffer("agent-transcript", ""), { side = "right" })
	local listed = run("objects", { kind = "view", filter = "panel" })
	assert(listed.objects[1].id == `view:{panel:id()}`, greed.json.encode(listed))
	assert(listed.objects[1].label == "agent-transcript (panel)", listed.objects[1].label)
	local done = run("act", { id = `view:{panel:id()}`, action = "close" })
	assert(not panel:valid() and done.gone, greed.json.encode(done))
	assert(done.targets[1] == `view:{panel:id()} agent-transcript (panel)`, greed.json.encode(done))
	assert(type(done.views_now) == "string", greed.json.encode(done))
	assert(not string.find(done.views_now, "panel", 1, true), done.views_now)
end)
