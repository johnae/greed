-- Links between notes: [[note]] and [[note|what to show]]. In notes the
-- brackets are hidden (except while typing on their line), `g d` follows a
-- link, and the notes linking to a note, and mentioning it (mentions.luau),
-- are listed at its end. Links in code blocks are code.

local core = require("@core")
local greed = require("@greed")
local markdown = require("@markdown")
local notes = require("./notes")
local syntax = require("./syntax")
local index = require("./index")
local picker = require("@picker")
local todos = require("./todos")

--- A link in a buffer: where it is (bytes, end exclusive), where the part
--- shown in its place is, the note it names (as written, without a
--- `#heading` or `#^block`), the heading or block in it, and whether it
--- embeds what it names (`![[...]]`).
type Link = {
	from: number,
	to: number,
	target: string,
	text_from: number,
	text_to: number,
	heading: string?,
	block: string?,
	embed: boolean,
}

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
				heading = link.heading,
				block = link.block,
				embed = link.embed,
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

--- The note a link to `target`, in note `from` (nil outside notes), goes
--- to: by its name, its file name in any folder, or one of the notes'
--- aliases (see `index.linked`); an empty target is `from` itself.
function M.target(target: string, from: string?): string
	if target == "" and from then
		return from
	end
	index.ensure()
	return index.linked(notes.resolve(target, from), from)
end

-- The backlinks shown under each note, by buffer id, worked out when it's
-- opened or saved.
local shown_backlinks: { [number]: { string } } = {}

--- How many lines of a note an embed shows at most.
M.EMBED_LINES = 30

-- What each embed in a buffer shows, by buffer id and then by what it
-- names, and whether it's still current; worked out away from drawing,
-- which only reads it. A stale one shows until it's worked out again.
type Embedded = { lines: { greed.MarkLine }, current: boolean }
local embedded: { [number]: { [string]: Embedded } } = {}
local embedding: { [number]: { [string]: boolean } } = {}

local redraw: (buffer: greed.Buffer?) -> ()

-- The notes mentioning each note without linking it, by buffer id, worked
-- out away from drawing (mentions.luau).
local shown_mentioned: { [number]: { string } } = {}

--- Shows `names`, the notes mentioning the note in `buffer` without
--- linking it, at its end under those linking to it.
function M.show_mentioned(buffer: greed.Buffer, names: { string })
	local was = shown_mentioned[buffer:id()] or {}
	if table.concat(was, "\n") ~= table.concat(names, "\n") then
		shown_mentioned[buffer:id()] = names
		redraw(buffer)
	end
end

local function embed_key(link: Link): string
	return `{link.target}#{link.heading or ""}#{link.block or ""}`
end

--- The lines an embed of `target` (a note's full name) shows: the note
--- without its front matter, the section under heading `heading`, or the
--- block `block` (with what's under it, for a list item), without block
--- ids. Nil when there's no such note, heading or block.
function M.embedded_lines(target: string, heading: string?, block: string?): { string }?
	local text = notes.read(target)
	if text == nil then
		return nil
	end
	local lines = string.split(text, "\n")
	if lines[#lines] == "" then
		table.remove(lines)
	end
	local first, last = 0, #lines - 1
	if heading or block then
		local note = index.note(target)
		local at = index.line_of(target, heading, block)
		if note == nil or at == nil then
			return nil
		end
		first, last = at, at
		for _, node in note.nodes do
			if node.line == at then
				last = node.last
				if node.kind == "heading" then
					-- A heading's section goes on to the next heading of its level
					-- or above.
					last = #lines - 1
					for _, other in note.nodes do
						if
							other.kind == "heading"
							and other.line > at
							and other.level <= node.level
						then
							last = other.line - 1
							break
						end
					end
				end
			end
		end
	elseif lines[1] == "---" then
		for i = 2, #lines do
			if lines[i] == "---" then
				first = i
				break
			end
		end
	end
	local out: { string } = {}
	for n = first, last do
		if #out >= M.EMBED_LINES then
			table.insert(out, "…")
			break
		end
		local line = lines[n + 1]
		if syntax.block_id(line) then
			line = string.gsub(line, "%s*%^[%w%-]+%s*$", "") :: string
		end
		table.insert(out, line)
	end
	while #out > 0 and string.match(out[#out], "^%s*$") do
		table.remove(out)
	end
	return out
end

-- Works out what `link`, an embed in `buffer` (note `from`), shows, and
-- draws the buffer again with it.
local function embed_later(buffer: greed.Buffer, link: Link, from: string?)
	local id = buffer:id()
	local key = embed_key(link)
	local busy = embedding[id] or {}
	embedding[id] = busy
	if busy[key] then
		return
	end
	busy[key] = true
	greed.spawn(function()
		local target = M.target(link.target, from)
		local lines = M.embedded_lines(target, link.heading, link.block)
		busy[key] = nil
		if not buffer:valid() then
			return
		end
		local shown: { greed.MarkLine } = {}
		local said: { string } = lines or { `({target} isn't there to show)` }
		for _, line in said do
			local pieces: greed.MarkLine =
				{ { text = "│ ", style = "comment" }, { text = line, style = "markup.quote" } }
			table.insert(shown, pieces)
		end
		local cached: { [string]: Embedded } = embedded[id] or {}
		embedded[id] = cached
		cached[key] = { lines = shown, current = true }
		redraw(buffer)
	end)
end

redraw = markdown.conceal({
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
		local cached: { [string]: Embedded } = embedded[buffer:id()] or {}
		local path = buffer:path()
		local here = if path then notes.name(path) else nil
		for _, link in links_in(s, first, last) do
			if link.embed then
				local shown = cached[embed_key(link)]
				if shown then
					table.insert(
						marks,
						{ from = link.from, to = link.to, style = "comment", lines = shown.lines }
					)
				end
				if shown == nil or not shown.current then
					embed_later(buffer, link, here)
				end
			end
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
		local backlinks = shown_backlinks[buffer:id()] or {}
		local mentioned = shown_mentioned[buffer:id()] or {}
		local count = #s.lines
		if last == count - 1 and (#backlinks > 0 or #mentioned > 0) then
			local lines: { greed.MarkLine } = {}
			local function list(title: string, names: { string })
				if #names > 0 then
					table.insert(lines, "")
					table.insert(lines, title)
					for _, name in names do
						table.insert(lines, `  [[{name}]]`)
					end
				end
			end
			list("Linked from:", backlinks)
			list("Mentioned in:", mentioned)
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

-- The embeds in `buffer` are worked out again as they're next drawn.
local function stale(buffer: greed.Buffer)
	local cached: { [string]: Embedded } = embedded[buffer:id()] or {}
	for _, shown in cached do
		shown.current = false
	end
end

local function refresh(buffer: greed.Buffer)
	if not notes.is_note(buffer) then
		return
	end
	shown_backlinks[buffer:id()] = M.backlinks(notes.name(buffer:path() :: string))
	stale(buffer)
	redraw(buffer)
end

greed.on("buffer.opened", function(event: greed.BufferChanged)
	refresh(event.buffer)
end)

greed.on("buffer.saved", function(event: greed.BufferChanged)
	refresh(event.buffer)
end)

-- A note linking here added or taken away, here or on disk, shows at once,
-- and so does a change to an embedded note.
index.on_changed(function()
	for _, buffer in greed.buffers() do
		if embedded[buffer:id()] and buffer:valid() then
			stale(buffer)
			redraw(buffer)
		end
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

-- g d on a [[link]] opens the note it points at, at the heading or block
-- it names, making the note if it's new. In Markdown outside the notes it
-- opens the file beside it (`M.target_path`).
core.lookup.add("definition", function(ctx)
	local head = ctx.view:cursor()
	for _, link in M.links(ctx.buffer) do
		if link.from <= head and head < link.to then
			local path = ctx.buffer:path()
			if path and notes.place_of(path) == nil and not notes.named_place(link.target) then
				core.file.open(M.target_path(link.target, path))
				return true
			end
			local from = if path and notes.place_of(path) then notes.name(path) else nil
			local name = M.target(link.target, from)
			local line = index.line_of(name, link.heading, link.block)
			if line then
				core.file.open_at(notes.path(name), line)
			else
				core.file.open(notes.path(name))
			end
			return true
		end
	end
	return false
end)

--- How note `from` (nil outside notes) writes a link to note `name`: as
--- short as still goes there.
function M.written(name: string, from: string?): string
	local _, rest = notes.split(name)
	if rest ~= name and notes.resolve(rest, from) == name then
		return rest
	end
	return name
end

--- A place in a note to link to: a heading, or a block (a list item, or a
--- line with a `^id` already), with the sign it reads with in a list ("##",
--- "-" or "^") and what it says.
export type Place = {
	note: string,
	line: number,
	heading: string?,
	id: string?,
	sign: string,
	text: string,
}

--- The places in `note` to link to, in order: its headings and list
--- items, then the other lines with ids.
function M.places_in(note: index.Note): { Place }
	local out: { Place } = {}
	local named: { [number]: boolean } = {}
	for _, node in note.nodes do
		named[node.line] = true
		local heading = node.kind == "heading"
		table.insert(out, {
			note = note.name,
			line = node.line,
			heading = if heading then node.text else nil,
			id = node.id,
			sign = if heading then string.rep("#", node.level) else "-",
			text = node.text,
		})
	end
	for id, line in note.blocks do
		if not named[line] then
			table.insert(out, { note = note.name, line = line, id = id, sign = "^", text = id })
		end
	end
	return out
end

--- Puts block id `id` at the end of line `line` (0-based) of note `name`,
--- so `[[name#^id]]` links to it.
function M.give_id(name: string, line: number, id: string)
	local text = todos.line(name, line)
	notes.set_line(name, line, `{(string.gsub(text, "%s+$", ""))} ^{id}`)
end

--- A new block id, like Obsidian's: six letters and digits.
function M.new_id(): string
	return greed.hash.random(3)
end

--- The link to `place` from note `from` (nil outside notes), giving the
--- block an id at the end of its line when it has none yet.
function M.link_to(place: Place, from: string?): string
	local name = if place.note == from then "" else M.written(place.note, from)
	if place.heading then
		return `[[{name}#{place.heading}]]`
	end
	local id: string = place.id or M.new_id()
	if place.id == nil then
		M.give_id(place.note, place.line, id)
	end
	return `[[{name}#^{id}]]`
end

greed.command({
	name = "notes-link",
	doc = "Link to a heading, a list item or a block in a note, picked from all of them",
	run = function(ctx)
		index.ensure()
		local path = ctx.buffer:path()
		local here = if path and notes.is_note(ctx.buffer) then notes.name(path) else nil
		local items = {}
		local all = index.all()
		table.sort(all, function(a: index.Note, b: index.Note)
			return a.name < b.name
		end)
		for _, note in all do
			for _, place in M.places_in(note) do
				table.insert(
					items,
					{ label = `{note.name}  {place.sign} {place.text}`, value = place }
				)
			end
		end
		picker.pick("Link to", items, function(item)
			local link = M.link_to(item.value, here)
			local at = ctx.view:cursor()
			ctx.buffer:edit(function(e)
				e:insert(at, link)
			end)
			ctx.view:set_cursor(at + #link)
		end)
	end,
})

--- Changes the links to note `old` in every other note to go to `new`,
--- after it was renamed, keeping their headings, blocks and shown text.
--- Links to its aliases stay as they are.
function M.relink(old: string, new: string)
	index.ensure()
	for _, from in index.backlinks(old) do
		local text = notes.read(from)
		if text == nil then
			continue
		end
		local changes: { { from: number, to: number, text: string } } = {}
		local base = 0
		for _, line in string.split(text, "\n") do
			if string.find(line, "[[", 1, true) then
				for _, link in syntax.links(line) do
					if link.target ~= "" and notes.resolve(link.target, from) == old then
						-- The name's place: after the brackets (and `!`) and any space.
						local start = string.find(line, link.target, link.from, true) :: number
						table.insert(changes, {
							from = base + start - 1,
							to = base + start - 1 + #link.target,
							text = M.written(new, from),
						})
					end
				end
			end
			base += #line + 1
		end
		-- From the end, so the places before each change stay right.
		for i = #changes, 1, -1 do
			local change = changes[i]
			core.file.write(notes.path(from), change.text, { from = change.from, to = change.to })
		end
	end
end

-- A note renamed (or a folder of them) takes the links to it along.
core.file.on_changed(function(path: string, to: string?)
	if to == nil or notes.place_of(path) == nil then
		return
	end
	local moved: { { old: string, new: string } } = {}
	local function move(from: string)
		local new = to .. string.sub(from, #path + 1)
		if string.match(new, "%.md$") and notes.place_of(new) then
			table.insert(moved, { old = notes.name(from), new = notes.name(new) })
		end
	end
	if string.match(path, "%.md$") then
		-- The index has let go of it already.
		move(path)
	else
		for _, note in index.all() do
			if core.project.inside(note.path, path) then
				move(note.path)
			end
		end
	end
	if #moved > 0 then
		greed.spawn(function()
			for _, move in moved do
				M.relink(move.old, move.new)
			end
		end)
	end
end)

return M
