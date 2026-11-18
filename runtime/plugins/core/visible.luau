-- Marks drawn on the lines in sight: for plugins whose marks are cheap to
-- work out a line at a time but would be too many over a whole big file,
-- like indent guides or color swatches. Each says which buffers it draws
-- on and how to draw a run of lines; its marks are drawn again as views
-- scroll, resize or change buffer, or the text changes (and with `cursor`,
-- as cursors move), for the lines each view shows and a few either side.
-- Nothing is drawn again while the text and the lines in sight are as they
-- were, so moving about costs little.

local greed = require("@greed")
local registry = require("./registry")

export type Painter = {
	--- The namespace of its marks.
	ns: string,
	--- Whether it draws on `buffer` at all.
	wants: (buffer: greed.Buffer) -> boolean,
	--- The marks for lines `first` to `last` (0-based, inclusive) of
	--- `buffer`.
	draw: (buffer: greed.Buffer, first: number, last: number) -> { greed.Mark },
	--- Whether its marks depend on the lines cursors are on, so they're
	--- drawn again as those change.
	cursor: boolean?,
	--- Whether a line's marks start on it and depend on its text alone, so
	--- an edit within lines redraws only those.
	lines: boolean?,
}

local M = {}

local painters: { Painter } = {}

-- What each painter drew last, by buffer id: the text's version, and the
-- line count with the lines in sight (and the cursors' lines, for one that
-- minds them).
type Drawn = { version: number, place: string }
local drawn_as: { [Painter]: { [number]: Drawn } } = {}

-- Lines drawn past the top and the bottom of what a view shows, so a
-- little scrolling finds them there.
local MARGIN = 10

-- The runs of `buffer`'s lines its views show, with a few either side,
-- merged where they meet.
local function in_sight(buffer: greed.Buffer): { { number } }
	local last = buffer:line_count() - 1
	local runs: { { number } } = {}
	for _, view in buffer:views() do
		local area = view:area()
		local height = if area then area.height else 50
		local top = view:scroll()
		table.insert(runs, { math.max(0, top - MARGIN), math.min(last, top + height + MARGIN) })
	end
	table.sort(runs, function(a: { number }, b: { number }): boolean
		return a[1] < b[1]
	end)
	local merged: { { number } } = {}
	for _, run in runs do
		local before = merged[#merged]
		if before and run[1] <= before[2] + 1 then
			before[2] = math.max(before[2], run[2])
		else
			table.insert(merged, { run[1], run[2] })
		end
	end
	return merged
end

-- Where `painter` would draw on `buffer` now, as a string to compare.
local function place(painter: Painter, buffer: greed.Buffer, runs: { { number } }): string
	local parts = { tostring(buffer:line_count()) }
	for _, run in runs do
		table.insert(parts, `{run[1]}-{run[2]}`)
	end
	if painter.cursor then
		for _, view in buffer:views() do
			for _, range in view:selection().ranges do
				table.insert(parts, tostring(buffer:line_of(range.head)))
			end
		end
	end
	return table.concat(parts, " ")
end

-- Draws lines `from` to `to` again, for a painter whose lines stand alone,
-- when they're in sight: true if that was enough.
local function repaint(
	painter: Painter,
	buffer: greed.Buffer,
	runs: { { number } },
	from: number,
	to: number
): boolean
	for _, run in runs do
		if from >= run[1] and to <= run[2] then
			local ok, drawn = pcall(painter.draw, buffer, from, to)
			if not ok then
				return false
			end
			local after = if to + 1 < buffer:line_count() then buffer:line_start(to + 1) else nil
			buffer:decorate(painter.ns, drawn, { from = buffer:line_start(from), to = after })
			return true
		end
	end
	return false
end

-- Draws `painter`'s marks on what `buffer` shows, or takes them away when
-- it doesn't want the buffer; nothing when that's what it drew last, unless
-- `again`. Lines `changed` are those an edit changed since, as
-- "buffer.changed" says.
local function paint(painter: Painter, buffer: greed.Buffer, again: boolean?, changed: { number }?)
	if not buffer:valid() then
		return
	end
	local seen = drawn_as[painter]
	-- A buffer nothing shows and that has nothing drawn needs nothing, like
	-- one opened in the background.
	if #buffer:views() == 0 and not (seen and seen[buffer:id()]) then
		return
	end
	if not painter.wants(buffer) then
		if seen and seen[buffer:id()] then
			buffer:decorate(painter.ns, {})
			seen[buffer:id()] = nil
		end
		return
	end
	local runs = in_sight(buffer)
	local now: Drawn = { version = buffer:version(), place = place(painter, buffer, runs) }
	if seen == nil then
		seen = {}
		drawn_as[painter] = seen
	end
	local before = seen[buffer:id()]
	seen[buffer:id()] = now
	if before and before.place == now.place and not again then
		if before.version == now.version then
			return
		end
		-- Lines kept their places: only those changed need drawing.
		if painter.lines and changed and repaint(painter, buffer, runs, changed[1], changed[2]) then
			return
		end
	end
	local marks: { greed.Mark } = {}
	for _, run in runs do
		local ok, drawn = pcall(painter.draw, buffer, run[1], run[2])
		if not ok then
			greed.echo(`{painter.ns} can't draw: {drawn}`)
			return
		end
		table.move(drawn, 1, #drawn, #marks + 1, marks)
	end
	buffer:decorate(painter.ns, marks)
end

--- Draws `painter`'s marks on the lines in sight, now and as they change,
--- until the plugin that called this goes. Returns what draws a buffer (or
--- every one) again, as after an option changed.
function M.add(painter: Painter): (buffer: greed.Buffer?) -> ()
	local take = registry.put(painters, painter)
	local function redraw(buffer: greed.Buffer?)
		if buffer then
			paint(painter, buffer, true)
			return
		end
		for _, open in greed.buffers() do
			paint(painter, open, true)
		end
	end
	greed.plugin.cleanup(function()
		take()
		drawn_as[painter] = nil
		for _, open in greed.buffers() do
			if open:valid() then
				open:decorate(painter.ns, {})
			end
		end
	end)
	redraw()
	return redraw
end

-- Draws every painter on `buffer`, with the lines `changed` if an edit
-- said which.
local function paint_all(buffer: greed.Buffer, changed: { number }?)
	for _, painter in table.clone(painters) do
		paint(painter, buffer, nil, changed)
	end
end

greed.on("buffer.changed", function(event: greed.BufferChanged)
	local from, to = event.from_line, event.to_line
	paint_all(event.buffer, if from and to then { from, to } else nil)
end)

greed.on("buffer.closed", function(event: greed.BufferClosed)
	for _, seen in drawn_as do
		seen[event.id] = nil
	end
end)

greed.on("view.scrolled", function(event: greed.ViewScrolled)
	paint_all(event.view:buffer())
end)

greed.on("view.resized", function(event: greed.ViewResized)
	paint_all(event.view:buffer())
end)

-- Told once a frame, when cursors move or a view shows another buffer: a
-- buffer just opened is drawn here, once, rather than as it opens, so
-- opening many at once costs nothing until one shows.
greed.on("selection.changed", function(event: greed.SelectionChanged)
	if event.view:valid() then
		paint_all(event.view:buffer())
	end
end)

return M
