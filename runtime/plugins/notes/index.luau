-- The index of notes: what each note holds (its title, headings and list
-- items as a tree, todos, tags, links, fields, reminders), for search, the
-- home screen, backlinks, the agenda and agents. It's worked out from the
-- files, and from the buffers of notes being edited, and never written
-- anywhere: the notes are the truth.
--
-- It's built the first time something asks (`M.ensure`), reading the notes
-- in the background (`greed.fs.scan`) and parsing them a slice at a time,
-- so the editor never waits; then it looks again every few seconds for
-- notes changed on disk, and follows open notes as they're typed in.

local greed = require("@greed")
local core = require("@core")
local markdown = require("@markdown")
local notes = require("./notes")
local syntax = require("./syntax")

local M = {}

--- How often, in milliseconds, the notes on disk are looked at again.
M.EVERY = 5000

--- How long, in milliseconds, parsing may run before it lets the editor
--- go on.
M.SLICE = 8

--- A todo: ticked or not, its text as written after its box, when it's
--- due, its reminders (each "2026-10-06 18:00", a date alone or a time
--- alone), how often it repeats (`habit` when as a habit), from and until
--- when, and the day a habit was last done.
export type Task = {
	done: boolean,
	text: string,
	due: string?,
	reminds: { string },
	every: string?,
	habit: boolean,
	starts: string?,
	ends: string?,
	done_on: string?,
}

--- A heading or a list item. `line` to `last` are its lines (0-based), a
--- list item's including those under it; `text` its words without markup
--- or markers; `parent` the node it's under, by its index in the note's
--- nodes. `id` is its `^block-id`, if it has one.
export type Node = {
	kind: "heading" | "item",
	line: number,
	last: number,
	text: string,
	level: number,
	parent: number?,
	id: string?,
	tags: { string },
	fields: { [string]: string },
	task: Task?,
}

--- A link from a note: on which line, to which note (its full name), and
--- to which heading or block in it.
export type Link = {
	line: number,
	target: string,
	heading: string?,
	block: string?,
	embed: boolean,
}

--- A reminder on a line of a note (any line, a todo or not): its date
--- and time, or a time alone, and what the line says of when: whether
--- it's a todo, its due date, how often it repeats (as a habit or not),
--- from and until when, and when a habit was last done.
export type Reminder = {
	line: number,
	text: string,
	date: string?,
	time: string?,
	todo: boolean,
	due: string?,
	every: string?,
	habit: boolean,
	starts: string?,
	ends: string?,
	done_on: string?,
}

--- What the index knows of a note.
export type Note = {
	name: string,
	path: string,
	--- When its file was last written and its size, as last read; -1 for a
	--- note known only from its buffer.
	modified: number,
	size: number,
	title: string,
	front: { [string]: string | { string } },
	--- Its tags in lower case, from its front matter and its text.
	tags: { [string]: boolean },
	--- Its fields: front matter first, then `key:: value` lines.
	fields: { [string]: string },
	nodes: { Node },
	links: { Link },
	reminders: { Reminder },
	--- The line (0-based) each `^block-id` names.
	blocks: { [string]: number },
}

-- A value from front matter: quotes taken off.
local function unquoted(value: string): string
	return string.match(value, '^"(.*)"$') or string.match(value, "^'(.*)'$") or value
end

--- Reads front matter's lines (between the `---` lines), as far as notes
--- use it: `key: value`, `key: [a, b]`, and `key:` followed by `- a` lines.
function M.front(lines: { string }): { [string]: string | { string } }
	local out: { [string]: string | { string } } = {}
	local list: { string }? = nil
	for _, line in lines do
		local item = string.match(line, "^%s+%-%s*(.-)%s*$") or string.match(line, "^%-%s+(.-)%s*$")
		if item and list then
			table.insert(list, unquoted(item))
			continue
		end
		local key, value = string.match(line, "^([%w_%-]+):%s*(.-)%s*$")
		if key == nil or value == nil then
			list = nil
			continue
		end
		key = string.lower(key)
		local inline = string.match(value, "^%[(.*)%]$")
		if value == "" then
			local fresh: { string } = {}
			out[key] = fresh
			list = fresh
		elseif inline then
			local items: { string } = {}
			for part in string.gmatch(inline, "[^,]+") do
				local trimmed = string.match(part, "^%s*(.-)%s*$") :: string
				if trimmed ~= "" then
					table.insert(items, unquoted(trimmed))
				end
			end
			out[key] = items
			list = nil
		else
			out[key] = unquoted(value)
			list = nil
		end
	end
	return out
end

-- The words of a list item's line, after its bullet and box, without its
-- markers and block id.
local function item_text(line: string): string
	local rest = string.match(line, "^%s*[-*+]%s+%[[ xX]%]%s+(.*)$")
		or string.match(line, "^%s*[-*+]%s+(.*)$")
		or string.match(line, "^%s*%d+[.)]%s+(.*)$")
		or line
	rest = string.gsub(rest, "%s*%^[%w%-]+%s*$", "") :: string
	return syntax.plain(rest)
end

--- What the note `name` at `path` holds, from its text.
function M.parse(name: string, path: string, text: string): Note
	local s = markdown.structure(text)
	local front_lines: { string } = {}
	if s.front then
		for n = 1, s.front - 1 do
			table.insert(front_lines, s.lines[n + 1])
		end
	end
	local front = M.front(front_lines)
	local note: Note = {
		name = name,
		path = path,
		modified = -1,
		size = #text,
		title = "",
		front = front,
		tags = {},
		fields = {},
		nodes = {},
		links = {},
		reminders = {},
		blocks = {},
	}
	for key, value in front do
		if type(value) == "string" then
			note.fields[key] = value
		end
	end
	local front_tags = front.tags
	if type(front_tags) == "string" then
		front_tags = string.split(front_tags, ",")
	end
	for _, tag in (front_tags or {}) :: { string } do
		local trimmed = string.match(tag, "^%s*#?(.-)%s*$") :: string
		if trimmed ~= "" then
			note.tags[string.lower(trimmed)] = true
		end
	end

	-- Headings and list items, in the order of their lines.
	local nodes: { Node } = {}
	for _, heading in s.headings do
		table.insert(nodes, {
			kind = "heading" :: "heading",
			line = heading.line,
			last = heading.last,
			text = heading.text,
			level = heading.level,
			tags = {},
			fields = {},
		})
	end
	for _, item in s.items do
		local line = s.lines[item.line + 1]
		local node: Node = {
			kind = "item" :: "item",
			line = item.line,
			last = item.last,
			text = item_text(line),
			level = item.indent,
			tags = {},
			fields = {},
		}
		local done, rest = syntax.parse(line)
		if done ~= nil and rest then
			local every, habit = syntax.every(rest)
			node.task = {
				done = done,
				text = rest,
				due = syntax.due(rest),
				reminds = syntax.reminds(rest),
				every = every,
				habit = habit,
				starts = syntax.starts(rest),
				ends = syntax.ends(rest),
				done_on = syntax.done_on(rest),
			}
		end
		table.insert(nodes, node)
	end
	table.sort(nodes, function(a: Node, b: Node): boolean
		return a.line < b.line
	end)
	-- Each node's parent: the nearest heading of a lower level above a
	-- heading; the item holding an item, or else the heading above it.
	local headings: { number } = {}
	local items: { number } = {}
	for i, node in nodes do
		if node.kind == "heading" then
			while #headings > 0 and nodes[headings[#headings]].level >= node.level do
				table.remove(headings)
			end
			node.parent = headings[#headings]
			table.insert(headings, i)
			table.clear(items)
		else
			while #items > 0 and nodes[items[#items]].last < node.line do
				table.remove(items)
			end
			node.parent = items[#items] or headings[#headings]
			table.insert(items, i)
		end
	end
	local node_at: { [number]: Node } = {}
	for _, node in nodes do
		node_at[node.line] = node
	end
	note.nodes = nodes

	-- Whether the note is one of yours, not in another place.
	local own = not string.find(name, ":", 1, true)
	for n = 0, #s.lines - 1 do
		if s.code_at[n] or (s.front and n <= s.front) then
			continue
		end
		local line = s.lines[n + 1]
		local node = node_at[n]
		-- Most lines hold none of these: look for each only where it can be.
		if string.find(line, "#", 1, true) then
			for _, tag in syntax.tags(line) do
				note.tags[string.lower(tag)] = true
				if node then
					table.insert(node.tags, tag)
				end
			end
		end
		if string.find(line, "::", 1, true) then
			for key, value in syntax.fields(line) do
				if note.fields[key] == nil then
					note.fields[key] = value
				end
				if node then
					node.fields[key] = value
				end
			end
		end
		if string.find(line, "^", 1, true) then
			local id = syntax.block_id(line)
			if id then
				if node then
					node.id = id
				end
				-- An id alone on its line names the block above it.
				local alone = string.match(line, "^%s*%^[%w%-]+%s*$") ~= nil
				note.blocks[id] = if alone and n > 0 then n - 1 else n
			end
		end
		if string.find(line, "[[", 1, true) then
			for _, link in syntax.links(line) do
				local target = link.target
				table.insert(note.links, {
					line = n,
					-- Between your own notes a name is the note's, as
					-- `notes.resolve` says, without looking up places.
					target = if target == ""
						then name
						elseif own and not string.find(target, ":", 1, true) then target
						else notes.resolve(target, name),
					heading = link.heading,
					block = link.block,
					embed = link.embed,
				})
			end
		end
		if string.find(line, "remind:", 1, true) then
			local done, rest = syntax.parse(line)
			if not done then
				local words = syntax.plain(rest or (string.gsub(line, "^%s*[-*+] ", "")))
				local every, habit = syntax.every(line)
				for _, reminder in syntax.reminders(line) do
					table.insert(note.reminders, {
						line = n,
						text = words,
						date = reminder.date,
						time = reminder.time,
						todo = done ~= nil,
						due = syntax.due(line),
						every = every,
						habit = habit,
						starts = syntax.starts(line),
						ends = syntax.ends(line),
						done_on = syntax.done_on(line),
					})
				end
			end
		end
	end

	local first_heading = s.headings[1]
	local title = front.title
	note.title = if type(title) == "string" and title ~= ""
		then title
		elseif first_heading and first_heading.level == 1 then first_heading.text
		else string.match(name, "([^/:]+)$") or name
	return note
end

-- What's indexed: notes by name, and by path; which notes link to each
-- note, which have each tag, and which go by each alias.
local by_name: { [string]: Note } = {}
local by_path: { [string]: string } = {}
local linking: { [string]: { [string]: boolean } } = {}
-- The same, by the name linked to in lower case, for aliases, which match
-- in any case.
local linking_any_case: { [string]: { [string]: boolean } } = {}
local tagging: { [string]: { [string]: boolean } } = {}
-- The notes going by each alias (`aliases:` in front matter), in lower
-- case, by alias.
local aliased: { [string]: string } = {}

--- The aliases `note`'s front matter gives it.
function M.aliases(note: Note): { string }
	local aliases = note.front.aliases
	if type(aliases) == "string" then
		return { aliases }
	end
	return if aliases then aliases else {}
end

-- Listeners told the name of each note whose entry changed or went.
local listeners: { (name: string) -> () } = {}

--- Calls `listener` with a note's name each time what the index knows of
--- it changes, or it goes. It goes when the plugin that added it does.
function M.on_changed(listener: (name: string) -> ())
	greed.plugin.tie(core.registry.put(listeners, listener))
end

-- Takes `name` out of the index.
local function drop(name: string)
	local old = by_name[name]
	if old == nil then
		return
	end
	by_name[name] = nil
	if by_path[old.path] == name then
		by_path[old.path] = nil
	end
	for _, link in old.links do
		local from = linking[link.target]
		if from then
			from[name] = nil
		end
		local any_case = linking_any_case[string.lower(link.target)]
		if any_case then
			any_case[name] = nil
		end
	end
	for _, alias in M.aliases(old) do
		if aliased[string.lower(alias)] == name then
			aliased[string.lower(alias)] = nil
		end
	end
	for tag in old.tags do
		local named = tagging[tag]
		if named then
			named[name] = nil
		end
	end
end

-- Puts `note` in the index in place of what it knew of it.
local function put(note: Note)
	drop(note.name)
	by_name[note.name] = note
	by_path[note.path] = note.name
	for _, link in note.links do
		local from = linking[link.target] or {}
		linking[link.target] = from
		from[note.name] = true
		local lower = string.lower(link.target)
		local any_case = linking_any_case[lower] or {}
		linking_any_case[lower] = any_case
		any_case[note.name] = true
	end
	for _, alias in M.aliases(note) do
		aliased[string.lower(alias)] = note.name
	end
	for tag in note.tags do
		local named = tagging[tag] or {}
		tagging[tag] = named
		named[note.name] = true
	end
end

-- Lets the editor go on when parsing has had its slice.
local slice_start = os.clock()
local function breathe()
	if (os.clock() - slice_start) * 1000 >= M.SLICE then
		greed.sleep(1)
		slice_start = os.clock()
	end
end

-- The buffer a note at `path` is open in, while it's being edited there.
local function editing(path: string): greed.Buffer?
	local buffer = greed.buffer_for(path)
	return if buffer and buffer:valid() and buffer:modified() then buffer else nil
end

-- The places the last look that finished covered, to tell when they change.
local looked_in = ""

local function places_key(): string
	local parts = {}
	for _, place in notes.places() do
		table.insert(parts, `{place.name}={place.folder}`)
	end
	return table.concat(parts, "\n")
end

-- Reads every place's notes again, parsing those whose file changed since
-- (or every one, the first time, read in the background with the scan).
-- Notes being edited are left to their buffers; notes gone from disk go.
local function refresh(first: boolean)
	local looking_in = places_key()
	local seen: { [string]: boolean } = {}
	local changed: { string } = {}
	slice_start = os.clock()
	for _, place in notes.places() do
		if greed.fs.stat(place.folder) == nil then
			continue
		end
		for _, file in greed.fs.scan(place.folder, { ext = "md", read = first }) do
			local path = `{place.folder}/{file.path}`
			seen[path] = true
			local name = notes.name(path)
			local known = by_name[name]
			if
				editing(path)
				or (
					known
					and known.path == path
					and known.modified == file.modified
					and known.size == file.size
				)
			then
				continue
			end
			local text = file.text or greed.fs.read(path)
			if text then
				local note = M.parse(name, path, text)
				note.modified, note.size = file.modified, file.size
				put(note)
				table.insert(changed, name)
			end
			breathe()
		end
	end
	for name, note in table.clone(by_name) do
		if not seen[note.path] and not editing(note.path) then
			drop(name)
			table.insert(changed, name)
		end
	end
	looked_in = looking_in
	for _, name in changed do
		core.registry.tell(listeners, name)
	end
end

local built = false
local building = false
local refreshing = false
-- The notes saved while the index was first being built.
local saved_while_building: { [string]: boolean } = {}

-- Looks at the notes again, after any look already under way, which may
-- have started before what's being asked about changed.
local function look(first: boolean)
	while refreshing do
		greed.sleep(5)
	end
	refreshing = true
	local ok, err = pcall(function()
		refresh(first)
	end)
	refreshing = false
	if not ok then
		error(err, 0)
	end
end

-- Reads the note at `path` again, as Greed just changed it: from its
-- buffer while it's being edited, or from disk; gone when it's gone.
local function reread(path: string)
	local name = notes.name(path)
	local buffer = greed.buffer_for(path)
	local text: string? = if buffer and buffer:valid() then buffer:text() else (greed.fs.read(path))
	if text == nil then
		drop(name)
	else
		local note = M.parse(name, path, text)
		local info = greed.fs.stat(path)
		note.modified = if info and info.modified then info.modified else -1
		note.size = if info then info.size else -1
		put(note)
	end
	core.registry.tell(listeners, name)
end

--- Builds the index if it isn't yet, and waits until it is. From then on
--- it keeps itself current: what Greed writes is read again at once (see
--- `core.file.on_changed`), notes being typed in a moment after typing
--- stops, and changes from elsewhere at the next look, every `M.EVERY`
--- milliseconds; when the places notes are in change, it looks again
--- before answering. Waits like greed.sleep: in commands, handlers and
--- greed.spawn.
function M.ensure()
	if building or built then
		-- Greed's own writes are in already; a change of places needs a
		-- look of its own, after any under way.
		while not built do
			greed.sleep(5)
		end
		if places_key() ~= looked_in then
			look(false)
		end
		return
	end
	building = true
	look(true)
	-- What was saved while the first look read the notes may have been
	-- read as it was before.
	for path in saved_while_building do
		reread(path)
	end
	table.clear(saved_while_building)
	built = true
	greed.spawn(function()
		while true do
			greed.sleep(M.EVERY)
			look(false)
		end
	end)
end

--- Looks at the notes on disk now, rather than at the next look. Waits
--- like `M.ensure`.
function M.refresh()
	M.ensure()
	look(false)
end

core.file.on_changed(function(path: string)
	if not built then
		return
	end
	if string.match(path, "%.md$") and notes.place_of(path) then
		reread(path)
		return
	end
	-- A folder moved or removed: the notes it held, and those it holds now,
	-- at the next look, which starts now.
	for _, place in notes.places() do
		if core.project.inside(place.folder, path) or core.project.inside(path, place.folder) then
			greed.spawn(function()
				look(false)
			end)
			return
		end
	end
end)

--- What the index knows of note `name`.
function M.note(name: string): Note?
	return by_name[name]
end

--- Every note, by name.
function M.all(): { Note }
	local out: { Note } = {}
	for _, note in by_name do
		table.insert(out, note)
	end
	table.sort(out, function(a: Note, b: Note): boolean
		return a.name < b.name
	end)
	return out
end

--- The names of the notes linking to note `name`, by its name or one of
--- its aliases, sorted.
function M.backlinks(name: string): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	local function from_all(linked: { [string]: boolean }?)
		for from in linked or {} :: { [string]: boolean } do
			if from ~= name and not seen[from] then
				seen[from] = true
				table.insert(out, from)
			end
		end
	end
	from_all(linking[name])
	local note = by_name[name]
	if note then
		-- A link to an alias names it as a note in the same place would,
		-- in any case.
		local place = string.match(name, "^([%w_-]+):")
		for _, alias in M.aliases(note) do
			from_all(linking_any_case[string.lower(if place then `{place}:{alias}` else alias)])
		end
	end
	table.sort(out)
	return out
end

--- The note a link to `target` goes to: the note of that name if there's
--- one, else the one with that alias (any case), else `target` itself, a
--- note to make.
function M.linked(target: string): string
	if by_name[target] then
		return target
	end
	local place, rest = string.match(target, "^([%w_-]+):(.+)$")
	local alias = aliased[string.lower(rest or target)]
	if alias and (place == nil or string.sub(alias, 1, #place + 1) == `{place}:`) then
		return alias
	end
	return target
end

--- The line (0-based) of the heading called `heading` (any case) or the
--- block with id `block` in note `name`, if the index knows of one.
function M.line_of(name: string, heading: string?, block: string?): number?
	local note = by_name[name]
	if note == nil then
		return nil
	end
	if block then
		return note.blocks[block]
	end
	if heading == nil then
		return nil
	end
	local wanted = string.lower(heading)
	for _, node in note.nodes do
		if node.kind == "heading" and string.lower(node.text) == wanted then
			return node.line
		end
	end
	return nil
end

--- The names of the notes with tag `tag` (without its `#`, any case), sorted.
function M.tagged(tag: string): { string }
	local out: { string } = {}
	for name in tagging[string.lower(tag)] or {} :: { [string]: boolean } do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

-- A note being edited is read from its buffer a moment after typing stops.
local pending: { [number]: boolean } = {}
-- The notes indexed from their buffers, by buffer, for when one closes.
local edited: { [number]: string } = {}
greed.on("buffer.changed", function(event: greed.BufferChanged)
	local buffer = event.buffer
	if not built or not buffer:valid() or not notes.is_note(buffer) then
		return
	end
	local id = buffer:id()
	if pending[id] then
		return
	end
	pending[id] = true
	greed.spawn(function()
		greed.sleep(300)
		pending[id] = nil
		if not buffer:valid() then
			return
		end
		local path = buffer:path() :: string
		edited[id] = path
		local name = notes.name(path)
		local known = by_name[name]
		local note = M.parse(name, path, buffer:text())
		-- Its file is as it was: what's on disk is read again once it's
		-- saved, or when edits are thrown away.
		note.modified = if known then known.modified else -1
		note.size = if known then known.size else -1
		put(note)
		core.registry.tell(listeners, name)
	end)
end)

-- A note saved is read again at once, before handlers that look at notes
-- on saving, like reminders', ask about it.
greed.on("buffer.saved", function(event: greed.BufferChanged)
	local buffer = event.buffer
	if not buffer:valid() or not notes.is_note(buffer) then
		return
	end
	local path = buffer:path() :: string
	if built then
		reread(path)
	elseif building then
		saved_while_building[path] = true
	end
end)

-- A note closed without saving goes back to what's on disk at the next look.
greed.on("buffer.closed", function(event: greed.BufferClosed)
	local path = edited[event.id]
	edited[event.id] = nil
	local name = if path then by_path[path] else nil
	local known = if name then by_name[name] else nil
	if known then
		known.modified = -1
	end
end)

return M
