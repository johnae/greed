local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")

local objects = core.objects

-- Tickets for the tests: A-1 blocks A-2.
local TICKETS = {
	["A-1"] = { status = "open", blocks = { "A-2" } },
	["A-2"] = { status = "done", blocks = {} },
}

local function ticket(key: string): core.Object
	return { kind = "ticket", id = `ticket:{key}`, label = key, value = key }
end

local function tickets()
	objects.kind({
		name = "ticket",
		doc = "A ticket in the tracker",
		list = function()
			return { ticket("A-1"), ticket("A-2") }
		end,
		get = function(key)
			return if TICKETS[key] then ticket(key) else nil
		end,
		inspect = function(key)
			return { status = TICKETS[key].status }
		end,
		relations = function(key)
			local blocks = {}
			for _, other in TICKETS[key].blocks do
				table.insert(blocks, ticket(other))
			end
			return { blocks = blocks }
		end,
	})
end

test("a kind's objects are listed, found by id, inspected and related", function()
	tickets()
	local listed = objects.list("ticket")
	assert(#listed == 2 and listed[1].id == "ticket:A-1", greed.json.encode(listed))
	local one = assert(objects.get("ticket:A-1"))
	assert(one.label == "A-1")
	assert(objects.get("ticket:Z-9") == nil, "one that isn't there")
	assert(objects.get("nothing:at-all") == nil, "a kind that isn't there")
	assert(objects.inspect(one).status == "open")
	local blocks = objects.related(one).blocks
	assert(#blocks == 1 and blocks[1].id == "ticket:A-2", greed.json.encode(blocks))
end)

test("an object's actions are its kind's, and act runs one", function()
	tickets()
	local ran: string? = nil
	core.actions.action({
		kind = "ticket",
		name = "close",
		doc = "Close it",
		run = function(target)
			ran = target.value
		end,
	})
	local one = assert(objects.get("ticket:A-1"))
	local names = {}
	for _, action in objects.actions(one) do
		table.insert(names, action.name)
	end
	assert(table.find(names, "close"), table.concat(names, " "))
	assert(objects.act(one, "close") and ran == "A-1")
	assert(not objects.act(one, "fly"), "an action it hasn't")
end)

test("buffers, views, tabs and plugins are objects, related to each other", function(t)
	t:buffer("|hello\nworld")
	local view = greed.view()
	local buffer = view:buffer()
	local b = assert(objects.get(`buffer:{buffer:id()}`))
	local state = objects.inspect(b)
	assert(state.lines == 2 and state.modified == false, greed.json.encode(state))
	local views = objects.related(b).views
	assert(#views >= 1 and views[1].id == `view:{view:id()}`, `{#views} views`)
	local v = assert(objects.get(`view:{view:id()}`))
	assert(objects.related(v).buffer[1].id == b.id, "a view shows its buffer")
	local tab = assert(objects.get(`tab:{greed.tab.current().id}`))
	local panes = objects.related(tab).panes
	assert(panes[1].id == v.id, `{#panes} panes`)
	assert(objects.related(v).tab[1].id == tab.id, "and is in its tab")
	local plugin = assert(objects.get("plugin:core"))
	assert(objects.inspect(plugin).dir ~= nil)
end)

test("the editor object relates every kind that can be listed", function()
	tickets()
	local editor = assert(objects.get("editor:"))
	local related = objects.related(editor)
	for _, kind in { "buffer", "tab", "plugin", "ticket" } do
		assert(related[kind] and #related[kind] > 0, kind)
	end
	assert(related.editor == nil, "not itself")
end)

test("what's under the cursor is an object when its kind can name it", function(t)
	tickets()
	core.actions.finder({
		name = "ticket",
		find = function(view, range)
			return { { kind = "ticket", label = "A-2", value = "A-2" } }
		end,
	})
	local dir = t:tempdir({ ["notes.txt"] = "hi\n" })
	t:buffer(`see |{dir}/notes.txt`)
	local found: { [string]: core.Object } = {}
	for _, object in objects.at(greed.view()) do
		found[object.kind] = object
	end
	assert(found.ticket and found.ticket.id == "ticket:A-2", "its kind names it")
	local file = assert(found.file, "a file names itself by its path")
	assert(file.id == `file:{dir}/notes.txt`, file.id)
	assert(objects.inspect(file).size == 3, greed.json.encode(objects.inspect(file)))
end)

test("a plugin's kinds go with it", function(t)
	local dir = t:tempdir({
		["plugin.toml"] = 'name = "tracker"\n',
		["init.luau"] = [[
require("@core").objects.kind({ name = "issue", list = function() return {} end })
]],
	})
	greed.plugin.load(dir)
	local function has(): boolean
		for _, kind in objects.kinds() do
			if kind.name == "issue" then
				return true
			end
		end
		return false
	end
	assert(has(), "added")
	greed.plugin.unload("tracker")
	assert(not has(), "gone with it")
end)

test("an action on something in a buffer runs with the cursor on it, from anywhere", function(t)
	local where: number? = nil
	core.actions.finder({
		name = "word-test",
		find = function(view, range)
			local buffer = view:buffer()
			local at = string.find(buffer:text(), "target", 1, true)
			return if at
				then {
					{
						kind = "word-test",
						label = "target",
						value = "target",
						from = at - 1,
						to = at + 5,
					},
				}
				else nil
		end,
	})
	core.actions.action({
		kind = "word-test",
		name = "mark",
		run = function()
			where = greed.view():cursor()
		end,
	})
	t:buffer("|some target here")
	local found = assert(objects.at(greed.view())[1])
	local main = greed.view()
	main:set_cursor(0)
	-- From a float, as the inspector is.
	greed.float(greed.create_buffer("elsewhere", "elsewhere"))
	assert(greed.view() ~= main)
	assert(objects.act(found, "mark"))
	assert(where == 5, `the cursor was at {where}`)
	assert(greed.view() == main, "in the view showing its buffer")
end)

test("an action for every kind comes after a kind's own", function()
	tickets()
	core.actions.action({ kind = "ticket", name = "close", run = function() end })
	core.actions.action({ kind = "*", name = "everywhere", run = function() end })
	local names = {}
	for _, action in objects.actions(ticket("A-1")) do
		table.insert(names, action.name)
	end
	-- Other plugins loaded may add actions for every kind too.
	assert(names[1] == "close" and names[#names] == "everywhere", table.concat(names, ","))
	local buffers = objects.actions(assert(objects.get(`buffer:{greed.view():buffer():id()}`)))
	assert(buffers[#buffers].name == "everywhere")
end)

test("plain gives an object's state as data JSON can carry", function()
	local state = objects.plain({ view = greed.view(), count = 2, nested = { f = print } })
	assert(type(state.view) == "string" and state.count == 2 and type(state.nested.f) == "string")
	assert(greed.json.encode(state) ~= "")
end)

test("a source adds objects of a kind another plugin owns, and says more of its own", function()
	local value = { name = "x" }
	local gadget: core.Object = { kind = "gadget", id = "gadget:x", label = "x", value = value }
	objects.kind({
		name = "gadget",
		doc = "A gadget",
		inspect = function(v)
			return { name = v.name }
		end,
	})
	objects.source({
		name = "shelf",
		list = function(kind)
			return if kind == "gadget" then { gadget } else {}
		end,
		get = function(id)
			return if id == "gadget:x" then gadget else nil
		end,
		inspect = function(v)
			return if v == value then { shelf = 2 } else nil
		end,
		relations = function(v)
			return if v == value then { shelf = {} } else {}
		end,
	})
	local listed = objects.list("gadget")
	assert(#listed == 1 and listed[1].id == "gadget:x", tostring(#listed))
	local found = assert(objects.get("gadget:x"))
	local state = objects.inspect(found)
	assert(state.name == "x" and state.shelf == 2, greed.json.encode(state))
	assert(objects.related(found).shelf ~= nil)
	assert(objects.get("gadget:y") == nil)
end)

test("typed commands find an object argument by its key or its label", function(t)
	objects.kind({
		name = "test-pet",
		list = function()
			return {
				{ kind = "test-pet", id = "test-pet:1", label = "rex", value = 1 },
				{ kind = "test-pet", id = "test-pet:2", label = "tom", value = 2 },
				{ kind = "test-pet", id = "test-pet:3", label = "tom", value = 3 },
			}
		end,
	})
	local got: core.Object? = nil
	greed.command({
		name = "test-pet-feed",
		args = { { name = "pet", type = "object", kind = "test-pet" } },
		run = function(ctx)
			got = ctx.values.pet
			assert(ctx.args[1] ~= nil, "the word is kept in args")
		end,
	})
	t:run("test-pet-feed", { "rex" })
	assert(got and got.id == "test-pet:1", tostring(got and got.id))
	t:run("test-pet-feed", { "3" })
	assert(got and got.value == 3, tostring(got and got.value))
	local function fails(word: string): string
		local ok, err = pcall(function()
			t:run("test-pet-feed", { word })
		end)
		assert(not ok, `{word} should fail`)
		return tostring(err)
	end
	local err = fails("tom")
	assert(
		string.find(err, ':test-pet-feed PET: more than one test-pet is called "tom"', 1, true),
		err
	)
	err = fails("felix")
	assert(string.find(err, ':test-pet-feed PET: no test-pet "felix"', 1, true), err)
	local _, why = objects.find("no-such-kind", "x")
	assert(why == "there's no kind of object called no-such-kind", tostring(why))
end)
