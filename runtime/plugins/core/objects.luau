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

local kinds: { Kind } = {}

--- Adds kind `kind.name`, or replaces it, until the plugin that added it
--- goes.
function M.kind(kind: Kind)
	greed.plugin.tie(registry.put(kinds, kind, function(other: Kind)
		return other.name == kind.name
	end))
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

--- Every object of `kind`, or of every kind that can be listed. A kind
--- whose list fails lists nothing.
function M.list(kind: string?): { Object }
	local out: { Object } = {}
	for _, k in kinds do
		local list = k.list
		if list and (kind == nil or k.name == kind) then
			local ok, found = pcall(list)
			if ok and found then
				for _, object in found do
					table.insert(out, object)
				end
			end
		end
	end
	return out
end

--- The object with `id`, if it's there.
function M.get(id: string): Object?
	local name, key = string.match(id, "^([^:]+):(.*)$")
	local kind = if name then kind_named(name) else nil
	if kind == nil or key == nil then
		return nil
	end
	if kind.get then
		local ok, found = pcall(kind.get, key)
		return if ok then found else nil
	end
	for _, object in M.list(kind.name) do
		if object.id == id then
			return object
		end
	end
	return nil
end

--- `object`'s state: its kind's say, or else its value.
function M.inspect(object: Object): { [string]: any }
	local kind = kind_named(object.kind)
	if kind and kind.inspect then
		local ok, state = pcall(kind.inspect, object.value)
		return if ok and state then state else { error = tostring(state) }
	end
	local value = object.value
	if type(value) == "table" then
		return table.clone(value)
	end
	return { value = value }
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

--- The objects `object` relates to, by name.
function M.related(object: Object): { [string]: { Object } }
	local kind = kind_named(object.kind)
	if kind and kind.relations then
		local ok, related = pcall(kind.relations, object.value)
		if ok and related then
			return related
		end
	end
	return {}
end

--- The actions `object`'s kind has.
function M.actions(object: Object): { actions.Action }
	return actions.for_kind(object.kind)
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

--- Runs `object`'s action `name`, with the cursor on it first when it's
--- somewhere in a buffer; false when its kind has no action by that name.
--- `by` says who for the history, as `actions.run` takes it.
function M.act(object: Object, name: string, by: string?): boolean
	for _, action in M.actions(object) do
		if action.name == name then
			go_to(object)
			actions.run(action, M.target(object), by)
			return true
		end
	end
	return false
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
