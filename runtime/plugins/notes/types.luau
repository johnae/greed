-- Kinds of notes, as Obsidian vaults keep them: a template for each kind
-- (`Templates/Meeting Template.md`, or `templates/meeting.md`), its front
-- matter the fields a meeting has and its body what a new one starts as.
-- Each template in the templates folder is a type: a new note can start
-- from one (`notes-new`), and a note can take one's fields
-- (`notes-type`), keeping its own. A line tagging a type (`#meeting`)
-- says which of its fields the note lacks, and the quick fix adds them.

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")
local notes = require("./notes")
local index = require("./index")
local syntax = require("./syntax")

local M = {}

--- A type: its name ("Meeting", from "Meeting Template") and the note
--- that's its template.
export type Type = { name: string, template: string }

-- The types as last listed, with the templates folder they're from, made
-- again after the notes change.
local listed: { folder: string, types: { Type } }? = nil

index.on_changed(function()
	listed = nil
end)

-- The types, shared with the cache; `M.all` gives a copy.
local function types(): { Type }
	local folder = notes.templates_folder()
	local known = listed
	if known and known.folder == folder then
		return known.types
	end
	local prefix = `{folder}/`
	local out: { Type } = {}
	for _, note in index.all() do
		local _, rest = notes.split(note.name)
		if string.sub(rest, 1, #prefix) == prefix then
			local file = string.sub(rest, #prefix + 1)
			local name = string.gsub(file, "%s*[Tt]emplate$", "") :: string
			table.insert(out, { name = if name == "" then file else name, template = note.name })
		end
	end
	table.sort(out, function(a: Type, b: Type): boolean
		return string.lower(a.name) < string.lower(b.name)
	end)
	listed = { folder = folder, types = out }
	return out
end

--- The types there are: one for each note in the templates folder, by
--- name.
function M.all(): { Type }
	return table.clone(types())
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

-- The keys front matter `lines` has.
local function keys_of(lines: { string }?): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for _, block in blocks(lines or {}) do
		out[block.key] = true
	end
	return out
end

-- The fields of type `kind` that `text`, note `name`, doesn't have yet:
-- the blocks of its template's front matter (filled in) for keys the
-- note's front matter lacks.
local function lacking(
	kind: Type,
	name: string,
	text: string
): { { key: string, lines: { string } } }
	local template = notes.read(kind.template)
	local wanted = if template then (front_of(notes.filled(template, name))) else nil
	local have = keys_of((front_of(text)))
	local out = {}
	for _, block in blocks(wanted or {}) do
		if not have[block.key] then
			table.insert(out, block)
		end
	end
	return out
end

--- Gives note `name` type `kind`'s fields: those in its template's front
--- matter that the note doesn't have yet are added, with what the
--- template has for them; what the note says stays.
function M.apply(name: string, kind: Type)
	local text = notes.read(name) or ""
	local missing = lacking(kind, name, text)
	if #missing == 0 then
		return
	end
	local own, body = front_of(text)
	local lines: { string } = table.clone(own or {})
	for _, block in missing do
		table.move(block.lines, 1, #block.lines, #lines + 1, lines)
	end
	local front = `---\n{table.concat(lines, "\n")}\n---\n`
	core.file.write(notes.path(name), front, { from = 0, to = body - 1 })
end

-- The type tag `tag` names: `#meeting` is Meeting, `#book-club` Book club.
local function type_of_tag(tag: string): Type?
	local wanted = string.lower(tag)
	for _, kind in types() do
		if string.lower((string.gsub(kind.name, "%s+", "-"))) == wanted then
			return kind
		end
	end
	return nil
end

--- What line `line` of `text` (note `name`) suggests: a type one of its
--- tags names, in the text or front matter's `tags:`, and the keys of that
--- type's fields the note doesn't have yet. Nil when there's none to add.
function M.suggested(name: string, text: string, line: number): (Type?, { string })
	local lines = string.split(text, "\n")
	local here = lines[line + 1] or ""
	local own = front_of(text)
	local tags: { string } = syntax.tags(here)
	if own and line <= #own and string.match(here, "^%s*%-?%s*[%w_%-#]") then
		-- In front matter: the line's words, as `tags:` lists them.
		local named = index.front(own).tags
		for _, tag in (if type(named) == "table" then named else { named }) :: { any } do
			if type(tag) == "string" and string.find(here, tag, 1, true) then
				table.insert(tags, (string.gsub(tag, "^#", "")))
			end
		end
	end
	local have = keys_of(own)
	for _, tag in tags do
		local kind = type_of_tag(tag)
		local template = if kind then index.note(kind.template) else nil
		if kind and template then
			-- The template's keys as the index read them, so no file is read.
			local keys: { string } = {}
			for key in template.front do
				if not have[key] then
					table.insert(keys, key)
				end
			end
			if #keys > 0 then
				table.sort(keys)
				return kind, keys
			end
		end
	end
	return nil, {}
end

-- The quick fix on a line tagging a type: the note gets its fields.
core.lookup.add("fix", function(ctx)
	local name = notes.name_of(ctx.buffer)
	if name == nil then
		return false
	end
	local line = ctx.buffer:line_of(ctx.view:cursor())
	local kind = M.suggested(name, ctx.buffer:text(), line)
	if kind == nil then
		return false
	end
	M.apply(name, kind)
	return true
end)

-- The hint on the line the cursor is on, when it tags a type whose fields
-- the note doesn't have.
local function hint(view: greed.View)
	if not view:valid() then
		return
	end
	local buffer = view:buffer()
	local name = notes.name_of(buffer)
	if name == nil then
		return
	end
	local line = buffer:line_of(view:cursor())
	-- Only a line with a tag, or in front matter, can suggest one; the
	-- note's text is read only then.
	local here = buffer:line_text(line)
	local maybe = string.find(here, "#", 1, true) ~= nil
		or (line < 100 and buffer:line_text(0) == "---")
	local kind: Type?, keys: { string } = nil, {}
	if maybe then
		kind, keys = M.suggested(name, buffer:text(), line)
	end
	if kind == nil then
		buffer:decorate("note-types", {})
		return
	end
	local start = buffer:line_start(line)
	buffer:decorate("note-types", {
		{
			from = start,
			to = start,
			style = "comment",
			text = `  ⊕ {kind.name}: {notes.fix_key()} adds {table.concat(keys, ", ")}`,
			eol = true,
			action = "quick-fix",
		},
	})
end

greed.on("selection.changed", function(event: greed.SelectionChanged)
	hint(event.view)
end)

greed.on("buffer.changed", function(event: greed.BufferChanged)
	local view = greed.view()
	if view:buffer() == event.buffer then
		hint(view)
	end
end)

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
		local name = notes.name_of(ctx.buffer)
		if name == nil then
			greed.echo("this isn't a note")
			return
		end
		pick("Give this note the fields of", nil, function(kind)
			if kind then
				M.apply(name, kind)
			end
		end)
	end,
})

greed.keymap.bind({ layer = "leader" }, { ["n n"] = "notes-new", ["n y"] = "notes-type" })

return M
