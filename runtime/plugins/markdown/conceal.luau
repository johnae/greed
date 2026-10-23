-- Drawing over Markdown, a few lines at a time: plugins that hide markup
-- (this one, notes) say which buffers they draw and how to draw a range of
-- lines, and after an edit only the lines it changed are drawn again, with
-- any blocks spanning lines it touched or moved (structure.affected).
-- Hidden text that `reveal = "auto"` marks show while typing needs nothing
-- drawn again as the mode changes.

local greed = require("@greed")
local core = require("@core")
local structure = require("./structure")

type Structure = structure.Structure

export type Concealer = {
	--- The namespace of its marks.
	ns: string,
	--- Whether it draws over `buffer` at all.
	wants: (buffer: greed.Buffer) -> boolean,
	--- The marks starting on lines `first` to `last` of `buffer`, whose
	--- structure is `s`.
	draw: (buffer: greed.Buffer, s: Structure, first: number, last: number) -> { greed.Mark },
}

type Entry = { concealer: Concealer, drawn: { [number]: boolean } }

local M = {}

local entries: { Entry } = {}

-- Each buffer's structure when it last changed, to see what an edit moved.
local seen: { [number]: Structure } = {}

-- Draws `entry` over `buffer`: all of it, or lines `first` to `last` if it
-- was drawn before.
local function paint(entry: Entry, buffer: greed.Buffer, first: number?, last: number?)
	local c, id = entry.concealer, buffer:id()
	if not c.wants(buffer) then
		if entry.drawn[id] then
			buffer:decorate(c.ns, {})
			entry.drawn[id] = nil
		end
		return
	end
	local s = structure.of(buffer)
	seen[id] = s
	local partly = first ~= nil and last ~= nil and entry.drawn[id]
	local from, to =
		if partly then first :: number else 0, if partly then last :: number else #s.lines - 1
	-- A drawing that fails (a rule from your config, say) leaves the marks
	-- as they were.
	local ok, marks = pcall(c.draw, buffer, s, from, to)
	if not ok then
		greed.echo(`{c.ns} can't draw: {marks}`)
		return
	elseif partly then
		buffer:decorate(c.ns, marks, { from = s.starts[from + 1], to = s.starts[to + 2] })
	else
		buffer:decorate(c.ns, marks)
		entry.drawn[id] = true
	end
end

--- Draws over the buffers `concealer` wants, now and as they change, until
--- the plugin that called this goes. Returns what draws a buffer (or all of
--- them) again in full, as after an option changed.
function M.add(concealer: Concealer): (buffer: greed.Buffer?) -> ()
	local entry: Entry = { concealer = concealer, drawn = {} }
	local take = core.registry.put(entries, entry)
	local function redraw(buffer: greed.Buffer?)
		if buffer then
			if buffer:valid() then
				paint(entry, buffer)
			end
			return
		end
		for _, open in greed.buffers() do
			paint(entry, open)
		end
	end
	greed.plugin.cleanup(function()
		take()
		for _, open in greed.buffers() do
			if entry.drawn[open:id()] then
				open:decorate(concealer.ns, {})
			end
		end
	end)
	redraw()
	return redraw
end

--- Draws `buffer` again in full, every concealer's marks: for a change that
--- reaches past the lines it touched, like a value others are drawn from.
function M.redraw(buffer: greed.Buffer)
	if buffer:valid() then
		for _, entry in entries do
			paint(entry, buffer)
		end
	end
end

greed.on("buffer.opened", function(event: greed.BufferChanged)
	local buffer = event.buffer
	for _, entry in entries do
		entry.drawn[buffer:id()] = nil
		paint(entry, buffer)
	end
end)

-- A buffer made with its text already in it (a page a plugin shows, a
-- preview) never opens or changes, so it's drawn the first time a view
-- shows it: views report their size when first drawn.
greed.on("view.resized", function(event: greed.ViewResized)
	local buffer = event.view:buffer()
	for _, entry in entries do
		if not entry.drawn[buffer:id()] then
			paint(entry, buffer)
		end
	end
end)

greed.on("buffer.changed", function(event: greed.BufferChanged)
	local buffer = event.buffer
	if not buffer:valid() then
		return
	end
	local id = buffer:id()
	local wanted = false
	for _, entry in entries do
		wanted = wanted or entry.concealer.wants(buffer)
	end
	local first, last = nil :: number?, nil :: number?
	local old, from, to = seen[id], event.from_line, event.to_line
	if wanted and old and from and to then
		local s = structure.update(buffer, old, from, to)
		first, last = structure.affected(old, s, from, to)
	elseif not wanted then
		seen[id] = nil
	end
	for _, entry in entries do
		paint(entry, buffer, first, last)
	end
end)

greed.on("buffer.closed", function(event: greed.BufferClosed)
	seen[event.id] = nil
	structure.forget(event.id)
	for _, entry in entries do
		entry.drawn[event.id] = nil
	end
end)

return M
