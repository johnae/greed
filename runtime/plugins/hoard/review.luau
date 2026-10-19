-- Looking back: the weekly review, a note in reviews/ (`reviews/2026-W42`)
-- with what was done that week, what's overdue and coming, what has waited
-- a long time, the inbox, and what was written; and what the home brings
-- back from before (home.luau). Written from the notes' index, once a week:
-- what you add to the review stays.

local greed = require("@greed")
local core = require("@core")
local notes = require("@notes")

local index = notes.index
local todos = notes.todos
local dates = notes.dates
local links = notes.links

local M = {}

--- A todo as a review lists it: its note and line, and its words.
export type Item = { note: string, line: number, text: string, due: string? }

-- Whether note `name` is one the review itself makes, or a template.
local function own(name: string): boolean
	local _, rest = notes.split(name)
	return string.match(rest, "^reviews/") ~= nil or string.match(rest, "^templates/") ~= nil
end

-- Every open or done todo, with its note, for what `keep` says yes to.
local function items(keep: (task: notes.Task, note: notes.Note) -> boolean): { Item }
	local out: { Item } = {}
	for _, note in index.all() do
		if not own(note.name) then
			for _, node in note.nodes do
				local task = node.task
				if task and keep(task, note) then
					table.insert(out, {
						note = note.name,
						line = node.line,
						text = todos.plain(task.text),
						due = task.due,
					})
				end
			end
		end
	end
	table.sort(out, function(a: Item, b: Item): boolean
		if (a.due or "") ~= (b.due or "") then
			return (a.due or "") < (b.due or "")
		end
		return if a.note ~= b.note then a.note < b.note else a.line < b.line
	end)
	return out
end

--- Open todos without a date, not habits, in notes unchanged for
--- `todos.WAITING_DAYS` days or more (`todos.waiting`): the oldest notes
--- first, at most `limit`.
function M.waiting(limit: number?): { Item }
	local found = items(todos.waiting)
	local changed: { [string]: number } = {}
	for _, note in index.all() do
		changed[note.name] = note.modified
	end
	table.sort(found, function(a: Item, b: Item): boolean
		return changed[a.note] < changed[b.note]
	end)
	if limit and #found > limit then
		found = table.move(found, 1, limit, 1, {})
	end
	return found
end

--- How long ago note `name` was last changed, in words: "3 weeks".
function M.untouched(name: string): string
	local note = index.note(name)
	local days = if note then math.floor((notes.clock() - note.modified) / 86400) else 0
	if days >= 60 then
		return `{days // 30} months`
	end
	return if days >= 14 then `{days // 7} weeks` else `{days} days`
end

--- The review note for the week `date` is in (today's by default):
--- "reviews/2026-W42".
function M.name(date: string?): string
	local year, week = dates.week(date or notes.today())
	return string.format("reviews/%04d-W%02d", year, week)
end

-- A line for a todo in the review: its words and a link to its note.
local function line_of(item: Item, here: string): string
	local due = if item.due then `, due {dates.short(item.due)}` else ""
	return `- {item.text} ([[{links.written(item.note, here)}]]{due})`
end

--- What the review of the week `date` is in says (see the top of this
--- file).
function M.text(date: string?): string
	local today = date or notes.today()
	local _, week, monday = dates.week(today)
	local sunday = dates.add_days(monday, 6)
	local here = M.name(today)
	local out = { `# Week {week}: {dates.short(monday)} to {dates.short(sunday)}`, "" }
	local function part(title: string, lines: { string }, empty: string)
		table.insert(out, `## {title}`)
		table.insert(out, "")
		if #lines == 0 then
			table.insert(out, empty)
		end
		for _, line in lines do
			table.insert(out, line)
		end
		table.insert(out, "")
	end
	local function listed(found: { Item }): { string }
		local lines = {}
		for _, item in found do
			table.insert(lines, line_of(item, here))
		end
		return lines
	end

	part(
		"Done",
		listed(items(function(task)
			return task.done
				and task.done_on ~= nil
				and task.done_on >= monday
				and task.done_on <= sunday
		end)),
		"Nothing ticked off this week."
	)
	part(
		"Overdue",
		listed(items(function(task)
			local due = todos.due_on(task, today)
			return due ~= nil and due < today and not task.habit
		end)),
		"Nothing overdue."
	)
	local next_week = dates.add_days(today, 7)
	part(
		"Coming up",
		listed(items(function(task)
			local due = todos.due_on(task, today)
			return due ~= nil and due >= today and due <= next_week and not task.habit
		end)),
		"Nothing due in the next week."
	)
	local waiting = {}
	for _, item in M.waiting() do
		table.insert(waiting, `{line_of(item, here)}, untouched for {M.untouched(item.note)}`)
	end
	part("Waiting", waiting, "Nothing has waited long.")
	local inbox = items(function(task, note)
		return not task.done and note.name == todos.inbox()
	end)
	part("Inbox", listed(inbox), "The inbox is empty.")

	-- What was written: each day's note, then the other notes changed.
	local written = {}
	for n = 0, 6 do
		local daily = notes.daily(dates.add_days(monday, n))
		if index.note(daily) then
			table.insert(written, `- [[{links.written(daily, here)}]]`)
		end
	end
	local from = dates.moment(monday, "00:00") or 0
	local to = (dates.moment(sunday, "23:59") or 0) + 60
	local changed = {}
	for _, note in index.all() do
		local _, rest = notes.split(note.name)
		if
			note.modified >= from
			and note.modified < to
			and not own(note.name)
			and not string.match(rest, "^daily/")
		then
			table.insert(changed, note.name)
		end
	end
	table.sort(changed)
	for _, name in changed do
		table.insert(written, `- [[{links.written(name, here)}]]`)
	end
	part("Written", written, "Nothing written this week.")
	part("Thoughts", { "- " }, "")
	return table.concat(out, "\n")
end

--- Opens the review of this week, writing it first if it isn't there yet.
function M.open()
	index.ensure()
	local name = M.name()
	local path = notes.path(name)
	if greed.fs.stat(path) == nil then
		core.file.write(path, M.text())
	end
	core.file.open(path)
end

greed.command({
	name = "hoard-review",
	doc = "Look back at the week: what was done, what's overdue, coming and waiting, the inbox "
		.. "and what was written, in a note of its own",
	run = function()
		M.open()
	end,
})

greed.keymap.bind({ layer = "leader" }, { ["n w"] = "hoard-review" })

return M
