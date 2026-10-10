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
