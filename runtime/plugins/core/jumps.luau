-- The jumplist, back and forward like a browser's: commands that jump
-- (searches, g g, G, going to a definition) and anything that shows another
-- buffer in a view (opening a file from the shell, a picker, a plugin)
-- leave the place they started in that view's list. ctrl-o goes back
-- through it, ctrl-i (or tab) forward again. Places follow edits, and a
-- place keeps where its view was scrolled. Other plugins add their own
-- jumping commands with `require("@core").jumps.add(name)`.

local greed = require("@greed")
local file = require("./file")
local registry = require("./registry")

type Place = {
	buffer: number,
	path: string?,
	-- Where the cursor was, kept up to date from `anchor` while it lasts.
	pos: number,
	anchor: greed.Anchor?,
	-- How many lines below the top of the view the cursor was.
	offset: number,
}

-- Where a view is, as last seen.
type Seen = { buffer: number, pos: number, top: number }

type History = {
	places: { Place },
	-- Where in `places` the view is; one past the end when not going
	-- through it.
	index: number,
}

-- More than this and the oldest place goes.
local LIMIT = 100

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

local histories: { [number]: History } = {}
local seen: { [number]: Seen } = {}

local function history(view: greed.View): History
	local id = view:id()
	local found = histories[id]
	if found == nil then
		found = { places = {}, index = 1 }
		histories[id] = found
	end
	return found
end

local function find_buffer(id: number): greed.Buffer?
	for _, buffer in greed.buffers() do
		if buffer:id() == id then
			return buffer
		end
	end
	return nil
end

local function where(place: Place): number
	local pos = if place.anchor then place.anchor:pos() else nil
	if pos then
		place.pos = pos
	end
	return place.pos
end

local function forget(place: Place)
	if place.anchor then
		place.anchor:forget()
		place.anchor = nil
	end
end

local function look(view: greed.View): Seen
	return { buffer = view:buffer():id(), pos = view:cursor(), top = view:scroll() }
end

local function place_of(at: Seen): Place?
	local buffer = find_buffer(at.buffer)
	if buffer == nil then
		return nil
	end
	local pos = math.min(at.pos, buffer:len())
	return {
		buffer = at.buffer,
		path = buffer:path(),
		pos = pos,
		anchor = buffer:track(pos),
		offset = math.max(buffer:line_of(pos) - at.top, 0),
	}
end

local function same(a: Place?, b: Place?): boolean
	return a ~= nil and b ~= nil and a.buffer == b.buffer and where(a) == where(b)
end

local function push(view: greed.View, at: Seen)
	local place = place_of(at)
	if place == nil then
		return
	end
	local h = history(view)
	-- Jumping from somewhere in the middle of the list forgets what came after.
	for i = #h.places, h.index, -1 do
		forget(table.remove(h.places, i) :: Place)
	end
	if same(h.places[#h.places], place) then
		forget(place)
	else
		table.insert(h.places, place)
		if #h.places > LIMIT then
			forget(table.remove(h.places, 1) :: Place)
		end
	end
	h.index = #h.places + 1
end

-- Shows `place` in `view`, opening its file again if its buffer was
-- closed. Returns whether it could.
local function go(view: greed.View, place: Place): boolean
	local found = find_buffer(place.buffer)
	if found then
		if view:buffer():id() ~= found:id() then
			view:show(found)
		end
	else
		local path = place.path
		if path == nil then
			return false
		end
		file.open(path)
		place.buffer = view:buffer():id()
	end
	local buffer = view:buffer()
	local pos = math.min(where(place), buffer:len())
	view:set_cursor(pos)
	view:set_scroll(math.max(buffer:line_of(pos) - place.offset, 0))
	-- Going somewhere isn't a jump to remember.
	seen[view:id()] = look(view)
	return true
end

-- Notes where `view` is now. It showing another buffer than when last
-- seen, whatever did it, is a jump from there.
local function note(view: greed.View): Seen
	local now = look(view)
	local before = seen[view:id()]
	if before and before.buffer ~= now.buffer then
		push(view, before)
	end
	seen[view:id()] = now
	return now
end

greed.on("command.run", function(event: greed.CommandRun)
	local view = greed.view()
	local now = note(view)
	if JUMPS[event.name] then
		push(view, now)
	end
end)

greed.on("selection.changed", function(event: greed.SelectionChanged)
	note(event.view)
end)

greed.on("view.scrolled", function(event: greed.ViewScrolled)
	local before = seen[event.view:id()]
	if before and before.buffer == event.view:buffer():id() then
		before.top = event.line
	end
end)

greed.on("view.closed", function(event: greed.ViewClosed)
	local h = histories[event.view]
	if h then
		for _, place in h.places do
			forget(place)
		end
	end
	histories[event.view] = nil
	seen[event.view] = nil
end)

greed.command({
	name = "jump-back",
	doc = "Go back to where the last jump started, in this view",
	run = function()
		local view = greed.view()
		local h = history(view)
		if h.index > #h.places then
			push(view, look(view))
			h.index = #h.places
		end
		while h.index > 1 do
			h.index -= 1
			if go(view, h.places[h.index]) then
				return
			end
		end
	end,
})

greed.command({
	name = "jump-forward",
	doc = "Go forward again after jumping back, in this view",
	run = function()
		local view = greed.view()
		local h = history(view)
		while h.index < #h.places do
			h.index += 1
			if go(view, h.places[h.index]) then
				return
			end
		end
	end,
})

local M = {}

--- Makes command `name` leave its starting place in the jumplist.
function M.add(name: string)
	greed.plugin.tie(registry.set(JUMPS, name, true))
end

--- The places in the focused view's jumplist, newest first: each one's
--- buffer id, file path if it has one, and position now.
function M.list(): { { buffer: number, path: string?, pos: number } }
	local out = {}
	local places = history(greed.view()).places
	for i = #places, 1, -1 do
		local place = places[i]
		table.insert(out, { buffer = place.buffer, path = place.path, pos = where(place) })
	end
	return out
end

--- Goes to `place`, one of `list()`'s, in the focused view; false if its
--- buffer is gone and it had no file.
function M.go(place: { buffer: number, path: string?, pos: number }): boolean
	return go(
		greed.view(),
		{ buffer = place.buffer, path = place.path, pos = place.pos, offset = 0 }
	)
end

return M
