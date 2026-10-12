-- Objects: the things in a running Greed, each with a kind and an id
-- ("buffer:12", "tab:3", "pod:prod-eu/payments/api-7d9f"), its state to
-- inspect, the objects it relates to, and the actions its kind has
-- (actions.luau). The inspector (`space h i`) and agents see them all the
-- same way.
--
-- A kind says how to list its objects, when the editor can (buffers,
-- tabs), how to find one again by the key in its id, and how to inspect and
-- relate them; all of that is optional. What finders find under the cursor
-- is an object too once it has an id: its kind's `key` gives one, or its
-- value when that's a string or number, like a file's path.
--
--     local objects = require("@core").objects
--     objects.kind({
--         name = "ticket",
--         get = function(key) return { kind = "ticket", id = "ticket:" .. key, label = key, value = key } end,
--         inspect = function(key) return { status = lookup(key).status } end,
--     })
--
-- A plugin's kinds go when it does.

local greed = require("@greed")
local registry = require("./registry")
local actions = require("./actions")

local M = {}

--- An object: a thing to act on (actions.Target) with an id, `kind:key`.
--- One that is somewhere in a buffer says where (`buffer`, `from`, `to`),
--- so actions that work on what's under the cursor can be run on it from
--- anywhere.
export type Object = {
	kind: string,
	id: string,
	label: string,
	value: any,
	buffer: greed.Buffer?,
	from: number?,
	to: number?,
}

--- What a kind of object can say, all of it optional but its name.
export type Kind = {
	name: string,
	doc: string?,
	--- Every object of this kind there is now, when the editor can know.
	list: (() -> { Object })?,
	--- The object whose id is `kind:key`, if it's still there.
	get: ((key: string) -> Object?)?,
	--- The key in the id of the thing with `value`, as a finder found it.
	key: ((value: any) -> string?)?,
	--- Its state, as a table to show or send as JSON.
	inspect: ((value: any) -> { [string]: any })?,
	--- The objects it relates to, by name: a buffer's views, a tab's panes.
	relations: ((value: any) -> { [string]: { Object } })?,
	--- Its state as it is now, asked of something outside the editor (a
	--- program: `kubectl get pod`), the way `inspect` gives it; nil once it's
	--- gone. It may wait. Watching uses it; kinds without it are found again
	--- by id and inspected.
	fresh: ((value: any) -> { [string]: any }?)?,
}

--- Somewhere objects of any kind show up besides their kind's own list,
--- like the rows of a shell block: its objects of a kind, the one with an
--- id, and for a value that came from it, more to inspect (a row's cells)
--- and more it relates to (the block). Each says nothing (nil, {}) about
--- what isn't its own.
export type Source = {
	name: string,
	list: (kind: string) -> { Object },
	get: (id: string) -> Object?,
	inspect: ((value: any) -> { [string]: any }?)?,
	relations: ((value: any) -> { [string]: { Object } })?,
}

local kinds: { Kind } = {}
local sources: { Source } = {}

--- Adds kind `kind.name`, or replaces it, until the plugin that added it
--- goes. The plugin that knows the things says what they are; the places
--- that show them are sources (`source`).
function M.kind(kind: Kind)
	greed.plugin.tie(registry.put(kinds, kind, function(other: Kind)
		return other.name == kind.name
	end))
end

--- Adds a source of objects, or replaces one by the same name, until the
--- plugin that added it goes.
function M.source(source: Source)
	greed.plugin.tie(registry.put(sources, source, function(other: Source)
		return other.name == source.name
	end))
end

-- What `f(...)` gives, or nil when it fails.
local function tried<T>(f: (...any) -> T, ...: any): T?
	local ok, found = pcall(f, ...)
	return if ok then found else nil
end

--- Every kind there is, in the order they were added.
function M.kinds(): { Kind }
	return table.clone(kinds)
end

local function kind_named(name: string): Kind?
	for _, kind in kinds do
		if kind.name == name then
			return kind
		end
	end
	return nil
end

--- The id of the thing of `kind` with `value`: by its kind's `key`, or the
--- value itself when it's a string or number. Nil when it can't be named.
function M.id_of(kind: string, value: any): string?
	local k = kind_named(kind)
	local key: string? = nil
	if k and k.key then
		key = k.key(value)
	elseif type(value) == "string" or type(value) == "number" then
		key = tostring(value)
	end
	return if key then `{kind}:{key}` else nil
end

--- `target` as an object, or nil when its kind can't name it.
function M.from(target: actions.Target): Object?
	local id = target.id or M.id_of(target.kind, target.value)
	if id == nil then
		return nil
	end
	return {
		kind = target.kind,
		id = id,
		label = target.label,
		value = target.value,
		buffer = target.buffer,
		from = target.from,
		to = target.to,
	}
end

--- `object` as a thing to act on, for actions and finders.
function M.target(object: Object): actions.Target
	return {
		kind = object.kind,
		label = object.label,
		value = object.value,
		id = object.id,
		buffer = object.buffer,
		from = object.from,
		to = object.to,
	}
end

--- Every object of `kind`, or of every kind that can be listed: the kind's
--- own list, then what the sources show of it, each id once. A list that
--- fails lists nothing.
function M.list(kind: string?): { Object }
	local out: { Object } = {}
	local seen: { [string]: boolean } = {}
	local function take(found: { Object }?)
		if found == nil then
			return
		end
		for _, object in found do
			if not seen[object.id] then
				seen[object.id] = true
				table.insert(out, object)
			end
		end
	end
	for _, k in kinds do
		if kind == nil or k.name == kind then
			if k.list then
				take(tried(k.list))
			end
			for _, source in sources do
				take(tried(source.list, k.name))
			end
		end
	end
	return out
end

--- The object with `id` as a source shows it, like the newest shell row
--- that is it; nil when none does. For a kind's `get` that would rather
--- give what's shown, with its cells, than ask a program.
function M.shown(id: string): Object?
	for _, source in sources do
		local found = tried(source.get, id)
		if found then
			return found
		end
	end
	return nil
end

--- The object with `id`, if it's there: by its kind's `get`, else by a
--- source's, else from its kind's list.
function M.get(id: string): Object?
	local name, key = string.match(id, "^([^:]+):(.*)$")
	local kind = if name then kind_named(name) else nil
	if kind == nil or key == nil then
		return nil
	end
	if kind.get then
		local found = tried(kind.get, key)
		if found then
			return found
		end
	end
	local shown = M.shown(id)
	if shown then
		return shown
	end
	for _, object in M.list(kind.name) do
		if object.id == id then
			return object
		end
	end
	return nil
end

--- `object`'s state: its kind's say, or else its value, with what the
--- source it came from adds.
function M.inspect(object: Object): { [string]: any }
	local kind = kind_named(object.kind)
	local state: { [string]: any }
	local value = object.value
	if kind and kind.inspect then
		local ok, said = pcall(kind.inspect, value)
		state = if ok and said then said else { error = tostring(said) }
	elseif type(value) == "table" then
		state = table.clone(value)
	else
		state = { value = value }
	end
	for _, source in sources do
		local more = if source.inspect then tried(source.inspect, value) else nil
		if more then
			for key, item in more do
				state[key] = item
			end
		end
	end
	return state
end

--- `value` as plain data JSON can carry, for agents and models: the
--- editor's handles and functions as text, tables some levels deep.
function M.plain(value: any, depth: number?): any
	local kind = type(value)
	if kind == "string" or kind == "number" or kind == "boolean" or value == nil then
		return value
	elseif kind ~= "table" then
		return tostring(value)
	end
	local left = (depth or 3) - 1
	if left < 0 then
		return "…"
	end
	local out = {}
	for key, item in value do
		out[tostring(key)] = M.plain(item, left)
	end
	return out
end

--- The objects `object` relates to, by name: by its kind, and by the
--- source it came from.
function M.related(object: Object): { [string]: { Object } }
	local out: { [string]: { Object } } = {}
	local kind = kind_named(object.kind)
	local all: { (value: any) -> { [string]: { Object } } } = {}
	if kind and kind.relations then
		table.insert(all, kind.relations)
	end
	for _, source in sources do
		if source.relations then
			table.insert(all, source.relations)
		end
	end
	for _, relations in all do
		local found = tried(relations, object.value)
		if found then
			for name, related in found do
				out[name] = out[name] or related
			end
		end
	end
	return out
end

--- The actions `object`'s kind has.
function M.actions(object: Object): { actions.Action }
	return actions.for_kind(object.kind, object :: any)
end

-- Puts the cursor on `object` when it's somewhere in a buffer, in a view
-- showing that buffer (the focused one shows it if none does), for the
-- many actions that work on what's under the cursor.
local function go_to(object: Object)
	local buffer, from = object.buffer, object.from
	if buffer == nil or from == nil or not buffer:valid() then
		return
	end
	local view = greed.view()
	if view:buffer() ~= buffer then
		local showing = buffer:views()[1]
		if showing then
			showing:focus()
			view = showing
		else
			view:show(buffer)
		end
	end
	view:set_cursor(from)
end

--- `object`'s state as it is now: asked again by its kind's `fresh`, or
--- found again by id and inspected. Nil once it's gone; nil and why when
--- it can't tell now (a program failing). It may wait.
function M.fresh(object: Object): ({ [string]: any }?, string?)
	local kind = kind_named(object.kind)
	if kind and kind.fresh then
		local ok, state = pcall(kind.fresh, object.value)
		if not ok then
			return nil, tostring(state)
		end
		return state, nil
	end
	local now = M.get(object.id)
	return if now then M.inspect(now) else nil, nil
end

-- `object`'s action `name`, if its kind has one.
local function action_named(object: Object, name: string): actions.Action?
	for _, action in M.actions(object) do
		if action.name == name then
			return action
		end
	end
	return nil
end

--- Runs `object`'s action `name`, with the cursor on it first when it's
--- somewhere in a buffer; false when its kind has no action by that name.
--- `by` says who for the history, as `actions.run` takes it.
function M.act(object: Object, name: string, by: string?): boolean
	local action = action_named(object, name)
	if action == nil then
		return false
	end
	go_to(object)
	actions.run(action, M.target(object), by)
	return true
end

--- Runs the action `name` on every one of `list` for `by`, as `act` does
--- on one, asking once for all those its action destroys or stops something
--- on. Gives back the ids it ran on, those it didn't (not chosen when asked)
--- and those whose kind has no action by that name.
function M.act_all(
	list: { Object },
	name: string,
	by: string?
): ({ string }, { string }, { string })
	local ran, skipped, missing = {}, {}, {}
	-- Those of one kind share an action, and are asked about together.
	local groups: { { action: actions.Action, targets: { actions.Target } } } = {}
	for _, object in list do
		local found = action_named(object, name)
		if found == nil then
			table.insert(missing, object.id)
		else
			local target = M.target(object)
			local joined = false
			for _, g in groups do
				if g.action == found then
					table.insert(g.targets, target)
					joined = true
					break
				end
			end
			if not joined then
				table.insert(groups, { action = found, targets = { target } })
			end
		end
	end
	for _, group in groups do
		local chosen = actions.run_all(group.action, group.targets, by, function(target)
			go_to(assert(M.from(target)))
		end)
		for _, target in group.targets do
			table.insert(if table.find(chosen, target) then ran else skipped, assert(target.id))
		end
	end
	return ran, skipped, missing
end

--- What's at the primary selection in `view` (actions.at) that can be
--- named, as objects, each saying it's there.
function M.at(view: greed.View): { Object }
	local out: { Object } = {}
	for _, target in actions.at(view) do
		local object = M.from(target)
		if object then
			if object.from then
				object.buffer = object.buffer or view:buffer()
			end
			table.insert(out, object)
		end
	end
	return out
end

require("./objects_editor")(M)

return M
