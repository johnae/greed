-- Links between notes: [[note]] and [[note|what to show]]. In notes the
-- brackets are hidden (except while typing on their line), `g d` follows a
-- link, and the notes linking to a note are listed at its end. Links in
-- code blocks are code.

local core = require("@core")
local greed = require("@greed")
local markdown = require("@markdown")
local notes = require("./notes")

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
		local base = s.starts[n + 1]
		for from, inside, to in string.gmatch(text, "()%[%[([^%]]+)%]%]()") do
			local link_from = base + (from :: number) - 1
			local link_to = base + (to :: number) - 1
			local target, shown = string.match(inside :: string, "^([^|]+)|(.+)$")
			local text_from = link_from + 2
			if target and shown then
				text_from += #target + 1
			else
				target = inside
			end
			table.insert(out, {
				from = link_from,
				to = link_to,
				target = string.match(target :: string, "^%s*(.-)%s*$") :: string,
				text_from = text_from,
				text_to = link_to - 2,
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

local function escape(text: string): string
	return (string.gsub(text, "[%^%$%(%)%.%[%]%*%+%-%?{}|\\]", "\\%0"))
end

--- The names of the notes that link to note `name`: by its full name from
--- anywhere, or by its name in its place from a note there.
function M.backlinks(name: string): { string }
	local function linking(target: string): { notes.Found }
		return notes.grep_text(`\\[\\[\\s*{escape(target)}\\s*(\\|[^\\]]*)?\\]\\]`) or {}
	end
	local place, rest = notes.split(name)
	local found = linking(name)
	if rest ~= name then
		for _, line in linking(rest) do
			if (notes.split(line.note)).name == place.name then
				table.insert(found, line)
			end
		end
	end
	local seen, out = {}, {}
	for _, line in found do
		if line.note ~= name and not seen[line.note] then
			seen[line.note] = true
			table.insert(out, line.note)
		end
	end
	table.sort(out)
	return out
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
