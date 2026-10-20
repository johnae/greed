-- Completion in notes: the `/` menu, and links as they're typed.
--
-- Typing `/` at the start of a word offers what a note can hold (a todo, a
-- date, a reminder, a repeat, a link, a heading, a table, a tag), and
-- picking one puts it in with places to fill in, as the completion menu
-- puts in a snippet.
--
-- Typing `[[` offers the notes (and their aliases); after a note's name,
-- `#` offers its headings and `#^` its list items and blocks, a block
-- without an id getting one when it's picked.
--
-- In front matter, the keys the notes have are offered, and after a key
-- (or a list item under one) the values the notes give it.

local greed = require("@greed")
local core = require("@core")
local notes = require("@notes")
local home = require("./home")

-- Where notes are written: in notes, and in the box on the home.
local function written_in(buffer: greed.Buffer): boolean
	return notes.is_note(buffer) or home.is(buffer)
end

local M = {}

--- What the menu offers: what to type after `/`, what it puts in (a
--- snippet), and what it is. Dates are worked out as the menu opens.
function M.items(): { { name: string, text: string, detail: string } }
	local today = notes.today()
	local tomorrow = notes.dates.add_days(today, 1)
	return {
		{ name = "todo", text = "- [ ] $0", detail = "a box to tick" },
		{ name = "today", text = today, detail = "today's date" },
		{ name = "tomorrow", text = tomorrow, detail = "tomorrow's date" },
		{ name = "due", text = "due:${1:" .. tomorrow .. "}$0", detail = "when a todo is due" },
		{
			name = "remind",
			text = "remind:${1:" .. tomorrow .. "} ${2:09:00}$0",
			detail = "a reminder",
		},
		{
			name = "every",
			text = "every:${1|monday,tuesday,wednesday,thursday,friday,saturday,sunday,day,weekday,week,month,year|}$0",
			detail = "a todo that comes back",
		},
		{ name = "link", text = "[[${1:note}]]$0", detail = "a link to a note" },
		{ name = "heading", text = "## ${1:Heading}$0", detail = "a heading" },
		{
			name = "table",
			text = "| ${1:Name} | ${2:Value} |\n|---|---|\n| $0 | |",
			detail = "a table",
		},
		{ name = "tag", text = "#${1:tag}$0", detail = "a tag" },
	}
end

-- What the menu offers at the cursor in `view`: the items, after a `/`
-- starting a word in a note.
local function offered(view: greed.View): { core.CompletionItem }?
	local buffer = view:buffer()
	if not written_in(buffer) then
		return nil
	end
	local pos = view:cursor()
	local start = buffer:line_start(buffer:line_of(pos))
	local before = buffer:slice(start, pos)
	-- A `/` starting a word, and what's typed after it.
	local slash = string.match(before, "^()/%a*$") or string.match(before, "%s()/%a*$")
	if slash == nil then
		return nil
	end
	local from = start + (slash :: number) - 1
	local items: { core.CompletionItem } = {}
	for _, item in M.items() do
		table.insert(items, {
			label = `/{item.name}`,
			detail = item.detail,
			text = item.text,
			from = from,
			snippet = true,
		})
	end
	return items
end

-- What's typed of a link before the cursor in `view`, if it's in one: the
-- text after `[[`, where it starts, and whether `]]` follows the cursor.
local function typing_link(view: greed.View): (string?, number, boolean)
	local buffer = view:buffer()
	local pos = view:cursor()
	local line = buffer:line_of(pos)
	local start = buffer:line_start(line)
	local before = buffer:slice(start, pos)
	local at: any, typed = string.match(before, "%[%[()([^%[%]|]*)$")
	if at == nil then
		return nil, 0, false
	end
	local after = buffer:slice(pos, math.min(pos + 2, buffer:line_end(line)))
	return typed, start + at - 1, after == "]]"
end

-- The ids offered for blocks that have none yet, by id: one goes on its
-- line once a note links to it (below).
local pending: { [string]: notes.Place } = {}

-- Links offered at the cursor in `view`, as `[[` is typed in a note.
local function linked(view: greed.View): { core.CompletionItem }?
	local buffer = view:buffer()
	if not written_in(buffer) then
		return nil
	end
	local typed, from, closed = typing_link(view)
	if typed == nil then
		return nil
	end
	local links = notes.links
	local index = notes.index
	index.ensure()
	local path = buffer:path()
	local here = if path then notes.name(path) else nil
	local close = if closed then "" else "]]"
	local items: { core.CompletionItem } = {}
	local name, anchor = string.match(typed, "^([^#]*)#(.*)$")
	if name and anchor then
		local note = index.note(links.target(name, here))
		if note == nil then
			return items
		end
		local block = string.sub(anchor, 1, 1) == "^"
		local after = from + #name + 1 + (if block then 1 else 0)
		-- Only this menu's ids can be picked.
		table.clear(pending)
		for _, place in links.places_in(note) do
			if block and place.heading == nil then
				local id: string = place.id or links.new_id()
				if place.id == nil then
					pending[id] = place
				end
				table.insert(items, {
					label = place.text,
					detail = if place.id then `^{id}` else "gets an id",
					text = id .. close,
					from = after,
				})
			elseif not block and place.heading then
				table.insert(items, {
					label = place.text,
					detail = place.sign,
					text = place.heading .. close,
					from = after,
				})
			end
		end
		return items
	end
	for _, note in index.all() do
		if note.name ~= here then
			local written = links.written(note.name, here)
			table.insert(items, {
				label = written,
				detail = if note.title and note.title ~= written then note.title else nil,
				text = written .. close,
				from = from,
			})
			for _, alias in index.aliases(note) do
				table.insert(items, {
					label = alias,
					detail = `another name for {written}`,
					text = alias .. close,
					from = from,
				})
			end
		end
	end
	return items
end

-- The front matter key whose value is typed on line `line` of `buffer`
-- (the key itself, or one above for a list's `- item`), and what's typed
-- of it; or with no key, what's typed of a key. Nil outside front matter.
local function typing_front(buffer: greed.Buffer, line: number, before: string): (string?, string?)
	if line == 0 or buffer:slice(buffer:line_start(0), buffer:line_end(0)) ~= "---" then
		return nil, nil
	end
	local above: string? = nil
	for n = 1, line - 1 do
		local text = buffer:slice(buffer:line_start(n), buffer:line_end(n))
		if string.match(text, "^%-%-%-%s*$") then
			return nil, nil
		end
		local key = string.match(text, "^([%w_%-]+):")
		if key then
			above = key
		elseif not string.match(text, "^%s") then
			above = nil
		end
	end
	local key, value = string.match(before, "^([%w_%-]+):%s+(.*)$")
	if key then
		return key, value
	end
	local item = string.match(before, "^%s+%-%s+(.*)$")
	if item then
		return above, item
	end
	return nil, string.match(before, "^([%w_%-]*)$")
end

-- `counts`' names, most first.
local function by_count(counts: { [string]: number }): { string }
	local out: { string } = {}
	for name in counts do
		table.insert(out, name)
	end
	table.sort(out, function(a: string, b: string): boolean
		return if counts[a] ~= counts[b] then counts[a] > counts[b] else a < b
	end)
	return out
end

-- Front matter at the cursor in `view`: the keys the notes have, and once
-- a key's typed, the values they give it (`[[Steph Ango]]` as written).
local function fielded(view: greed.View): { core.CompletionItem }?
	local buffer = view:buffer()
	if not notes.is_note(buffer) then
		return nil
	end
	local pos = view:cursor()
	local line = buffer:line_of(pos)
	local before = buffer:slice(buffer:line_start(line), pos)
	local key, typed = typing_front(buffer, line, before)
	if typed == nil then
		return nil
	end
	notes.index.ensure()
	local counts: { [string]: number } = {}
	local function count(name: string)
		counts[name] = (counts[name] or 0) + 1
	end
	for _, note in notes.index.all() do
		if key == nil then
			for name in note.front do
				count(name)
			end
		else
			local value = note.front[string.lower(key)]
			if type(value) == "table" then
				for _, each in value do
					count(each)
				end
			elseif type(value) == "string" and value ~= "" then
				count(value)
			end
		end
	end
	local items: { core.CompletionItem } = {}
	for _, name in by_count(counts) do
		table.insert(items, {
			label = name,
			detail = if key then `in {counts[name]} notes` else "a field",
			-- A link is quoted, as YAML wants it.
			text = if key == nil
				then `{name}: `
				elseif string.sub(name, 1, 2) == "[[" then `"{name}"`
				else name,
			from = pos - #typed,
		})
	end
	return items
end

-- A link picked to a block offered an id gives the block that id: the
-- menu puts the link in, and this sees it on the lines that changed.
greed.on("buffer.changed", function(event: greed.BufferChanged)
	local buffer = event.buffer
	if next(pending) == nil or not written_in(buffer) then
		return
	end
	local last_line = buffer:line_count() - 1
	local first = event.from_line or 0
	local last = math.min(event.to_line or last_line, last_line)
	local text = buffer:slice(buffer:line_start(first), buffer:line_end(last))
	for id, place in pending do
		if string.find(text, `#^{id}]]`, 1, true) then
			table.clear(pending)
			notes.links.give_id(place.note, place.line, id)
			return
		end
	end
end)

-- Both are the lsp plugin's menu: they're asked while it's loaded, before
-- completing paths.
local function attach()
	local completion = require("@lsp").completion
	completion.source(offered, { first = true })
	completion.source(linked, { first = true })
	completion.source(fielded, { first = true })
	completion.keys_over("hoard")
	completion.keys_over("file")
end

if table.find(greed.plugin.list(), "lsp") then
	attach()
end

greed.on("plugin.loaded", function(event: greed.PluginLoaded)
	if event.name == "lsp" then
		attach()
	end
end)

return M
