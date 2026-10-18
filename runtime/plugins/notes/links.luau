-- Links between notes: [[note]] and [[note|what to show]]. In notes the
-- brackets are hidden (except while typing on their line), `g d` follows a
-- link, and the notes linking to a note are listed at its end. Links in
-- code blocks are code.

local core = require("@core")
local greed = require("@greed")
local markdown = require("@markdown")
local notes = require("./notes")
local syntax = require("./syntax")
local index = require("./index")

--- A link in a buffer: where it is (bytes, end exclusive), where the part
--- shown in its place is, and the note it names (as written, without a
--- `#heading` or `#^block`).
type Link = { from: number, to: number, target: string, text_from: number, text_to: number }

local M = {}

-- The links on lines `first` to `last` of a note whose structure is `s`.
local function links_in(s: markdown.Structure, first: number, last: number): { Link }
	local out: { Link } = {}
	for n = first, last do
		local text = s.lines[n + 1]
		if s.code_at[n] or not string.find(text, "[[", 1, true) then
			continue
		end
		local base = s.starts[n + 1] - 1
		for _, link in syntax.links(text) do
			table.insert(out, {
				from = base + link.from,
				to = base + link.to,
				target = link.target,
				text_from = base + link.shown_from,
				text_to = base + link.shown_to,
			})
		end
	end
	return out
end

--- The links in `buffer`: where each is, where the part to show is, and
--- the note it points at.
function M.links(buffer: greed.Buffer): { Link }
	local s = markdown.structure(buffer)
	return links_in(s, 0, #s.lines - 1)
end

--- The names of the notes that link to note `name`: by its full name from
--- anywhere, or by its name in its place from a note there. Waits for the
--- index (see index.luau) the first time.
function M.backlinks(name: string): { string }
	index.ensure()
	return index.backlinks(name)
end

-- The backlinks shown under each note, by buffer id, worked out when it's
-- opened or saved.
local shown_backlinks: { [number]: { string } } = {}

local redraw = markdown.conceal({
	ns = "notes",
	wants = notes.is_note,
	draw = function(
		buffer: greed.Buffer,
		s: markdown.Structure,
		first: number,
		last: number
	): { greed.Mark }
		local marks: { greed.Mark } = {}
		local conceal = greed.option.get("notes-conceal") == true
		for _, link in links_in(s, first, last) do
			table.insert(marks, { from = link.text_from, to = link.text_to, style = "markup.link" })
			if conceal then
				table.insert(marks, {
					from = link.from,
					to = link.text_from,
					style = "markup.link",
					conceal = true,
					reveal = "auto" :: "auto",
				})
				table.insert(marks, {
					from = link.text_to,
					to = link.to,
					style = "markup.link",
					conceal = true,
					reveal = "auto" :: "auto",
				})
			end
		end
		local backlinks = shown_backlinks[buffer:id()]
		local count = #s.lines
		if last == count - 1 and backlinks and #backlinks > 0 then
			local lines: { greed.MarkLine } = { "", "Linked from:" }
			for _, name in backlinks do
				table.insert(lines, `  [[{name}]]`)
			end
			table.insert(marks, {
				from = s.starts[count],
				to = buffer:len(),
				style = "comment",
				lines = lines,
			})
		end
		return marks
	end,
})

local function refresh(buffer: greed.Buffer)
	if not notes.is_note(buffer) then
		return
	end
	shown_backlinks[buffer:id()] = M.backlinks(notes.name(buffer:path() :: string))
	redraw(buffer)
end

greed.on("buffer.opened", function(event: greed.BufferChanged)
	refresh(event.buffer)
end)

greed.on("buffer.saved", function(event: greed.BufferChanged)
	refresh(event.buffer)
end)

-- A note linking here added or taken away, here or on disk, shows at once.
index.on_changed(function()
	for _, buffer in greed.buffers() do
		local shown = shown_backlinks[buffer:id()]
		if shown and buffer:valid() and notes.is_note(buffer) then
			local now = index.backlinks(notes.name(buffer:path() :: string))
			if table.concat(now, "\n") ~= table.concat(shown, "\n") then
				shown_backlinks[buffer:id()] = now
				redraw(buffer)
			end
		end
	end
end)

greed.on("option.changed", function(event)
	if event.name == "notes-conceal" or event.name == "notes-everywhere" then
		redraw()
	end
end)

--- The file a link to `target` in the file at `path` opens: a note, or
--- for Markdown outside every place, the file beside it, unless the link
--- names a place.
function M.target_path(target: string, path: string?): string
	local from: string? = nil
	if path then
		if notes.place_of(path) then
			from = notes.name(path)
		elseif not notes.named_place(target) then
			local file = if string.match(target, "%.md$") then target else target .. ".md"
			return core.project.resolve(file, string.match(path, "^(.*)/"))
		end
	end
	return notes.path(notes.resolve(target, from))
end

-- g d on a [[link]] opens the note it points at, making it if it's new.
core.lookup.add("definition", function(ctx)
	local head = ctx.view:cursor()
	for _, link in M.links(ctx.buffer) do
		if link.from <= head and head < link.to then
			core.file.open(M.target_path(link.target, ctx.buffer:path()))
			return true
		end
	end
	return false
end)

return M
