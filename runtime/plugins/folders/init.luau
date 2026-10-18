-- Folders as text you edit: `space -` (or `:folder`) shows the folder of
-- the file you're in as a buffer with a line per file and folder. Rename
-- by editing a name, with any style's keys (Helix's `s` and `c` rename
-- many at once); make a file by adding a line, a folder by ending it in
-- `/`, and a file in a new folder with `a/b.txt`; delete by deleting the
-- line. Move a file by cutting its line in one folder's buffer and pasting
-- it in another's; pasting it while it's still in the first copies it.
-- Saving says what it will do and does it once you press y, for every
-- folder buffer at once; `:folder-undo` takes that back. Deleting goes to
-- the trash where there is one (see `core.file.remove`).
--
-- In a folder's buffer, enter opens the file or folder on the line and
-- `-` goes up to the folder above. Each line starts with a hidden number
-- that says which file it was, so a renamed line is a rename, not a
-- delete and a new file.

local greed = require("@greed")
local core = require("@core")

greed.option.define({
	name = "folder-hidden",
	doc = "Show hidden files and folders in a folder's buffer",
	default = false,
})

local KIND = "folder"

local M = {}

-- What a line's hidden number stands for: the file or folder it was.
type Entry = { path: string, dir: boolean }

-- Every file and folder shown in a folder's buffer, by its number.
local entries: { [number]: Entry } = {}
local next_id = 0

-- Each folder buffer's folder, and the numbers it was filled with, by
-- buffer id.
type Shown = { dir: string, ids: { number } }
local shown: { [number]: Shown } = {}

-- What the last save did, to take back with :folder-undo: each takes one
-- change back, the last first.
local last: { () -> () } = {}

--- A line of a folder's buffer as it reads: the number it carries (nil
--- for a new line), the name, and whether it ends in `/`.
function M.parse(line: string): (number?, string, boolean)
	local id, rest = string.match(line, "^(%d%d%d%d+) (.*)$")
	local name = string.match(rest or line, "^%s*(.-)%s*$") :: string
	local dir = string.sub(name, -1) == "/"
	if dir then
		name = string.gsub(name, "/+$", "") :: string
	end
	return if id then tonumber(id) else nil, name, dir
end

local function join(dir: string, name: string): string
	return if dir == "/" then "/" .. name else `{dir}/{name}`
end

local function parent_of(path: string): string
	local up = string.match(path, "^(.*)/[^/]*$")
	return if up == nil or up == "" then "/" else up
end

-- Fills `buffer` with folder `dir` as it is on the disk now: a line per
-- entry, folders first, each starting with its number, hidden.
local function fill(buffer: greed.Buffer, dir: string)
	local list: { greed.DirEntry } = greed.fs.list(
		dir,
		{ hidden = greed.option.get("folder-hidden") == true }
	) or {}
	local lines: { string } = {}
	local marks: { greed.Mark } = {}
	local ids: { number } = {}
	local at = 0
	for _, entry in list do
		next_id += 1
		entries[next_id] = { path = join(dir, entry.name), dir = entry.dir }
		table.insert(ids, next_id)
		local id = string.format("%04d ", next_id)
		local name = if entry.dir then entry.name .. "/" else entry.name
		table.insert(lines, id .. name)
		local hidden: greed.Mark =
			{ from = at, to = at + #id, style = "comment", conceal = true, reveal = "never" }
		table.insert(marks, hidden)
		if entry.dir then
			table.insert(
				marks,
				{ from = at + #id, to = at + #id + #name, style = "ui.tree.directory" }
			)
		end
		at += #id + #name + 1
	end
	shown[buffer:id()] = { dir = dir, ids = ids }
	buffer:set_name(core.project.tilde(dir) .. "/")
	buffer:edit(function(e)
		e:replace(0, buffer:len(), table.concat(lines, "\n"))
	end, { undo = false })
	buffer:clear_history()
	buffer:decorate("folder", marks)
end

local function is_dir(path: string): boolean
	local info = greed.fs.stat(path)
	return info ~= nil and info.kind == "dir"
end

-- Opening a folder, from the file picker, the tree or `:open`, shows it as
-- a buffer to edit.
core.file.opener(is_dir, function(path: string, views: { greed.View }): string?
	local buffer = greed.create_buffer(KIND, "")
	fill(buffer, path)
	for _, view in views do
		view:show(buffer)
	end
	return nil
end)

--- Shows folder `dir` as a buffer in the main view: a full path, or from
--- the project's root.
function M.open(dir: string)
	local full = core.project.resolve(dir)
	if not is_dir(full) then
		error(`there's no folder at {core.project.short(full)}`, 0)
	end
	core.file.open(full)
end

-- The folder buffers open now.
local function folder_buffers(): { greed.Buffer }
	local out = {}
	for _, buffer in greed.buffers() do
		if shown[buffer:id()] and buffer:valid() then
			table.insert(out, buffer)
		end
	end
	return out
end

--- One change a save makes.
export type Change = {
	kind: "make" | "rename" | "copy" | "delete",
	from: string?,
	to: string?,
	dir: boolean,
}

--- What saving folder buffers would do: `lines` are each buffer's folder
--- and its lines now, `known` what the numbers they were filled with stand
--- for. Or nil and why when it can't be done, like two lines with one name
--- or a name that's there already.
function M.plan(
	lines: { { dir: string, lines: { string } } },
	known: { [number]: Entry }
): ({ Change }?, string?)
	-- Where each number is now, and the new lines' places.
	local places: { [number]: { string } } = {}
	local made: { { path: string, dir: boolean } } = {}
	local named: { [string]: boolean } = {}
	for _, folder in lines do
		for _, line in folder.lines do
			local id, name, dir = M.parse(line)
			if name ~= "" then
				local path = core.project.clean(join(folder.dir, name))
				if named[path] then
					return nil, `{core.project.short(path)} is there twice`
				end
				named[path] = true
				if id and known[id] then
					places[id] = places[id] or {}
					table.insert(places[id], path)
				else
					table.insert(made, { path = path, dir = dir })
				end
			end
		end
	end
	local changes: { Change } = {}
	local deletes: { Change } = {}
	for _, new in made do
		-- A new line naming a file that was listed and whose line went (its
		-- number typed over, say) is that file, kept.
		local kept = false
		for id, entry in known do
			if entry.path == new.path and places[id] == nil then
				places[id] = { new.path }
				kept = true
			end
		end
		if not kept then
			if greed.fs.stat(new.path) then
				return nil, `{core.project.short(new.path)} is there already`
			end
			local make: Change = { kind = "make", to = new.path, dir = new.dir }
			table.insert(changes, make)
		end
	end
	for id, entry in known do
		local at = places[id]
		if at == nil then
			local delete: Change = { kind = "delete", from = entry.path, dir = entry.dir }
			table.insert(deletes, delete)
			continue
		end
		local stays = table.find(at, entry.path) ~= nil
		for i, path in at do
			if path ~= entry.path then
				-- Swapping names takes two saves: one to a name that's free.
				if greed.fs.stat(path) then
					return nil, `{core.project.short(path)} is there already`
				end
				local move = not stays and i == 1
				if not move and entry.dir then
					return nil, `copying a folder isn't done: {core.project.short(path)}`
				end
				local change: Change = {
					kind = if move then "rename" else "copy",
					from = entry.path,
					to = path,
					dir = entry.dir,
				}
				table.insert(changes, change)
			end
		end
	end
	-- Folders are made before what goes in them, and deletes come last.
	local order: { [string]: number } = { make = 1, rename = 2, copy = 3 }
	table.sort(changes, function(a: Change, b: Change): boolean
		if order[a.kind] ~= order[b.kind] then
			return order[a.kind] < order[b.kind]
		end
		return (a.to or "") < (b.to or "")
	end)
	table.sort(deletes, function(a: Change, b: Change): boolean
		return (a.from or "") < (b.from or "")
	end)
	table.move(deletes, 1, #deletes, #changes + 1, changes)
	return changes, nil
end

-- A change in words, for asking before it's done.
local function describe(change: Change): string
	local short = core.project.short
	if change.kind == "make" then
		return `make {short(change.to or "")}{if change.dir then "/" else ""}`
	elseif change.kind == "delete" then
		return `delete {short(change.from or "")}`
	end
	return `{change.kind} {short(change.from or "")} to {short(change.to or "")}`
end

-- Does `change`, and returns what takes it back.
local function apply(change: Change): () -> ()
	local from, to = change.from or "", change.to or ""
	if change.kind == "make" then
		if change.dir then
			greed.fs.mkdir(to)
		else
			greed.fs.mkdir(parent_of(to))
			greed.fs.write(to, "")
		end
		return function()
			core.file.remove(to)
		end
	elseif change.kind == "rename" then
		core.file.rename(from, to)
		return function()
			core.file.rename(to, from)
		end
	elseif change.kind == "copy" then
		local ok, err = greed.fs.copy(from, to)
		if not ok then
			error(err, 0)
		end
		return function()
			core.file.remove(to)
		end
	end
	local trashed = core.file.remove(from)
	return function()
		if trashed == nil then
			error(`{core.project.short(from)} was deleted for good, not to the trash`, 0)
		end
		greed.fs.mkdir(parent_of(from))
		local ok, err = greed.fs.rename(trashed, from)
		if not ok then
			error(err, 0)
		end
	end
end

-- Fills every folder buffer again from the disk.
local function refresh()
	for _, buffer in folder_buffers() do
		fill(buffer, shown[buffer:id()].dir)
	end
end

-- Saving a folder buffer does what the folder buffers' changes say, once
-- you press y.
core.file.on_save(KIND, function()
	local lines = {}
	local known: { [number]: Entry } = {}
	for _, buffer in folder_buffers() do
		local s = shown[buffer:id()]
		table.insert(lines, { dir = s.dir, lines = string.split(buffer:text(), "\n") })
		for _, id in s.ids do
			known[id] = entries[id]
		end
	end
	local changes, why = M.plan(lines, known)
	if changes == nil then
		error(why, 0)
	end
	if #changes == 0 then
		greed.echo("nothing to change")
		return
	end
	local words = {}
	for i, change in changes do
		if i > 3 then
			table.insert(words, `and {#changes - 3} more`)
			break
		end
		table.insert(words, describe(change))
	end
	greed.echo(`{table.concat(words, ", ")}? y does it, anything else doesn't`)
	local key = greed.next_key()
	greed.echo("")
	if key ~= "y" then
		greed.echo("nothing changed")
		return
	end
	local undo: { () -> () } = {}
	for _, change in changes do
		local ok, back = pcall(apply, change)
		if not ok then
			last = undo
			refresh()
			error(`{describe(change)}: {back}; what came before it is done (:folder-undo)`, 0)
		end
		table.insert(undo, back)
	end
	last = undo
	refresh()
	greed.echo(
		`{#changes} {if #changes == 1 then "change" else "changes"} done; :folder-undo takes them back`
	)
end)

greed.command({
	name = "folder",
	doc = "Show a folder as a buffer you edit to rename, make, move and delete files: this file's, or the one given",
	args = {
		{ name = "path", doc = "The folder", complete = "file", type = "string", optional = true },
	},
	run = function(ctx)
		local path = ctx.values.path :: string?
		if path == nil then
			local file = ctx.buffer:path()
			local s = shown[ctx.buffer:id()]
			path = if file then parent_of(file) elseif s then s.dir else core.project.root()
		end
		M.open(path :: string)
	end,
})

greed.command({
	name = "folder-open",
	doc = "Open the file or folder on the cursor's line of a folder's buffer",
	run = function(ctx)
		local s = shown[ctx.buffer:id()]
		if s == nil then
			return
		end
		local line = ctx.buffer:line_text(ctx.buffer:line_of(ctx.view:cursor()))
		local _, name, dir = M.parse(line)
		if name == "" then
			return
		end
		local path = join(s.dir, name)
		if dir or is_dir(path) then
			fill(ctx.buffer, path)
		else
			core.file.open(path)
		end
	end,
})

greed.command({
	name = "folder-up",
	doc = "Show the folder above in a folder's buffer",
	run = function(ctx)
		local s = shown[ctx.buffer:id()]
		if s then
			fill(ctx.buffer, parent_of(s.dir))
		end
	end,
})

greed.command({
	name = "folder-undo",
	doc = "Take back what the last save of folder buffers did",
	run = function()
		if #last == 0 then
			greed.echo("nothing to take back")
			return
		end
		local undo = last
		last = {}
		for i = #undo, 1, -1 do
			undo[i]()
		end
		refresh()
		greed.echo("taken back")
	end,
})

greed.on("buffer.closed", function(event: greed.BufferClosed)
	shown[event.id] = nil
end)

greed.keymap.bind({ layer = "leader" }, { ["-"] = "folder" })
greed.keymap.bind({ kind = KIND, role = "command" }, {
	enter = "folder-open",
	["-"] = "folder-up",
})

return M
