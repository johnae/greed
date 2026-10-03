-- The jumplist: commands that jump (searches, g g, G, going to a definition,
-- opening a file) leave the place they started in a list, and ctrl-o goes
-- back through it, ctrl-i (or tab) forward again. Other plugins add their
-- own jumping commands with `require("@core").jumps.add(name)`.

local kern = require("@kern")

type Place = { buffer: number, path: string?, pos: number }

local JUMPS: { [string]: boolean } = {}
for _, name in
	{
		"goto-start",
		"goto-line",
		"goto-end",
		"search",
		"search-back",
		"search-next",
		"search-prev",
		"match-bracket",
		"jump-to-word",
		"open",
		"pick-file",
		"pick-buffer",
		"goto-definition",
		"goto-references",
		"pick-problem",
		"next-diagnostic",
		"prev-diagnostic",
		"pick-diagnostic",
		"grep-open",
		"search-project",
		"pick-outline",
		"next-change",
		"prev-change",
		"tree-open",
		"multibuffer-open",
		"proposal-next",
		"proposal-prev",
	}
do
	JUMPS[name] = true
end

local list: { Place } = {}
-- Where in `list` we are; one past the end when not going through it.
local index = 1

local function here(): Place?
	local view = kern.view()
	local buffer = view:buffer()
	if buffer:kind() ~= "file" then
		return nil
	end
	local selection = view:selection()
	return {
		buffer = buffer:id(),
		path = buffer:path(),
		pos = selection.ranges[selection.primary].head,
	}
end

local function same(a: Place?, b: Place?): boolean
	return a ~= nil and b ~= nil and a.buffer == b.buffer and a.pos == b.pos
end

local function push(place: Place)
	-- Jumping from somewhere in the middle of the list forgets what came after.
	for i = #list, index, -1 do
		table.remove(list, i)
	end
	if not same(list[#list], place) then
		table.insert(list, place)
	end
	index = #list + 1
end

-- Shows `place`, opening its file again if its buffer was closed. Returns
-- whether it could.
local function go(place: Place): boolean
	local shown = false
	for _, buffer in kern.buffers() do
		if buffer:id() == place.buffer then
			kern.view():show(buffer)
			shown = true
			break
		end
	end
	if not shown then
		if place.path == nil then
			return false
		end
		kern.open(place.path)
	end
	local pos = math.min(place.pos, kern.view():buffer():len())
	kern.view():set_selection({ ranges = { { anchor = pos, head = pos } }, primary = 1 })
	return true
end

kern.on("command.run", function(event: kern.CommandRun)
	if JUMPS[event.name] then
		local place = here()
		if place then
			push(place)
		end
	end
end)

kern.command({
	name = "jump-back",
	doc = "Go back to where the last jump started",
	run = function()
		if index > #list then
			local place = here()
			if place and not same(list[#list], place) then
				table.insert(list, place)
			end
			index = #list
		end
		while index > 1 do
			index -= 1
			if go(list[index]) then
				return
			end
		end
	end,
})

kern.command({
	name = "jump-forward",
	doc = "Go forward again after jumping back",
	run = function()
		while index < #list do
			index += 1
			if go(list[index]) then
				return
			end
		end
	end,
})

local M = {}

--- Makes command `name` leave its starting place in the jumplist.
function M.add(name: string)
	JUMPS[name] = true
end

--- The places in the jumplist, newest first: each one's buffer id, file
--- path if it has one, and position.
function M.list(): { Place }
	local out = {}
	for i = #list, 1, -1 do
		table.insert(out, table.clone(list[i]))
	end
	return out
end

--- Goes to `place`, one of `list()`'s; false if its buffer is gone and it
--- had no file.
M.go = go

return M
