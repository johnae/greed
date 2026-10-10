-- Switch to anything open: files, shells, terminals and every other buffer
-- you can show, each saying what it is. `@shell` (or `@sh`) keeps one kind,
-- `@modified` those with unsaved changes and `@shown` those in a pane now;
-- the rest of what's typed is matched against the names. enter shows it
-- here, ctrl-v in a pane beside this one, ctrl-s below it and ctrl-f in a
-- float, and beside the list a preview shows it as it is: a file where its
-- cursor is, a shell or terminal at its end.

local greed = require("@greed")
local core = require("@core")
local picker = require("./picker")
local project = core.project

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

-- The open buffers, the ones you were in last first and the one you're in
-- last of all, so enter goes back to the one before.
local function buffers(): { greed.Buffer }
	local here = greed.view():buffer()
	local out: { greed.Buffer } = {}
	local seen: { [number]: boolean } = { [here:id()] = true }
	local function add(buffer: greed.Buffer)
		if not seen[buffer:id()] and listed(buffer) then
			seen[buffer:id()] = true
			table.insert(out, buffer)
		end
	end
	for _, buffer in core.recent.buffers() do
		add(buffer)
	end
	for _, buffer in greed.buffers() do
		add(buffer)
	end
	if listed(here) then
		table.insert(out, here)
	end
	return out
end

local function label(buffer: greed.Buffer, width: number): string
	local path = buffer:path()
	local name = if path then project.short(path) else buffer:title()
	if core.file.unsaved(buffer) then
		name ..= " [+]"
	end
	local kind = buffer:kind()
	return kind .. string.rep(" ", width - #kind + 2) .. name
end

-- Whether `buffer` has what `word` asks for: a kind starting with it, or
-- "modified" or "shown".
local function tagged(buffer: greed.Buffer, word: string): boolean
	local lower = string.lower(word)
	if string.sub(buffer:kind(), 1, #lower) == lower then
		return true
	elseif string.sub("modified", 1, #lower) == lower then
		return core.file.unsaved(buffer)
	elseif string.sub("shown", 1, #lower) == lower then
		return shown(buffer)
	end
	return false
end

-- A buffer as it is: a file where a view of it has the cursor, anything
-- else (a shell, a terminal) at its end, where what's new is.
local function preview(item: picker.Item): picker.Preview?
	local buffer: greed.Buffer = item.value
	if not buffer:valid() then
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
	if item == nil then
		return
	end
	local buffer: greed.Buffer = item.value
	for _, action in core.actions.for_kind("buffer") do
		if action.name == name then
			action.run({ kind = "buffer", label = buffer:title(), value = buffer })
			return
		end
	end
	greed.echo(`nothing here can {name} a buffer`)
end

greed.command({
	name = "pick-anything",
	doc = "Switch to anything open: a file, a shell, a terminal or another buffer; @kind keeps one kind, ctrl-v, ctrl-s and ctrl-f open it beside, below or in a float",
	run = function()
		local list = buffers()
		local width = 0
		for _, buffer in list do
			width = math.max(width, #buffer:kind())
		end
		local items: { picker.Item } = {}
		for _, buffer in list do
			table.insert(items, { label = label(buffer, width), value = buffer, kind = "buffer" })
		end
		picker.pick("Switch to", items, function(item)
			greed.view():show(item.value)
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
