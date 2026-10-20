-- Renaming a tag in every note: `#garden` in the text, with the tags under
-- it (`#garden/seeds`), and `garden` in front matter's `tags:`.
--
--     :notes-tag-rename garden yard

local greed = require("@greed")
local core = require("@core")
local markdown = require("@markdown")
local notes = require("./notes")
local index = require("./index")
local syntax = require("./syntax")

local M = {}

-- `tag` with `old` at its start changed to `new`, when it's `old` or a tag
-- under it, in any case; nil otherwise.
local function renamed(tag: string, old: string, new: string): string?
	local lower = string.lower(tag)
	if lower == old or string.sub(lower, 1, #old + 1) == `{old}/` then
		return new .. string.sub(tag, #old + 1)
	end
	return nil
end

-- Whether `note` has tag `old` or one under it.
local function tagged(note: index.Note, old: string): boolean
	for tag in note.tags do
		if renamed(tag, old, "") then
			return true
		end
	end
	for _, node in note.nodes do
		for _, tag in node.tags do
			if renamed(tag, old, "") then
				return true
			end
		end
	end
	return false
end

-- A change to a note: bytes `from` to `to` (0-based, `to` not in it)
-- become `text`.
type Change = { from: number, to: number, text: string }

-- The changes renaming `old` to `new` makes in `text`: the `#tags` outside
-- code, and the values of front matter's `tags:`.
local function changes_in(text: string, old: string, new: string): { Change }
	local out: { Change } = {}
	local s = markdown.structure(text)
	local in_tags = false
	for n = 1, (s.front or 1) - 1 do
		local line, base = s.lines[n + 1], s.starts[n + 1]
		local key = string.match(line, "^([%w_%-]+):")
		if key then
			in_tags = string.lower(key) == "tags"
		end
		if in_tags then
			-- Each value, between spaces, brackets, commas and quotes;
			-- the key and a list's `-` don't match.
			for at: any, word: any in string.gmatch(line, "()([^%s%[%],\"']+)") do
				local hash = if string.sub(word, 1, 1) == "#" then 1 else 0
				local to = renamed(string.sub(word, hash + 1), old, new)
				if to then
					local from = base + at - 1 + hash
					table.insert(out, { from = from, to = from + #word - hash, text = to })
				end
			end
		end
	end
	for n = (s.front or -1) + 1, #s.lines - 1 do
		if s.code_at[n] then
			continue
		end
		local base = s.starts[n + 1]
		for _, span in syntax.tag_spans(s.lines[n + 1]) do
			local to = renamed(span.tag, old, new)
			if to then
				table.insert(out, { from = base + span.from - 1, to = base + span.to, text = to })
			end
		end
	end
	return out
end

--- Renames tag `old` to `new` in every note, and the tags under it: in
--- their text (not in code) and in their front matter's `tags:`. Returns
--- how many notes changed.
function M.rename(old: string, new: string): number
	old = string.lower((string.gsub(old, "^#", "")))
	new = string.gsub(new, "^#", "") :: string
	index.ensure()
	local changed = 0
	for _, note in index.all() do
		if not tagged(note, old) then
			continue
		end
		local text = notes.read(note.name)
		if text == nil then
			continue
		end
		local changes = changes_in(text, old, new)
		-- From the end, so the places before each change stay right.
		for i = #changes, 1, -1 do
			local change = changes[i]
			core.file.write(note.path, change.text, { from = change.from, to = change.to })
		end
		if #changes > 0 then
			changed += 1
		end
	end
	return changed
end

greed.command({
	name = "notes-tag-rename",
	doc = "Rename a tag in every note, with the tags under it",
	args = {
		{ name = "old", doc = "The tag to rename, with or without its #" },
		{ name = "new", doc = "What to call it" },
	},
	run = function(ctx)
		local old, new = ctx.values.old :: string, ctx.values.new :: string
		local changed = M.rename(old, new)
		greed.echo(`#{old} is #{new} now, in {changed} {if changed == 1 then "note" else "notes"}`)
	end,
})

return M
