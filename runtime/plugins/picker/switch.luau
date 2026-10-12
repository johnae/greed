-- Switch to anything: files, shells, terminals and every other buffer you
-- can show, and what other plugins add (`picker.add_places`), like your
-- sessions and the agents in them on every machine, each saying what it
-- is. `@shell` (or `@sh`) keeps one kind, `@modified` those with unsaved
-- changes, `@shown` those in a pane now, and a word a plugin tags its
-- places with (like `@waiting` or a machine's name) those; the rest of
-- what's typed is matched against the names. enter goes there; for a
-- buffer ctrl-v opens it in a pane beside this one, ctrl-s below it and
-- ctrl-f in a float, and beside the list a preview shows it as it is: a
-- file where its cursor is, a shell or terminal at its end.

local greed = require("@greed")
local core = require("@core")
local picker = require("./picker")
local project = core.project

-- One thing in the list: a buffer, or a place a plugin added.
type Entry = { buffer: greed.Buffer?, place: picker.Place? }

-- Whether `buffer` is shown in a pane, rather than only in floats or not
-- at all.
local function shown(buffer: greed.Buffer): boolean
	for _, view in buffer:views() do
		if view:is_pane() then
			return true
		end
	end
	return false
end

-- Whether `buffer` is one to switch to: a file, one kept open (a shell, a
-- terminal), or one in a pane. Floats' own buffers (pickers, menus) aren't.
local function listed(buffer: greed.Buffer): boolean
	return buffer:path() ~= nil or buffer:kept() or shown(buffer)
end

-- What to list: the open buffers, the ones you were in last first, then
-- what plugins add, and the buffer you're in last of all, so enter goes
-- back to the one before.
local function entries(): { Entry }
	local here = greed.view():buffer()
	local out: { Entry } = {}
	local seen: { [number]: boolean } = { [here:id()] = true }
	local function add(buffer: greed.Buffer)
		if not seen[buffer:id()] and listed(buffer) then
			seen[buffer:id()] = true
			table.insert(out, { buffer = buffer })
		end
	end
	for _, buffer in core.recent.buffers() do
		add(buffer)
	end
	for _, buffer in greed.buffers() do
		add(buffer)
	end
	for _, place in picker.places() do
		table.insert(out, { place = place })
	end
	if listed(here) then
		table.insert(out, { buffer = here })
	end
	return out
end

local function kind_of(entry: Entry): string
	return if entry.place then entry.place.kind else (entry.buffer :: greed.Buffer):kind()
end

local function label(entry: Entry, width: number): string
	local kind = kind_of(entry)
	local name
	if entry.place then
		name = entry.place.label
	else
		local buffer = entry.buffer :: greed.Buffer
		local path = buffer:path()
		name = if path then project.short(path) else buffer:title()
		if core.file.unsaved(buffer) then
			name ..= " [+]"
		end
	end
	return kind .. string.rep(" ", width - #kind + 2) .. name
end

-- Whether `entry` has what `word` asks for: a kind starting with it,
-- "modified" or "shown" for a buffer, or a place's tag starting with it.
local function tagged(entry: Entry, word: string): boolean
	local lower = string.lower(word)
	local function starts(text: string): boolean
		return string.sub(string.lower(text), 1, #lower) == lower
	end
	if starts(kind_of(entry)) then
		return true
	end
	local place, buffer = entry.place, entry.buffer
	if place then
		local tags: { string } = place.tags or {}
		for _, tag in tags do
			if starts(tag) then
				return true
			end
		end
		return false
	elseif buffer and starts("modified") then
		return core.file.unsaved(buffer)
	elseif buffer and starts("shown") then
		return shown(buffer)
	end
	return false
end

-- A buffer as it is: a file where a view of it has the cursor, anything
-- else (a shell, a terminal) at its end, where what's new is.
local function preview(item: picker.Item): picker.Preview?
	local entry: Entry = item.value
	local buffer = entry.buffer
	if buffer == nil or not buffer:valid() then
		return nil
	end
	local view = buffer:views()[1]
	local line = if buffer:path() == nil
		then buffer:line_count() - 1
		elseif view then buffer:line_of(view:cursor())
		else 0
	return { text = buffer:text(), language = buffer:language(), line = line }
end

-- Runs the buffer action `name` (panes adds "float", "split beside" and
-- "split below") on the buffer `item` is.
local function act(name: string, item: picker.Item?)
	local entry: Entry? = item and item.value
	local buffer = entry and entry.buffer
	if buffer == nil then
		return
	end
	for _, action in core.actions.for_kind("buffer") do
		if action.name == name then
			core.actions.run(action, { kind = "buffer", label = buffer:title(), value = buffer })
			return
		end
	end
	greed.echo(`nothing here can {name} a buffer`)
end

greed.command({
	name = "pick-anything",
	doc = "Switch to anything: a file, a shell, a terminal or another buffer, and what plugins add, like your sessions and agents; @kind keeps one kind, ctrl-v, ctrl-s and ctrl-f open a buffer beside, below or in a float",
	run = function()
		local list = entries()
		local width = 0
		for _, entry in list do
			width = math.max(width, #kind_of(entry))
		end
		local items: { picker.Item } = {}
		for _, entry in list do
			table.insert(items, {
				label = label(entry, width),
				value = entry,
				kind = if entry.buffer then "buffer" else nil,
			})
		end
		picker.pick("Switch to", items, function(item)
			local entry: Entry = item.value
			if entry.place then
				entry.place.go()
			elseif entry.buffer then
				greed.view():show(entry.buffer)
			end
		end, {
			preview = preview,
			tags = function(item, word)
				return tagged(item.value, word)
			end,
			keys = {
				["ctrl-f"] = function(_items, current)
					act("float", current)
				end,
				["ctrl-v"] = function(_items, current)
					act("split beside", current)
				end,
				["ctrl-s"] = function(_items, current)
					act("split below", current)
				end,
			},
		})
	end,
})

return {}
