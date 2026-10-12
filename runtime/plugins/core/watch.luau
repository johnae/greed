-- Watching objects: `watch` on anything (`space .` on a pod, a file, a
-- process) looks at it again every `watch-interval` seconds and, when its
-- state changed, sends a notification saying how ("STATUS Running →
-- CrashLoopBackOff"), on the status line and to your desktop. Once it's
-- gone it says so and stops. `watch` again stops it, and `:watches` (the
-- picker plugin) lists what's watched, to stop one.

local greed = require("@greed")
local actions = require("./actions")
local objects = require("./objects")

greed.option.define({
	name = "watch-interval",
	doc = "Seconds between looks at each watched object",
	default = 10,
})

-- What a watch saw last, and what wakes it to look again.
type Watch = { object: objects.Object, state: { [string]: string }, wake: greed.Signal? }

-- What's watched, by object id.
local watched: { [string]: Watch } = {}

-- `state` as flat text by name: its plain fields, and a table row's cells
-- (a `row` field) by their column.
local function flat(state: { [string]: any }): { [string]: string }
	local out: { [string]: string } = {}
	for name, value in state do
		if name == "row" and type(value) == "table" then
			for column, cell in value do
				out[tostring(column)] = tostring(cell)
			end
		elseif type(value) ~= "table" and type(value) ~= "userdata" then
			out[name] = tostring(value)
		end
	end
	return out
end

-- How `now` differs from `before`, each change in a few words, by name.
local function changes(before: { [string]: string }, now: { [string]: string }): { string }
	local names: { string } = {}
	for name in now do
		if before[name] ~= now[name] then
			table.insert(names, name)
		end
	end
	for name in before do
		if now[name] == nil then
			table.insert(names, name)
		end
	end
	table.sort(names)
	local out = {}
	for _, name in names do
		table.insert(out, `{name} {before[name] or "none"} → {now[name] or "none"}`)
	end
	return out
end

local function tell(object: objects.Object, said: string)
	greed.echo(`{object.label}: {said}`)
	greed.client.notify(object.label, said)
end

-- Looks at `w` again every interval while it's watched, and at once when
-- its owner says it changed (`objects.changed`).
local function follow(w: Watch)
	local id = w.object.id
	while watched[id] == w do
		local wake = greed.signal()
		w.wake = wake
		greed.spawn(function()
			greed.sleep((tonumber(greed.option.get("watch-interval")) or 10) * 1000)
			wake:send(true)
		end)
		wake:wait()
		if watched[id] ~= w then
			return
		end
		local state, why = objects.fresh(w.object)
		if watched[id] ~= w then
			return
		elseif state == nil and why == nil then
			watched[id] = nil
			tell(w.object, "gone; stopped watching it")
			return
		elseif state then
			local now = flat(state)
			local changed = changes(w.state, now)
			w.state = now
			if #changed > 0 then
				tell(w.object, table.concat(changed, "; "))
			end
		end
	end
end

-- An object its owner says changed is looked at again now.
objects.on_changed(function(id)
	local w = watched[id]
	if w and w.wake then
		w.wake:send(true)
	end
end)

local M = {}

--- Starts watching `object`, or stops when it's watched already. Says
--- which, and returns whether it's watched now.
function M.toggle(object: objects.Object): boolean
	local was = watched[object.id]
	if was then
		watched[object.id] = nil
		-- Its loop ends now rather than at its next look.
		if was.wake then
			was.wake:send(false)
		end
		greed.echo(`stopped watching {object.label}`)
		return false
	end
	local state, why = objects.fresh(object)
	if state == nil then
		greed.echo(if why then `can't watch {object.label}: {why}` else `{object.label} is gone`)
		return false
	end
	local w: Watch = { object = object, state = flat(state) }
	watched[object.id] = w
	greed.spawn(follow, w)
	greed.echo(`watching {object.label}: a notification when it changes`)
	return true
end

--- The objects watched, by label.
function M.list(): { objects.Object }
	local out: { objects.Object } = {}
	for _, w in watched do
		table.insert(out, w.object)
	end
	table.sort(out, function(a: objects.Object, b: objects.Object): boolean
		return a.label < b.label
	end)
	return out
end

actions.action({
	kind = "*",
	name = "watch",
	doc = "A notification each time it changes, saying how; again to stop",
	run = function(target)
		local object = objects.from(target)
		if object == nil then
			greed.echo(`a {target.kind} can't be watched: it has no id`)
			return
		end
		M.toggle(object)
	end,
})

return M
