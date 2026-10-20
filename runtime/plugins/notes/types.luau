-- Kinds of notes, as Obsidian vaults keep them: a template for each kind
-- (`Templates/Meeting Template.md`, or `templates/meeting.md`), its front
-- matter the fields a meeting has and its body what a new one starts as.
-- Each template in the templates folder is a type: a new note can start
-- from one (`notes-new`), and a note can take one's fields
-- (`notes-type`), keeping its own.

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")
local notes = require("./notes")
local index = require("./index")

local M = {}

--- A type: its name ("Meeting", from "Meeting Template") and the note
--- that's its template.
export type Type = { name: string, template: string }

--- The types there are: one for each note in the templates folder, by
--- name.
function M.all(): { Type }
	local folder = `{notes.templates_folder()}/`
	local out: { Type } = {}
	for _, note in index.all() do
		local _, rest = notes.split(note.name)
		if string.sub(rest, 1, #folder) == folder then
			local file = string.sub(rest, #folder + 1)
			local name = string.gsub(file, "%s*[Tt]emplate$", "") :: string
			table.insert(out, { name = if name == "" then file else name, template = note.name })
		end
	end
	table.sort(out, function(a: Type, b: Type): boolean
		return string.lower(a.name) < string.lower(b.name)
	end)
	return out
end

-- `text`'s front matter, the lines between its `---` lines (nil without
-- any), and the byte its body starts at.
local function front_of(text: string): ({ string }?, number)
	local inside, after: any = string.match(text, "^%-%-%-\r?\n(.-\n?)%-%-%-[ \t]*\r?\n?()")
	if inside == nil or after == nil then
		return nil, 1
	end
	local lines = string.split(inside, "\n")
	if lines[#lines] == "" then
		table.remove(lines)
	end
	return lines, after
end

-- Front matter's lines in blocks, one for each key with the lines under
-- it (a list's items).
local function blocks(lines: { string }): { { key: string, lines: { string } } }
	local out: { { key: string, lines: { string } } } = {}
	for _, line in lines do
		local key = string.match(line, "^([%w_%-]+):")
		if key then
			table.insert(out, { key = string.lower(key), lines = { line } })
		elseif #out > 0 then
			table.insert(out[#out].lines, line)
		end
	end
	return out
end

--- Makes note `name` from type `kind`'s template (or empty, without
--- one), its `{{date}}`, `{{title}}` and the like filled in, and opens it.
--- A note that's there already is opened as it is.
function M.new(name: string, kind: Type?)
	local path = notes.path(name)
	if greed.fs.stat(path) == nil then
		local template = if kind then notes.read(kind.template) else nil
		core.file.write(path, if template then notes.filled(template, name) else `# {name}\n\n`)
	end
	core.file.open(path)
end

--- Gives note `name` type `kind`'s fields: those in its template's front
--- matter that the note doesn't have yet are added, with what the
--- template has for them; what the note says stays.
function M.apply(name: string, kind: Type)
	local template = notes.read(kind.template)
	local wanted = if template then (front_of(notes.filled(template, name))) else nil
	if wanted == nil then
		return
	end
	local path = notes.path(name)
	local text = notes.read(name) or ""
	local own, body = front_of(text)
	local have: { [string]: boolean } = {}
	local lines: { string } = table.clone(own or {})
	for _, block in blocks(own or {}) do
		have[block.key] = true
	end
	for _, block in blocks(wanted) do
		if not have[block.key] then
			table.move(block.lines, 1, #block.lines, #lines + 1, lines)
		end
	end
	local front = `---\n{table.concat(lines, "\n")}\n---\n`
	core.file.write(path, front, { from = 0, to = body - 1 })
end

-- Picks a type, then does `with` it (nil for none, when `none` says what
-- having none is called).
local function pick(title: string, none: string?, with: (kind: Type?) -> ())
	local items: { picker.Item } = {}
	if none then
		table.insert(items, { label = none, value = false })
	end
	for _, kind in M.all() do
		table.insert(items, { label = kind.name, detail = kind.template, value = kind })
	end
	if #items == 0 then
		greed.echo(`there are no templates in {notes.templates_folder()}/`)
		return
	end
	picker.pick(title, items, function(item)
		with(if item.value then item.value :: Type else nil)
	end)
end

greed.command({
	name = "notes-new",
	doc = "Make a note from a template: pick one, then name the note",
	run = function()
		pick("New note from", "No template", function(kind)
			greed.spawn(function()
				local name = core.prompt.ask(if kind then `New {kind.name}` else "New note")
				if name and string.match(name, "%S") then
					M.new(core.text.trim(name), kind)
				end
			end)
		end)
	end,
})

greed.command({
	name = "notes-type",
	doc = "Give this note a template's fields, those it doesn't have yet",
	run = function(ctx)
		local path = ctx.buffer:path()
		if path == nil or not notes.is_note(ctx.buffer) then
			greed.echo("this isn't a note")
			return
		end
		pick("Give this note the fields of", nil, function(kind)
			if kind then
				M.apply(notes.name(path), kind)
			end
		end)
	end,
})

greed.keymap.bind({ layer = "leader" }, { ["n n"] = "notes-new", ["n y"] = "notes-type" })

return M
