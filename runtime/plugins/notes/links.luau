-- Links between notes: [[note]] and [[note|what to show]]. In notes the
-- brackets are hidden (except on the cursor's line), `g d` follows a link,
-- and the notes linking to a note are listed at its end.

local kern = require("@kern")
local notes = require("./notes")

type Link = { from: number, to: number, target: string, text_from: number, text_to: number }

local M = {}

--- The links in `buffer`: where each is, where the part to show is, and
--- the note it points at.
function M.links(buffer: kern.Buffer): { Link }
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

--- The names of the notes that link to note `name`.
function M.backlinks(name: string): { string }
	local found = kern.fs.grep(`\\[\\[\\s*{escape(name)}\\s*(\\|[^\\]]*)?\\]\\]`, notes.folder())
		or {}
	local seen, out = {}, {}
	for _, line in found do
		local from = notes.name(`{notes.folder()}/{line.path}`)
		if from ~= name and not seen[from] then
			seen[from] = true
			table.insert(out, from)
		end
	end
	table.sort(out)
	return out
end

-- The backlinks shown under each note, by buffer id, worked out when it's
-- opened or saved.
local shown_backlinks: { [number]: { string } } = {}

local function mark(buffer: kern.Buffer)
	local marks: { kern.Mark } = {}
	local conceal = kern.option.get("notes-conceal") == true
	for _, link in M.links(buffer) do
		table.insert(marks, { from = link.text_from, to = link.text_to, style = "markup.link" })
		if conceal then
			table.insert(
				marks,
				{ from = link.from, to = link.text_from, style = "markup.link", conceal = true }
			)
			table.insert(
				marks,
				{ from = link.text_to, to = link.to, style = "markup.link", conceal = true }
			)
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

local function refresh(buffer: kern.Buffer)
	if not notes.is_note(buffer) then
		return
	end
	shown_backlinks[buffer:id()] = M.backlinks(notes.name(buffer:path() :: string))
	mark(buffer)
end

kern.on("buffer.opened", function(event: kern.BufferChanged)
	refresh(event.buffer)
end)

kern.on("buffer.saved", function(event: kern.BufferChanged)
	refresh(event.buffer)
end)

kern.on("buffer.changed", function(event: kern.BufferChanged)
	if notes.is_note(event.buffer) then
		pcall(mark, event.buffer)
	end
end)

kern.on("option.changed", function(event)
	if event.name == "notes-conceal" or event.name == "notes-everywhere" then
		for _, buffer in kern.buffers() do
			if notes.is_note(buffer) then
				mark(buffer)
			else
				buffer:decorate("notes", {})
			end
		end
	end
end)

kern.command({
	name = "notes-follow",
	doc = "Open the note the [[link]] under the cursor points at, or go to the definition",
	run = function(ctx)
		local selection = ctx.view:selection()
		local head = selection.ranges[selection.primary].head
		for _, link in M.links(ctx.buffer) do
			if link.from <= head and head < link.to then
				kern.open(notes.path(link.target))
				return
			end
		end
		kern.run("goto-definition")
	end,
})

return M
