-- What needs you: an agent waiting for an answer, a command that finished
-- out of sight. The plugin that knows the thing says so and takes it off
-- again; floats get a colored dot, and the session's status lists them,
-- oldest first.

local greed = require("@greed")
local registry = require("./registry")

local M = {}

--- Something that needs you. `key` is the thing's object id, like
--- "terminal:12"; `buffer` is where to look at it, when it has one; `since`
--- is when it started needing you, in seconds since the epoch.
export type Need = {
	key: string,
	label: string,
	reason: string,
	since: number,
	buffer: greed.Buffer?,
}

local needs: { [string]: Need } = {}
local watchers: { () -> () } = {}

local function tell()
	for _, watch in watchers do
		watch()
	end
end

--- Says the thing `key` needs you, why (`reason`) and where to look
--- (`buffer`), or with nil that it no longer does. Saying it again with the
--- same reason keeps when it started.
function M.set(key: string, need: { label: string, reason: string, buffer: greed.Buffer? }?)
	local had = needs[key]
	if need == nil then
		if had then
			needs[key] = nil
			tell()
		end
		return
	end
	if
		had
		and had.reason == need.reason
		and had.label == need.label
		and had.buffer == need.buffer
	then
		return
	end
	needs[key] = {
		key = key,
		label = need.label,
		reason = need.reason,
		since = if had and had.reason == need.reason then had.since else os.time(),
		buffer = need.buffer,
	}
	tell()
end

--- Everything that needs you now, oldest first.
function M.list(): { Need }
	local list = {}
	for _, need in needs do
		table.insert(list, need)
	end
	table.sort(list, function(a: Need, b: Need)
		return if a.since == b.since then a.key < b.key else a.since < b.since
	end)
	return list
end

--- What needs you that's shown in `buffer`, if anything.
function M.of(buffer: greed.Buffer): Need?
	local id = buffer:id()
	for _, need in needs do
		if need.buffer and need.buffer:id() == id then
			return need
		end
	end
	return nil
end

--- Calls `watch` whenever something starts or stops needing you, until the
--- plugin that asked goes.
function M.on_change(watch: () -> ())
	greed.plugin.tie(registry.put(watchers, watch))
end

-- A closed buffer's needs go with it.
greed.on("buffer.closed", function(event: greed.BufferClosed)
	local gone = false
	for key, need in needs do
		if need.buffer and need.buffer:id() == event.id then
			needs[key] = nil
			gone = true
		end
	end
	if gone then
		tell()
	end
end)

return M
