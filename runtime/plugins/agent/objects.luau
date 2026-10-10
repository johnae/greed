-- The objects of the running editor for agents (core.objects): `objects`
-- finds them, `inspect` gives one's state, the objects it relates to and its
-- actions, and `act` runs one of those actions. They're always offered:
-- with them an agent reaches anything a plugin makes an object, with no
-- tool of its own. `act` does more than read, so agents in Greed ask first,
-- and what an action guards (proposals are yours to decide, a delete asks
-- you) it guards here too.

local greed = require("@greed")
local core = require("@core")
local agent = require("./registry")

local object = agent.schema.object
local objects = core.objects

-- How many objects a list gives by default, and at most.
local LIST = 100
local MOST = 500
-- How many related objects `inspect` gives under each name.
local RELATED = 20

local function brief(found: core.Object): { [string]: any }
	return { id = found.id, kind = found.kind, label = found.label }
end

local function find(id: any): core.Object
	if type(id) ~= "string" then
		error("give the object's id, like buffer:12; objects lists them", 0)
	end
	return objects.get(id) or error(`there's no object {id} now; objects lists them`, 0)
end

-- `list` cut to `limit`, keeping those whose label or id has `filter`, with
-- the total kept.
local function chosen(list: { core.Object }, filter: string?, limit: number): { [string]: any }
	local out = {}
	local total = 0
	for _, found in list do
		local text = string.lower(found.label .. " " .. found.id)
		if filter == nil or string.find(text, string.lower(filter), 1, true) then
			total += 1
			if #out < limit then
				table.insert(out, brief(found))
			end
		end
	end
	return { objects = greed.json.array(out), total = total }
end

-- The objects `found` relates to, by relation, each chosen as above.
local function related(found: core.Object, filter: string?, limit: number): { [string]: any }
	local out = {}
	for name, list in objects.related(found) do
		out[name] = chosen(list, filter, limit)
	end
	return out
end

agent.tool({
	name = "objects",
	description = "The objects of the running editor: buffers, views, tabs, terminals, shell "
		.. "blocks, language servers, proposals, plugins and whatever plugins add. With no "
		.. "arguments, the kinds there are and how many of each. With `kind`, its objects "
		.. "(id, kind, label); with `related_to` (an id), the objects it relates to, by "
		.. "relation (a buffer's views, a tab's panes). `filter` keeps those whose label or "
		.. "id holds it. inspect gives one object's state and actions",
	input = object({
		kind = { type = "string", description = "e.g. buffer, terminal, shell-block" },
		related_to = { type = "string", description = "An object's id, e.g. tab:3" },
		filter = { type = "string", description = "Text the label or id holds" },
		limit = { type = "number", description = `How many at most (default {LIST})` },
	}),
	run = function(args)
		local limit = math.clamp(tonumber(args.limit) or LIST, 1, MOST)
		local filter = if type(args.filter) == "string" then args.filter else nil
		if args.related_to ~= nil then
			return related(find(args.related_to), filter, limit)
		elseif type(args.kind) == "string" then
			return chosen(objects.list(args.kind), filter, limit)
		end
		local kinds = {}
		for _, kind in objects.kinds() do
			table.insert(kinds, {
				kind = kind.name,
				doc = kind.doc,
				count = if kind.list then #objects.list(kind.name) else nil,
			})
		end
		return {
			kinds = greed.json.array(kinds),
			note = "editor: relates to every kind that can be listed; things under the "
				.. "cursor, like a file path, are objects too",
		}
	end,
})

agent.tool({
	name = "inspect",
	description = "One object of the running editor, by id (from objects, or like buffer:12): "
		.. "its state, the objects it relates to (by relation, a few of each with the total), "
		.. "the actions it has, which act runs, and what was done to it (the last few: which "
		.. "action, by the user or an agent, when, and what it made, like a shell block)",
	input = object({
		id = { type = "string", description = "e.g. buffer:12, shell-block:7.2, editor:" },
	}, { "id" }),
	run = function(args)
		local found = find(args.id)
		local actions = {}
		for _, action in objects.actions(found) do
			table.insert(actions, { name = action.name, doc = action.doc })
		end
		local done = {}
		for i, entry in core.actions.history(found.id) do
			if i > RELATED then
				break
			end
			table.insert(done, {
				action = entry.action,
				by = entry.by,
				seconds_ago = (greed.now() - entry.at) // 1000,
				made = entry.made,
			})
		end
		return {
			id = found.id,
			kind = found.kind,
			label = found.label,
			state = objects.plain(objects.inspect(found)),
			related = related(found, nil, RELATED),
			actions = greed.json.array(actions),
			done = greed.json.array(done),
		}
	end,
})

agent.tool({
	name = "act",
	kind = "execute",
	description = "Run one of an object's actions (inspect lists them), on that object, as "
		.. "the user would from the inspector: show a buffer, run a shell block again, "
		.. "stop a terminal's program. Some ask the user first, and deciding on proposed "
		.. "changes is only theirs. Gives back the object's state afterwards, if it's "
		.. "still there",
	input = object({
		id = { type = "string", description = "The object's id" },
		action = { type = "string", description = "The action's name, as inspect gives it" },
	}, { "id", "action" }),
	run = function(args)
		local found = find(args.id)
		if type(args.action) ~= "string" then
			error("give the action's name; inspect lists them", 0)
		end
		if not objects.act(found, args.action, "agent") then
			local names = {}
			for _, action in objects.actions(found) do
				table.insert(names, action.name)
			end
			local have = if #names > 0 then table.concat(names, ", ") else "none"
			error(`{found.id} has no action {args.action}; it has {have}`, 0)
		end
		local after = objects.get(found.id)
		return {
			ran = args.action,
			on = found.id,
			state = if after then objects.plain(objects.inspect(after)) else nil,
			gone = after == nil,
		}
	end,
})

return {}
