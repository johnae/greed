-- Where the notes are, which buffers are notes, and reading and writing
-- them by name.

local kern = require("@kern")

kern.option.define({
	name = "notes-folder",
	doc = "The folder notes live in; ~ is your home folder",
	default = "~/notes",
})

kern.option.define({
	name = "notes-everywhere",
	doc = "Treat every Markdown file as a note: concealed links and backlinks",
	default = false,
})

kern.option.define({
	name = "notes-conceal",
	doc = "Show links in notes without their brackets, and markup as symbols",
	default = true,
})

local M = {}

--- The notes folder, with ~ filled in.
function M.folder(): string
	local folder = kern.option.get("notes-folder") :: string
	local home = kern.fs.dirs().home
	if home and (folder == "~" or string.sub(folder, 1, 2) == "~/") then
		folder = home .. string.sub(folder, 2)
	end
	return (string.gsub(folder, "/+$", ""))
end

local function absolute(path: string): string
	return if string.sub(path, 1, 1) == "/" then path else `{kern.fs.cwd()}/{path}`
end

--- Whether `buffer` is a note: Markdown in the notes folder, or any
--- Markdown with `notes-everywhere`.
function M.is_note(buffer: kern.Buffer): boolean
	-- A buffer can be closed by the time an event about it is handled.
	local ok, path = pcall(buffer.path, buffer)
	if not ok or path == nil or not string.match(path, "%.md$") then
		return false
	end
	if kern.option.get("notes-everywhere") == true then
		return true
	end
	local folder = M.folder()
	return string.sub(absolute(path), 1, #folder + 1) == folder .. "/"
end

--- The file for note `name`, e.g. "ideas" or "projects/kern".
function M.path(name: string): string
	local file = if string.match(name, "%.md$") then name else name .. ".md"
	return `{M.folder()}/{file}`
end

--- The name of the note at `path`: its path in the folder, without ".md".
function M.name(path: string): string
	local folder = M.folder()
	local full = absolute(path)
	if string.sub(full, 1, #folder + 1) == folder .. "/" then
		full = string.sub(full, #folder + 2)
	end
	return (string.gsub(full, "%.md$", ""))
end

--- Every note's name, sorted.
function M.all(): { string }
	local names = {}
	for _, path in kern.files(M.folder()) do
		if string.match(path, "%.md$") then
			table.insert(names, (string.gsub(path, "%.md$", "")))
		end
	end
	table.sort(names)
	return names
end

--- The buffer note `name` is open in, if it is.
function M.buffer(name: string): kern.Buffer?
	local path = M.path(name)
	for _, buffer in kern.buffers() do
		local p = buffer:path()
		if p and absolute(p) == path then
			return buffer
		end
	end
	return nil
end

--- Note `name`'s text, as the editor has it if it's open.
function M.read(name: string): string?
	local buffer = M.buffer(name)
	if buffer then
		return buffer:text()
	end
	return (kern.fs.read(M.path(name)))
end

--- Adds `text` as a line at the end of note `name`, making the note if
--- there isn't one. An open note is changed in the editor (and saved).
function M.append(name: string, text: string)
	local buffer = M.buffer(name)
	if buffer then
		local current = buffer:text()
		local line = if current == "" or string.sub(current, -1) == "\n" then text else "\n" .. text
		buffer:edit(function(e)
			e:insert(buffer:len(), line .. "\n")
		end)
		buffer:save()
		return
	end
	local path = M.path(name)
	local current: string = kern.fs.read(path) or ""
	local before = if current ~= "" and string.sub(current, -1) ~= "\n"
		then current .. "\n"
		else current
	local ok, err = kern.fs.write(path, before .. text .. "\n")
	if not ok then
		error(err, 0)
	end
end

--- Today's date, as notes write it: "2026-10-01".
function M.today(): string
	return os.date("%Y-%m-%d") :: string
end

export type Symbols = {
	todo: string,
	done: string,
	--- One for each heading level, the last for any deeper.
	headings: { string },
	bullet: string,
	due: string,
}

export type Rule = {
	--- A Luau pattern, e.g. "#[%w_-]+" for tags.
	pattern: string,
	--- The style what it matches is drawn in.
	style: string,
	--- What to show in its place, on lines the cursor isn't on.
	show: string?,
	--- A command clicking it runs, with the cursor put on it first.
	action: string?,
}

--- What notes show their markup as, and the rules you added (see
--- look.luau, which draws them).
M.look = {
	symbols = {
		todo = "☐",
		done = "☑",
		headings = { "◉", "○", "◆", "◇" },
		bullet = "•",
		due = "📅",
	} :: Symbols,
	rules = {} :: { Rule },
	-- Draws the notes again; look.luau sets it.
	changed = function() end,
}

--- Replaces some or all of the symbols notes show their markup as.
function M.symbols(changes: { [string]: any })
	for name, value in changes do
		(M.look.symbols :: any)[name] = value
	end
	M.look.changed()
end

--- Adds a rule: text matching `pattern` drawn in `style`, shown as `show`
--- and running the command `action` when clicked, if given.
function M.rule(rule: Rule)
	table.insert(M.look.rules, rule)
	M.look.changed()
end

return M
