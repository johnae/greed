-- Where the notes are, which buffers are notes, and reading and writing
-- them by name.

local greed = require("@greed")
local core = require("@core")

greed.option.define({
	name = "notes-folder",
	doc = "The folder notes live in; ~ is your home folder",
	default = "~/notes",
})

greed.option.define({
	name = "notes-everywhere",
	doc = "Treat every Markdown file as a note: concealed links and backlinks",
	default = false,
})

greed.option.define({
	name = "notes-conceal",
	doc = "Show links in notes without their brackets, and markup as symbols",
	default = true,
})

greed.option.define({
	name = "notes-project-folder",
	doc = "Where a project keeps its notes, in the project: they're named project:NAME, and the plan and decisions you share with agents are among them",
	default = ".greed/notes",
})

local M = {}

--- A folder of notes. Notes in your own (`notes-folder`) go by their
--- names; those in another place by the place's name first, like
--- "project:plan".
export type Place = { name: string, folder: string }

--- Your notes folder, with ~ filled in.
function M.folder(): string
	return core.project.resolve(greed.option.get("notes-folder") :: string)
end

--- The project's notes folder: `notes-project-folder` in the project shown.
function M.project_folder(): string
	return core.project.resolve(greed.option.get("notes-project-folder") :: string)
end

-- Places added with `M.add_place`, by name.
local added: { Place } = {}

--- Adds a folder of notes, named `name` (letters, digits, - and _): its
--- notes are `name:NOTE`, and they're searched, linked and listed with the
--- rest. E.g. `notes.add_place("work", "~/work/notes")` in your config.
--- It goes when the plugin (or config) that added it does.
function M.add_place(name: string, folder: string)
	assert(string.match(name, "^[%w_-]+$"), "a place's name is letters, digits, - and _")
	for i, place in added do
		if place.name == name then
			table.remove(added, i)
		end
	end
	greed.plugin.tie(
		core.registry.put(added, { name = name, folder = core.project.resolve(folder) })
	)
end

--- Every place notes are: yours first (named ""), those added, then the
--- project's.
function M.places(): { Place }
	local mine = M.folder()
	local places: { Place } = { { name = "", folder = mine } }
	for _, place in added do
		table.insert(places, place)
	end
	local project = M.project_folder()
	if project ~= mine then
		table.insert(places, { name = "project", folder = project })
	end
	return places
end

--- The place called `name` ("" for yours), if there is one.
function M.place(name: string): Place?
	for _, place in M.places() do
		if place.name == name then
			return place
		end
	end
	return nil
end

--- Note `name`'s place and its name there: "project:plan" is "plan" in the
--- project's place; a name without a known place is yours.
function M.split(name: string): (Place, string)
	local place_name, rest = string.match(name, "^([%w_-]+):(.+)$")
	local place = place_name and M.place(place_name)
	if place and rest then
		return place, rest
	end
	return M.places()[1], name
end

-- What Obsidian's settings in the notes folder say, by file
-- (`.obsidian/daily-notes.json`), read again every few seconds.
local obsidian_read: { [string]: { at: number, folder: string, value: { [string]: any } } } = {}

--- What Obsidian's settings in `.obsidian/FILE.json` of the notes folder
--- say (`daily-notes`, `templates`, `types`), or an empty table where
--- there are none. Read again every few seconds.
function M.obsidian(file: string): { [string]: any }
	local folder = M.folder()
	local known = obsidian_read[file]
	if known == nil or known.folder ~= folder or os.clock() - known.at > 5 then
		local text = greed.fs.read(`{folder}/.obsidian/{file}.json`)
		local ok, value = pcall(greed.json.decode, text or "")
		known = {
			at = os.clock(),
			folder = folder,
			value = if ok and type(value) == "table" then value else {},
		}
		obsidian_read[file] = known
	end
	return known.value
end

-- Obsidian's setting `key` in `.obsidian/FILE.json`, when it's text that
-- says something.
local function obsidian(file: string, key: string): string?
	local value = M.obsidian(file)[key]
	return if type(value) == "string" and string.match(value, "%S") then value else nil
end

-- A folder name as a setting gives it: without slashes at its ends.
local function trimmed_folder(folder: string): string
	return (string.gsub(string.gsub(folder, "^/+", ""), "/+$", ""))
end

--- The folder day notes go in: "daily", or the one Obsidian's daily notes
--- are set to keep them in.
function M.daily_folder(): string
	local set = obsidian("daily-notes", "folder")
	return if set then trimmed_folder(set) else "daily"
end

--- The folder templates are in: "templates", or Obsidian's.
function M.templates_folder(): string
	local set = obsidian("templates", "folder")
	return if set then trimmed_folder(set) else "templates"
end

-- The files in each notes folder by their name in lower case, found by
-- walking it, walked again after a minute.
local by_name: { [string]: { at: number, files: { [string]: string } } } = {}

--- The file (a picture, a PDF) that `![[name]]` in note `from` shows, as
--- Obsidian finds it: a path from the notes folder, beside the note, in
--- Obsidian's attachments folder, or anywhere in the notes folder by its
--- name, in any case. Nil when there's none. Walking the folder waits like
--- greed.sleep.
function M.attachment(name: string, from: string?): string?
	local place, rest = M.split(from or "")
	local folder = place.folder
	local note_dir = string.match(`{folder}/{rest}`, "^(.*)/[^/]*$") :: string
	local set = obsidian("app", "attachmentFolderPath")
	local candidates = { `{folder}/{name}`, `{note_dir}/{name}` }
	if set and string.sub(set, 1, 2) == "./" then
		table.insert(candidates, `{note_dir}/{trimmed_folder(string.sub(set, 3))}/{name}`)
	elseif set and set ~= "/" then
		table.insert(candidates, `{folder}/{trimmed_folder(set)}/{name}`)
	end
	for _, path in candidates do
		if core.project.inside(path, folder) and greed.fs.stat(path) then
			return path
		end
	end
	local known = by_name[folder]
	if known == nil or os.clock() - known.at > 60 then
		local files: { [string]: string } = {}
		for _, file in greed.fs.scan(folder) do
			local base = string.lower(string.match(file.path, "[^/]+$") :: string)
			files[base] = files[base] or `{folder}/{file.path}`
		end
		known = { at = os.clock(), files = files }
		by_name[folder] = known
	end
	return known.files[string.lower(string.match(name, "[^/]+$") :: string)]
end

-- How day notes' names are written: Obsidian's format when it's the
-- year, month and day once each with marks between (`YYYY-MM-DD`,
-- `DD.MM.YYYY`), else "YYYY-MM-DD".
local function day_format(): string
	local set = obsidian("daily-notes", "format")
	if set == nil then
		return "YYYY-MM-DD"
	end
	local rest, count = string.gsub(set, "YYYY", "")
	local _, months = string.gsub(rest, "MM", "")
	local _, days = string.gsub(rest, "DD", "")
	local marks = string.gsub(string.gsub(rest, "MM", ""), "DD", "")
	return if count == 1
			and months == 1
			and days == 1
			and not string.find(marks, "[%w%[]")
		then set
		else "YYYY-MM-DD"
end

-- The name of a day note in the day notes' folder, `date` ("2026-10-01")
-- written as their format says.
local function day_name(date: string): string
	local y, m, d = string.match(date, "^(%d+)%-(%d+)%-(%d+)$")
	local written = string.gsub(day_format(), "YYYY", y or date)
	written = string.gsub(written, "MM", m or "")
	written = string.gsub(written, "DD", d or "")
	return `{M.daily_folder()}/{written}`
end

--- The day ("2026-10-01") note `name` is the day note of, if it's one.
function M.day_of(name: string): string?
	local _, rest = M.split(name)
	local format = day_format()
	local function escaped(text: string): string
		return (string.gsub(text, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
	end
	local pattern = string.gsub(escaped(format), "YYYY", "(%%d%%d%%d%%d)")
	pattern = string.gsub(string.gsub(pattern, "MM", "(%%d%%d)"), "DD", "(%%d%%d)")
	local a, b, c = string.match(rest, `^{escaped(M.daily_folder())}/{pattern}$`)
	if a == nil or b == nil or c == nil then
		return nil
	end
	-- The year, month and day, in the order the format has them.
	local function at(token: string): number
		return (string.find(format, token, 1, true)) or 0
	end
	type Part = { at: number, part: string }
	local order: { Part } = {
		{ at = at("YYYY"), part = "y" },
		{ at = at("MM"), part = "m" },
		{ at = at("DD"), part = "d" },
	}
	table.sort(order, function(x: Part, y: Part): boolean
		return x.at < y.at
	end)
	local got: { [string]: string } = {}
	for i, value in { a, b, c } do
		got[order[i].part] = value
	end
	return `{got.y}-{got.m}-{got.d}`
end

--- Whether note `name` is a template, one in the templates folder.
function M.is_template(name: string): boolean
	local _, rest = M.split(name)
	local templates = M.templates_folder()
	return string.sub(rest, 1, #templates + 1) == `{templates}/`
end

--- Whether note `name` is one whose name means little among others or in
--- a sentence: a day's note, a template, a weekly review, the inbox.
function M.routine(name: string): boolean
	local _, rest = M.split(name)
	local daily = M.daily_folder()
	return string.sub(rest, 1, #daily + 1) == `{daily}/`
		or M.is_template(name)
		or string.match(rest, "^reviews/") ~= nil
		or rest == "inbox"
end

-- `rest` in `place` as a note's full name.
local function qualified(place: Place, rest: string): string
	return if place.name == "" then rest else `{place.name}:{rest}`
end

--- The place the file at `path` is in, and its path there; nil outside
--- every place. The deepest place wins, for one inside another.
function M.place_of(path: string): (Place?, string?)
	local full = core.project.resolve(path)
	local best: Place? = nil
	for _, place in M.places() do
		local inside = string.sub(full, 1, #place.folder + 1) == place.folder .. "/"
		if inside and (best == nil or #place.folder > #best.folder) then
			best = place
		end
	end
	if best == nil then
		return nil, nil
	end
	return best, string.sub(full, #best.folder + 2)
end

--- Whether `buffer` is a note: Markdown in a place notes are, or any
--- Markdown with `notes-everywhere`.
function M.is_note(buffer: greed.Buffer): boolean
	-- A buffer can be closed by the time an event about it is handled.
	local path = if buffer:valid() then buffer:path() else nil
	if path == nil or not string.match(path, "%.md$") then
		return false
	end
	if greed.option.get("notes-everywhere") == true then
		return true
	end
	return M.place_of(path) ~= nil
end

--- The file for note `name`, e.g. "ideas", "projects/greed" or
--- "project:plan". A name that would leave its place, like "../x" or
--- "/etc/x", is an error: agents name notes too.
function M.path(name: string): string
	local place, rest = M.split(name)
	if string.sub(rest, 1, 1) == "/" or string.find(`/{rest}/`, "/%.%.?/") then
		error(`{name} isn't a note's name: names stay inside their place, without . or ..`, 0)
	end
	local file = if string.match(rest, "%.md$") then rest else rest .. ".md"
	local path = `{place.folder}/{file}`
	if not core.project.inside(path, place.folder) then
		error(`{name} isn't inside {place.folder}`, 0)
	end
	return path
end

--- The name of the note at `path`: its path in its place, without ".md",
--- after the place's name for places other than yours.
function M.name(path: string): string
	local place, rest = M.place_of(path)
	if place and rest then
		return qualified(place, (string.gsub(rest, "%.md$", "")))
	end
	return (string.gsub(core.project.resolve(path), "%.md$", ""))
end

--- The name of the note `buffer` is, or nil when it isn't one.
function M.name_of(buffer: greed.Buffer): string?
	local path = buffer:path()
	return if path and M.is_note(buffer) then M.name(path) else nil
end

--- Every note's name, sorted, from every place.
function M.all(): { string }
	local names = {}
	for _, place in M.places() do
		if greed.fs.stat(place.folder) then
			for _, path in greed.files(place.folder) do
				if string.match(path, "%.md$") then
					table.insert(names, qualified(place, (string.gsub(path, "%.md$", ""))))
				end
			end
		end
	end
	table.sort(names)
	return names
end

export type Found = { note: string, line: number, text: string }

--- The lines matching the regex `pattern` in every place's notes, with
--- each one's note and 0-based line; nil and why for a bad pattern.
function M.grep(pattern: string): ({ Found }?, string?)
	local out: { Found } = {}
	for _, place in M.places() do
		if greed.fs.stat(place.folder) then
			local lines, err = greed.fs.grep(pattern, place.folder)
			if lines == nil then
				return nil, err
			end
			for _, line in lines do
				if string.match(line.path, "%.md$") then
					local rest = string.gsub(line.path, "%.md$", "")
					table.insert(
						out,
						{ note = qualified(place, rest), line = line.line, text = line.text }
					)
				end
			end
		end
	end
	return out, nil
end

--- The place a link's `target` names before its colon, as "work:plan"
--- names "work"; nil when it names none that exists.
function M.named_place(target: string): Place?
	local place_name = string.match(target, "^([%w_-]+):")
	return if place_name then M.place(place_name) else nil
end

--- Where a link to `target` in note `from` goes: a name with a place goes
--- there; one without goes to `from`'s place when the note is there (or
--- isn't anywhere), and otherwise to yours.
function M.resolve(target: string, from: string?): string
	if M.named_place(target) then
		return target
	end
	local from_place = if from then (M.split(from)) else M.places()[1]
	local here = qualified(from_place, target)
	if
		from_place.name == ""
		or greed.fs.stat(M.path(here))
		or not greed.fs.stat(M.path(target))
	then
		return here
	end
	return target
end

--- The buffer note `name` is open in, if it is.
function M.buffer(name: string): greed.Buffer?
	return greed.buffer_for(M.path(name))
end

--- Note `name`'s text, as the editor has it if it's open.
function M.read(name: string): string?
	return (core.file.text(M.path(name)))
end

--- The key for the quick fix, as a hint in a note says it.
function M.fix_key(): string
	return if greed.option.get("editing-style") == "vscode" then "ctrl-." else "space a"
end

-- Checks on what agents may write, each saying why not for a note's path.
local guards: { (path: string) -> string? } = {}

--- Keeps agents' note tools from writing where `check` says why not,
--- given a note's file; e.g. the plan plugin keeps decisions for you.
--- It goes when the plugin that added it does.
function M.guard(check: (path: string) -> string?)
	greed.plugin.tie(core.registry.put(guards, check))
end

--- Errors with why when agents may not write note `name`.
function M.check_agent_write(name: string)
	local path = M.path(name)
	for _, check in guards do
		local why = check(path)
		if why then
			error(why, 0)
		end
	end
end

--- Adds `text` as a line at the end of note `name`, making the note if
--- there isn't one. An open note is changed in the editor (and saved).
function M.append(name: string, text: string)
	local path = M.path(name)
	local current = core.file.text(path) or ""
	local line = if current == "" or string.sub(current, -1) == "\n" then text else "\n" .. text
	core.file.write(path, line .. "\n", { from = #current, to = #current })
end

--- Replaces line `line` (0-based) of note `name` with `text`. An open note
--- is changed in the editor (and saved).
function M.set_line(name: string, line: number, text: string)
	local path = M.path(name)
	local current = core.file.text(path)
	local lines = string.split(current or "", "\n")
	if current == nil or line >= #lines or (line == #lines - 1 and lines[#lines] == "") then
		error(`{name} has no line {line + 1}`, 0)
	end
	local from = 0
	for i = 1, line do
		from += #lines[i] + 1
	end
	core.file.write(path, text, { from = from, to = from + #lines[line + 1] })
end

--- Today's date, as notes write it: "2026-10-01".
function M.today(): string
	return core.dates.today()
end

--- The name of the daily note for `date` ("2026-10-01"; today by
--- default): "daily/2026-10-01", or as Obsidian's daily notes are set to
--- name it (`Daily/2026-10-01`, see `M.daily_folder`).
function M.daily(date: string?): string
	return day_name(date or M.today())
end

--- Makes today's daily note if there isn't one yet, and gives back its
--- path. It starts as its template says (the note `templates/daily`, or
--- the one Obsidian's daily notes are set to start from), with `{{date}}`
--- ("2026-10-18"), `{{day}}` ("Sunday 18 October"), `{{title}}` (the
--- note's name) and `{{time}}` filled in; or else with the date as its
--- heading.
function M.make_daily(): string
	local today = M.today()
	local name = M.daily(today)
	local path = M.path(name)
	if greed.fs.stat(path) == nil then
		local template_name = obsidian("daily-notes", "template")
		local template = M.read(
			if template_name
				then (string.gsub(trimmed_folder(template_name), "%.md$", ""))
				else `{M.templates_folder()}/daily`
		)
		core.file.write(path, if template then M.filled(template, name) else `# {today}\n\n`)
	end
	return path
end

--- `template`'s text for a new note `name`, its `{{date}}`
--- ("2026-10-18"), `{{day}}` ("Sunday 18 October"), `{{title}}` (the
--- note's name without its folders) and `{{time}}` filled in, as
--- Obsidian's templates have them.
function M.filled(template: string, name: string): string
	local clock = core.dates.clock()
	local values = {
		["{{date}}"] = M.today(),
		["{{day}}"] = os.date("%A %d %B", clock) :: string,
		["{{title}}"] = string.match(name, "([^/:]+)$") or name,
		["{{time}}"] = os.date("%H:%M", clock) :: string,
	}
	return (
		string.gsub(template, "{{%a+}}", function(found: string): string
			return values[found] or found
		end)
	)
end

export type Symbols = {
	todo: string,
	done: string,
	--- One for each heading level, the last for any deeper.
	headings: { string },
	bullet: string,
	due: string,
	remind: string,
	--- Before how often a line repeats.
	every: string,
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
		remind = "⏰",
		every = "↻",
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
--- and running the command `action` when clicked, if given. It goes when
--- the plugin (or config) that added it does.
function M.rule(rule: Rule)
	local remove = core.registry.put(M.look.rules, rule)
	M.look.changed()
	greed.plugin.tie(function()
		remove()
		M.look.changed()
	end)
end

return M
