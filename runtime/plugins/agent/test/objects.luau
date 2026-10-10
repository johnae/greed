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
