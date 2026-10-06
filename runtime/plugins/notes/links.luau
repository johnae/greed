-- Links between notes: [[note]] and [[note|what to show]]. In notes the
-- brackets are hidden (except while typing on their line), `g d` follows a
-- link, and the notes linking to a note are listed at its end.

local greed = require("@greed")
local core = require("@core")
local notes = require("./notes")

type Link = { from: number, to: number, target: string, text_from: number, text_to: number }

local M = {}

--- The links in `buffer`: where each is, where the part to show is, and
--- the note it points at.
function M.links(buffer: greed.Buffer): { Link }
	local text = buffer:text()
	local out: { Link } = {}
	local at = 1
	while true do
		local found_from, found_to, found = string.find(text, "%[%[([^%]\n]+)%]%]", at)
		if found_from == nil or found_to == nil or found == nil then
			break
		end
		local from: number, to: number, inside: string = found_from, found_to, found
		local target, shown = string.match(inside, "^([^|]+)|(.+)$")
		local text_from = from + 1
		if target and shown then
			text_from += #target + 1
		else
			target = inside
		end
		table.insert(out, {
			from = from - 1,
			to = to,
			target = string.match(target :: string, "^%s*(.-)%s*$") :: string,
			text_from = text_from,
			text_to = to - 2,
		})
		at = to + 1
	end
	return out
end

local function escape(text: string): string
	return (string.gsub(text, "[%^%$%(%)%.%[%]%*%+%-%?{}|\\]", "\\%0"))
end

--- The names of the notes that link to note `name`: by its full name from
--- anywhere, or by its name in its place from a note there.
function M.backlinks(name: string): { string }
	local function linking(target: string): { notes.Found }
		return notes.grep(`\\[\\[\\s*{escape(target)}\\s*(\\|[^\\]]*)?\\]\\]`) or {}
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

local function mark(buffer: greed.Buffer)
	local marks: { greed.Mark } = {}
	local conceal = greed.option.get("notes-conceal") == true
	local shows: "line" | "cursor" | "never" = core.reveal()
	for _, link in M.links(buffer) do
		table.insert(marks, { from = link.text_from, to = link.text_to, style = "markup.link" })
		if conceal then
			table.insert(marks, {
				from = link.from,
				to = link.text_from,
				style = "markup.link",
				conceal = true,
				reveal = shows,
			})
			table.insert(marks, {
				from = link.text_to,
				to = link.to,
				style = "markup.link",
				conceal = true,
				reveal = shows,
			})
		end
	end
	local backlinks = shown_backlinks[buffer:id()]
	if backlinks and #backlinks > 0 then
		local lines = { "", "Linked from:" }
		for _, name in backlinks do
			table.insert(lines, `  [[{name}]]`)
		end
		local last = buffer:line_count() - 1
		table.insert(marks, {
			from = buffer:line_start(last),
			to = buffer:len(),
			style = "comment",
			lines = lines,
		})
	end
	buffer:decorate("notes", marks)
end

local function refresh(buffer: greed.Buffer)
	if not notes.is_note(buffer) then
		return
	end
	shown_backlinks[buffer:id()] = M.backlinks(notes.name(buffer:path() :: string))
	mark(buffer)
end

-- Typing shows link brackets as written, so notes are drawn again as modes
-- change.
greed.on("mode.changed", function()
	for _, buffer in greed.buffers() do
		if notes.is_note(buffer) then
			mark(buffer)
		end
	end
end)

greed.on("buffer.opened", function(event: greed.BufferChanged)
	refresh(event.buffer)
end)

greed.on("buffer.saved", function(event: greed.BufferChanged)
	refresh(event.buffer)
end)

greed.on("buffer.changed", function(event: greed.BufferChanged)
	if notes.is_note(event.buffer) then
		pcall(mark, event.buffer)
	end
end)

greed.on("option.changed", function(event)
	if event.name == "notes-conceal" or event.name == "notes-everywhere" then
		for _, buffer in greed.buffers() do
			if notes.is_note(buffer) then
				mark(buffer)
			else
				buffer:decorate("notes", {})
			end
		end
	end
end)

greed.command({
	name = "notes-follow",
	doc = "Open the note the [[link]] under the cursor points at, or go to the definition",
	run = function(ctx)
		local selection = ctx.view:selection()
		local head = selection.ranges[selection.primary].head
		for _, link in M.links(ctx.buffer) do
			if link.from <= head and head < link.to then
				local path = ctx.buffer:path()
				local from = if path and notes.is_note(ctx.buffer) then notes.name(path) else nil
				greed.open(notes.path(notes.resolve(link.target, from)))
				return
			end
		end
		greed.run("goto-definition")
	end,
})

return M
