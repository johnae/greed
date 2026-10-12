-- For plugins keeping registries other plugins add to: putting an entry in
-- and getting back what takes it out again, but only while it's still the
-- one there. Hand that to `greed.plugin.tie`, and what a plugin added goes
-- when it does:
--
--     function M.add(name, thing)
--         greed.plugin.tie(core.registry.set(things, name, thing))
--     end

local greed = require("@greed")

local M = {}

--- Sets `map[key]` to `value`. What it returns takes it out again, unless
--- something else was set there since.
function M.set<K, V>(map: { [K]: V }, key: K, value: V): () -> ()
	map[key] = value
	return function()
		if map[key] == value then
			map[key] = nil
		end
	end
end

--- Adds `entry` to the end of `list`, or in place of the first entry `same`
--- matches. What it returns takes it out again, if it's still there.
function M.put<T>(list: { T }, entry: T, same: ((other: T) -> boolean)?): () -> ()
	local at = nil
	if same then
		for i, other in list do
			if same(other) then
				at = i
				break
			end
		end
	end
	if at then
		list[at] = entry
	else
		table.insert(list, entry)
	end
	return M.remover(list, entry)
end

--- Calls each listener in `listeners`, a list or a map, with `...`. One
--- that fails has its error said and the rest are still called, so a broken
--- plugin can't stop what comes after; one taken out meanwhile doesn't make
--- another miss its turn.
function M.tell<K, A...>(listeners: { [K]: (A...) -> () }, ...: A...)
	for _, listener in table.clone(listeners) do
		xpcall(listener, function(err)
			greed.echo(tostring(err))
		end, ...)
	end
end

--- What takes `entry` out of `list` again, if it's still there, for an
--- entry put in some other way than `put`.
function M.remover<T>(list: { T }, entry: T): () -> ()
	return function()
		local i = table.find(list, entry)
		if i then
			table.remove(list, i)
		end
	end
end

return M
