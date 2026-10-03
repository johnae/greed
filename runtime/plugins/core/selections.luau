-- Selection history: the selections each view had before each command,
-- so selection-undo goes back to an earlier one and selection-redo forward
-- again, like Kakoune's ctrl-h and ctrl-k and VS Code's ctrl-u. Edits
-- don't count; `u` undoes those.
--
-- Each kept selection is a set of marks in its buffer, so it moves with
-- edits made since.

local greed = require("@greed")

-- At most this many selections are kept for each view.
local KEPT = 50

-- A kept selection: its buffer and primary range; its ranges are marks
-- styled "<id> <range> <reversed>" in the view's namespace.
type Entry = { id: number, buffer: number, primary: number, count: number }

type History = {
	entries: { Entry },
	-- The entry shown now while going back and forth, or nil when the
	-- selection is the view's own.
	at: number?,
}

local histories: { [number]: History } = {}
local next_id = 0

-- Commands that don't add to the history: these two, and typing, whose
-- cursors would fill it one character at a time.
local IGNORED: { [string]: boolean } = {}
for _, name in
	{
		"selection-undo",
		"selection-redo",
		"insert-char",
		"insert-newline",
		"insert-tab",
		"delete-back",
		"delete-forward",
		"type-char",
		"type-newline",
		"type-tab",
		"erase-back",
		"erase-forward",
		"vim-replace-typed",
	}
do
	IGNORED[name] = true
end

local function namespace(view: greed.View): string
	return `selection-history-{view:id()}`
end

local function history_of(view: greed.View): History
	local found = histories[view:id()]
	if found then
		return found
	end
	local fresh: History = { entries = {}, at = nil }
	histories[view:id()] = fresh
	return fresh
end

-- The ranges of `entry`, where its marks are now.
local function ranges_of(view: greed.View, entry: Entry): { greed.Range }
	local ranges: { greed.Range } = {}
	for _, mark in view:buffer():decorations(namespace(view)) do
		local id, index, reversed = string.match(mark.style, "^(%d+) (%d+) (%d)$")
		if tonumber(id) == entry.id then
			local i = tonumber(index) :: number
			ranges[i] = if reversed == "1"
				then { anchor = mark.to, head = mark.from }
				else { anchor = mark.from, head = mark.to }
		end
	end
	return ranges
end

local function same(a: greed.Selection, b: greed.Selection): boolean
	if #a.ranges ~= #b.ranges or a.primary ~= b.primary then
		return false
	end
	for i, range in a.ranges do
		if range.anchor ~= b.ranges[i].anchor or range.head ~= b.ranges[i].head then
			return false
		end
	end
	return true
end

-- Keeps only `entries`' marks in the view's namespace.
local function keep_marks(view: greed.View, entries: { Entry })
	local wanted: { [number]: boolean } = {}
	for _, entry in entries do
		wanted[entry.id] = true
	end
	local marks = {}
	for _, mark in view:buffer():decorations(namespace(view)) do
		if wanted[tonumber(string.match(mark.style, "^%d+")) :: number] then
			table.insert(marks, mark)
		end
	end
	view:buffer():decorate(namespace(view), marks)
end

-- Adds the view's selection to its history, unless it's the last one kept.
local function push(view: greed.View, history: History)
	local buffer = view:buffer()
	local selection = view:selection()
	local last = history.entries[#history.entries]
	if last and last.buffer == buffer:id() then
		local kept = { ranges = ranges_of(view, last), primary = last.primary }
		if #kept.ranges == last.count and same(kept, selection) then
			return
		end
	end
	next_id += 1
	local marks = buffer:decorations(namespace(view))
	for i, range in selection.ranges do
		table.insert(marks, {
			from = math.min(range.anchor, range.head),
			to = math.max(range.anchor, range.head),
			style = `{next_id} {i} {if range.anchor > range.head then 1 else 0}`,
		})
	end
	buffer:decorate(namespace(view), marks)
	table.insert(
		history.entries,
		{
			id = next_id,
			buffer = buffer:id(),
			primary = selection.primary,
			count = #selection.ranges,
		}
	)
	if #history.entries > KEPT then
		table.remove(history.entries, 1)
		keep_marks(view, history.entries)
	end
end

-- Before each command, the selection it starts from is kept. A command
-- after going back drops what was ahead.
greed.on("command.run", function(event: greed.CommandRun)
	if IGNORED[event.name] then
		return
	end
	local view = greed.view()
	local history = history_of(view)
	if history.at then
		for _ = history.at + 1, #history.entries do
			table.remove(history.entries)
		end
		history.at = nil
		keep_marks(view, history.entries)
	end
	push(view, history)
end)

greed.on("view.closed", function(event: greed.ViewClosed)
	histories[event.view] = nil
end)

-- Shows entry `at`, if it's for the buffer the view shows.
local function show(view: greed.View, history: History, at: number): boolean
	local entry = history.entries[at]
	if entry == nil or entry.buffer ~= view:buffer():id() then
		return false
	end
	local ranges = ranges_of(view, entry)
	if #ranges ~= entry.count then
		return false
	end
	history.at = at
	view:set_selection({ ranges = ranges, primary = entry.primary })
	return true
end

greed.command({
	name = "selection-undo",
	doc = "Go back to the selection before the last command",
	run = function(ctx)
		local history = history_of(ctx.view)
		if history.at == nil then
			-- The selection now, to come back to.
			push(ctx.view, history)
			history.at = #history.entries
		end
		local at = history.at :: number
		if not show(ctx.view, history, at - 1) then
			greed.echo("no earlier selection")
		end
	end,
})

greed.command({
	name = "selection-redo",
	doc = "Go forward to the selection selection-undo went back from",
	run = function(ctx)
		local history = history_of(ctx.view)
		if history.at == nil or not show(ctx.view, history, history.at + 1) then
			greed.echo("no later selection")
		end
	end,
})

return {}
