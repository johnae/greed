-- Mentions: another note's name, title or alias written in a note without a
-- link, like "talked to Anna about the garden plans" with a note called
-- Garden plans. The line the cursor is on says which notes it mentions,
-- and the quick fix (ctrl-. in the vscode style, space a, or a click on
-- the hint) links them, keeping the words as written. Each note lists the
-- notes mentioning it under those linking to it.

local core = require("@core")
local greed = require("@greed")
local notes = require("./notes")
local syntax = require("./syntax")
local index = require("./index")
local links = require("./links")

local M = {}

--- Another note named in a line: where (1-based, end exclusive), the
--- words as written, the note, and how it was named.
export type Mention = {
	from: number,
	to: number,
	text: string,
	note: string,
	by: "name" | "title" | "alias",
}

-- What a note can be called, in lower case.
type Called = { text: string, note: string, by: "name" | "title" | "alias" }

-- The names, titles and aliases of every note, by their first word in
-- lower case, longest first; made again after the notes change. Making it
-- waits for the index, like greed.sleep.
local by_first: { [string]: { Called } }? = nil

index.on_changed(function()
	by_first = nil
end)

-- Note `name` without its place and folders: "projects/greed" is "greed".
local function base_of(name: string): string
	return string.match(name, "([^/:]+)$") or name
end

-- Whether `text` is worth looking for: three letters or more, and not a
-- date or a number.
local function worth(text: string): boolean
	return #text >= 3 and string.find(text, "%a") ~= nil
end

local function called(): { [string]: { Called } }
	local made = by_first
	if made then
		return made
	end
	index.ensure()
	local out: { [string]: { Called } } = {}
	local function add(text: string, note: string, by: "name" | "title" | "alias")
		local lower = string.lower(text)
		local first = string.match(lower, "^[^%s%p]+")
		if first and worth(lower) then
			local list = out[first] or {}
			out[first] = list
			table.insert(list, { text = lower, note = note, by = by })
		end
	end
	for _, note in index.all() do
		if not notes.routine(note.name) then
			local base = base_of(note.name)
			add(base, note.name, "name")
			if string.lower(note.title) ~= string.lower(base) then
				add(note.title, note.name, "title")
			end
			for _, alias in index.aliases(note) do
				add(alias, note.name, "alias")
			end
		end
	end
	for _, list in out do
		table.sort(list, function(a: Called, b: Called): boolean
			return #a.text > #b.text
		end)
	end
	by_first = out
	return out
end

-- `text` with what isn't prose blanked out, the same length: links, inline
-- code and web addresses.
local function prose(text: string): string
	local out = text
	for _, link in syntax.links(text) do
		out = string.sub(out, 1, link.from - 1)
			.. string.rep(" ", link.to - link.from)
			.. string.sub(out, link.to)
	end
	out = string.gsub(out, "`[^`]*`", function(code: string): string
		return string.rep(" ", #code)
	end) :: string
	out = string.gsub(out, "%a+://%S+", function(url: string): string
		return string.rep(" ", #url)
	end) :: string
	return out
end

--- The notes `text` (a line) mentions without linking them, in order and
--- not overlapping, leaving out headings, note `here` (the one it's in)
--- and notes whose names mean little in a sentence (`notes.routine`).
function M.in_line(text: string, here: string?): { Mention }
	local out: { Mention } = {}
	if not string.find(text, "%a") or string.match(text, "^#") then
		return out
	end
	local names = called()
	local lower = string.lower(prose(text))
	local after = 0
	for at: any, word in string.gmatch(lower, "()([^%s%p]+)") do
		if at <= after then
			continue
		end
		local list: { Called } = names[word :: string] or {}
		for _, name in list do
			local stop = at + #name.text
			local next_char = string.sub(lower, stop, stop)
			if
				name.note ~= here
				and string.sub(lower, at, stop - 1) == name.text
				and (next_char == "" or string.match(next_char, "[%s%p]") ~= nil)
			then
				table.insert(out, {
					from = at,
					to = stop,
					text = string.sub(text, at, stop - 1),
					note = name.note,
					by = name.by,
				})
				after = stop - 1
				break
			end
		end
	end
	return out
end

--- The link that takes the place of `mention` in note `from`: the words
--- stay as written, shown in place of the note's name when they differ.
function M.link_text(mention: Mention, from: string?): string
	if mention.by == "alias" then
		return `[[{mention.text}]]`
	end
	local written = links.written(mention.note, from)
	return if written == mention.text then `[[{written}]]` else `[[{written}|{mention.text}]]`
end

-- The quick fix in a note: the mentions on the cursor's line, linked.
core.lookup.add("fix", function(ctx)
	local here = notes.name_of(ctx.buffer)
	if here == nil then
		return false
	end
	local buffer = ctx.buffer
	local line = buffer:line_of(ctx.view:cursor())
	local start = buffer:line_start(line)
	local found = M.in_line(buffer:line_text(line), here)
	if #found == 0 then
		return false
	end
	buffer:edit(function(e)
		for _, mention in found do
			e:replace(start + mention.from - 1, start + mention.to - 1, M.link_text(mention, here))
		end
	end)
	return true
end)

-- The hint on the line the cursor is on in a note: which notes it
-- mentions, and how to link them.
local function hint(view: greed.View)
	-- Events can come for a view that has closed since.
	if not view:valid() then
		return
	end
	local buffer = view:buffer()
	local here = notes.name_of(buffer)
	if here == nil then
		return
	end
	local line = buffer:line_of(view:cursor())
	local found = M.in_line(buffer:line_text(line), here)
	if #found == 0 then
		buffer:decorate("mentions", {})
		return
	end
	local named = {}
	for _, mention in found do
		local note = index.note(mention.note)
		table.insert(named, if note then note.title else mention.note)
	end
	local start = buffer:line_start(line)
	buffer:decorate("mentions", {
		{
			from = start,
			to = start,
			style = "comment",
			text = `  ↗ {table.concat(named, ", ")}: {notes.fix_key()} links`,
			eol = true,
			action = "quick-fix",
		},
	})
end

greed.on("selection.changed", function(event: greed.SelectionChanged)
	hint(event.view)
end)

greed.on("view.focused", function(event: greed.ViewFocused)
	hint(event.view)
end)

greed.on("buffer.changed", function(event: greed.BufferChanged)
	local view = greed.view()
	if view:buffer() == event.buffer then
		hint(view)
	end
end)

--- The notes mentioning note `name` without linking it, sorted: a line of
--- each with the words it's mentioned in. Searches the notes in the
--- background, so it waits like greed.sleep.
function M.mentioning(name: string): { { note: string, line: number, text: string } }
	index.ensure()
	local note = index.note(name)
	if note == nil or notes.routine(name) then
		return {}
	end
	local words: { string } = {}
	for _, text in { base_of(name), note.title, table.unpack(index.aliases(note)) } do
		if worth(string.lower(text)) and not table.find(words, text) then
			table.insert(words, text)
		end
	end
	if #words == 0 then
		return {}
	end
	local escaped = {}
	for _, text in words do
		table.insert(escaped, (string.gsub(text, "[%^%$%(%)%%%.%[%]%*%+%-%?{}|\\]", "\\%0")))
	end
	local found = notes.grep(`(?i)\\b({table.concat(escaped, "|")})\\b`)
	if found == nil then
		return {}
	end
	local out: { { note: string, line: number, text: string } } = {}
	local seen: { [string]: boolean } = {}
	for _, line in found do
		if line.note ~= name and not seen[line.note] then
			for _, mention in M.in_line(line.text, line.note) do
				if mention.note == name then
					seen[line.note] = true
					table.insert(out, { note = line.note, line = line.line, text = line.text })
					break
				end
			end
		end
	end
	table.sort(out, function(a: { note: string }, b: { note: string }): boolean
		return a.note < b.note
	end)
	return out
end

-- Each note shows where it's mentioned, worked out as it's opened or saved.
local function refresh(buffer: greed.Buffer)
	local here = notes.name_of(buffer)
	if here == nil then
		return
	end
	greed.spawn(function()
		local found = M.mentioning(here)
		if buffer:valid() then
			local names = {}
			for _, mention in found do
				table.insert(names, mention.note)
			end
			links.show_mentioned(buffer, names)
		end
	end)
end

greed.on("buffer.opened", function(event: greed.BufferChanged)
	if greed.view():buffer() == event.buffer then
		hint(greed.view())
	end
	refresh(event.buffer)
end)

greed.on("buffer.saved", function(event: greed.BufferChanged)
	refresh(event.buffer)
end)

return M
