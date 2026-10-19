-- Notes as a source for the query language (core.query): each note, each
-- todo and each heading is an item, todos and headings under their note,
-- so a query can ask for any of them, and `in:` and `has:` say where.
--
--     is:todo -is:done due:..+7d in:(tag:garden) sort:due
--     is:note tag:meeting has:(is:todo is:open)
--     is:overdue OR is:waiting
--
-- Fields: `title`, `note` (its name), `tag` (a todo has its note's too),
-- `due`, `done` (the day it was done), `starts` and `until` (a repeat's),
-- `every`, `date` (a day's note's day, or when a note last changed),
-- `modified`, and every `key:: value` field and front matter key in the
-- notes. Flags: what an item is (`note`, `todo`, `heading`), `done` and
-- `open`, and what depends on today: `overdue`, `today` (due today, or
-- written in today's note without a date, as the agenda has it),
-- `due-today`, `habit`, `recurring` and `waiting`. A `notes` block in a
-- note shows what its query finds (below).

local core = require("@core")
local notes = require("./notes")
local index = require("./index")
local todos = require("./todos")

local dates = core.dates
local query = core.query

local M = {}

--- An item a query runs over: a note, or a todo or heading in one.
export type Item = {
	kind: "note" | "todo" | "heading",
	note: index.Note,
	node: index.Node?,
	--- The note's item, for a todo or heading.
	parent: Item?,
	--- A note's todos and headings.
	children: { Item },
}

-- The items, made again after the notes change.
local made: { Item }? = nil

index.on_changed(function()
	made = nil
end)

--- Every note, todo and heading as items (see the top of this file).
function M.items(): { Item }
	local cached = made
	if cached then
		return cached
	end
	index.ensure()
	local out: { Item } = {}
	for _, note in index.all() do
		local item: Item = { kind = "note", note = note, children = {} }
		table.insert(out, item)
		for _, node in note.nodes do
			local kind: "todo" | "heading"? = if node.task
				then "todo"
				elseif node.kind == "heading" then "heading"
				else nil
			if kind then
				local child: Item = {
					kind = kind,
					note = note,
					node = node,
					parent = item,
					children = {},
				}
				table.insert(item.children, child)
				table.insert(out, child)
			end
		end
	end
	made = out
	return out
end

-- The day a note is about: a day's note's day, otherwise the day it last
-- changed.
local function date_of(note: index.Note): string?
	local day = string.match(note.name, "daily/(%d%d%d%d%-%d%d%-%d%d)$")
	if day then
		return day
	end
	return if note.modified > 0 then os.date("%Y-%m-%d", note.modified) :: string else nil
end

-- A todo's or heading's own tags and its note's; a note's own.
local function tags_of(item: Item): { string }
	local tags: { string } = {}
	for tag in item.note.tags do
		table.insert(tags, tag)
	end
	local node = item.node
	if node then
		for _, tag in node.tags do
			if not item.note.tags[tag] then
				table.insert(tags, tag)
			end
		end
	end
	return tags
end

local function task_of(item: Item): index.Task?
	local node = item.node
	return if node then node.task else nil
end

-- A field of the todo an item is, nil for anything else.
local function of_task(get: (task: index.Task) -> string?): (item: Item) -> string?
	return function(item: Item): string?
		local task = task_of(item)
		return if task then get(task) else nil
	end
end

-- The fields every source of notes has; `key:: value` fields and front
-- matter keys are added per query (see `M.source`).
local FIELDS: { [string]: core.QueryField } = {
	title = {
		kind = "text",
		get = function(item: Item)
			return item.note.title
		end,
	},
	note = {
		kind = "exact",
		get = function(item: Item)
			return item.note.name
		end,
	},
	tag = { kind = "exact", get = tags_of },
	due = {
		kind = "date",
		ahead = true,
		get = function(item: Item)
			local task = task_of(item)
			return if task then todos.due_on(task, dates.today()) or task.due else nil
		end,
	},
	done = {
		kind = "date",
		get = of_task(function(task)
			return task.done_on
		end),
	},
	starts = {
		kind = "date",
		get = of_task(function(task)
			return task.starts
		end),
	},
	["until"] = {
		kind = "date",
		ahead = true,
		get = of_task(function(task)
			return task.ends
		end),
	},
	every = {
		kind = "exact",
		get = of_task(function(task)
			return task.every
		end),
	},
	date = {
		kind = "date",
		get = function(item: Item)
			return date_of(item.note)
		end,
	},
	modified = {
		kind = "date",
		get = function(item: Item)
			local modified = item.note.modified
			return if modified > 0 then os.date("%Y-%m-%d", modified) :: string else nil
		end,
	},
}

-- What an open todo is as of today, for the flags that depend on it.
local function due_today(item: Item): string?
	local task = task_of(item)
	return if task then todos.due_on(task, dates.today()) else nil
end

local FLAGS: { [string]: (item: any) -> boolean } = {
	note = function(item: Item)
		return item.kind == "note"
	end,
	todo = function(item: Item)
		return item.kind == "todo"
	end,
	heading = function(item: Item)
		return item.kind == "heading"
	end,
	done = function(item: Item)
		local task = task_of(item)
		return task ~= nil and todos.done_now(task.text, task.done)
	end,
	open = function(item: Item)
		local task = task_of(item)
		return task ~= nil and not todos.done_now(task.text, task.done)
	end,
	overdue = function(item: Item)
		local due = due_today(item)
		return due ~= nil and due < dates.today()
	end,
	["due-today"] = function(item: Item)
		return due_today(item) == dates.today()
	end,
	today = function(item: Item)
		local task = task_of(item)
		if task == nil or task.done then
			return false
		end
		local due = todos.due_on(task, dates.today())
		return due == dates.today()
			or (due == nil and not task.habit and item.note.name == notes.daily())
	end,
	habit = function(item: Item)
		local task = task_of(item)
		return task ~= nil and task.habit
	end,
	recurring = function(item: Item)
		local task = task_of(item)
		return task ~= nil and task.every ~= nil
	end,
	waiting = function(item: Item)
		local task = task_of(item)
		return task ~= nil and todos.waiting(task, item.note)
	end,
}

-- The words of an item: a note's title and what's in it, a todo's or a
-- heading's own words.
local function text_of(item: Item): string
	local node = item.node
	if node then
		local task = node.task
		return if task then todos.plain(task.text) else node.text
	end
	local parts = { item.note.title }
	for _, child in item.note.nodes do
		table.insert(parts, child.text)
	end
	return table.concat(parts, "\n")
end

--- The source a query runs over notes with: the fields above, and the
--- `key:: value` fields and front matter keys the notes have now.
function M.source(): core.QuerySource
	local fields = table.clone(FIELDS)
	for _, note in index.all() do
		for key in note.fields do
			local name = string.lower(key)
			if fields[name] == nil then
				fields[name] = {
					kind = "text",
					get = function(item: Item)
						local node = item.node
						local own = if node then node.fields[name] else nil
						return own or item.note.fields[name]
					end,
				}
			end
		end
	end
	return {
		fields = fields,
		flags = FLAGS,
		text = text_of,
		parent = function(item: Item)
			return item.parent
		end,
		children = function(item: Item)
			return item.children
		end,
		name = function(item: Item)
			return if item.kind == "note" then item.note.name else nil
		end,
	}
end

--- Runs `text` over the notes: the items it finds, in the order it asks
--- for, and its hints; or nil and its problems, each with where it is in
--- the text.
function M.run(text: string): ({ Item }?, { core.QueryProblem })
	local parsed = query.parse(text)
	local source = M.source()
	local said = table.clone(parsed.problems)
	local checked = query.check(parsed, source)
	table.move(checked, 1, #checked, #said + 1, said)
	local hints: { core.QueryProblem } = {}
	local wrong: { core.QueryProblem } = {}
	for _, problem in said do
		table.insert(if problem.hint then hints else wrong, problem)
	end
	if #wrong > 0 then
		return nil, wrong
	end
	local found, err = query.run(parsed, M.items(), source)
	if found == nil then
		return nil,
			{
				{ message = err or "the query couldn't run", at = { from = 1, to = #text + 1 } } :: any,
			}
	end
	return found, hints
end

-- What a block of notes' items shows: whether it's done (for a todo), its
-- words, its due date and its note.
local function row_of(item: Item): { [string]: any }
	local node = item.node
	local task = if node then node.task else nil
	local due = if task then FIELDS.due.get(item) else nil
	return {
		[""] = if task then (if todos.done_now(task.text, task.done) then "☑" else "☐") else "",
		what = if task then todos.plain(task.text) elseif node then node.text else item.note.title,
		due = if type(due) == "string" then dates.short(due) else nil,
		note = item.note.name,
	}
end

-- Those watching what a block of notes shows, told when the notes change.
local watching: { () -> () } = {}

index.on_changed(function()
	for _, changed in table.clone(watching) do
		changed()
	end
end)

-- A Markdown block of notes, its query the block's text, shows what it
-- finds, as the data plugin draws a table, and again as the notes change:
--
--     ```notes
--     is:todo is:open due:..+7d sort:due
--     ```
core.data.source({
	name = "notes",
	doc = "Your notes, todos and headings a query finds, like is:todo is:open due:..+7d",
	read = function(ask: core.DataAsk): (core.DataTable?, string?)
		local text = string.gsub(ask.body, "%s+", " ")
		local found, problems = M.run(text)
		if found == nil then
			return nil, if problems[1] then problems[1].message else "the query couldn't run"
		end
		local from = (ask.offset or 0) + 1
		local last = if ask.limit then math.min(#found, from + ask.limit - 1) else #found
		local rows = {}
		for i = from, last do
			table.insert(rows, row_of(found[i]))
		end
		return {
			columns = {
				{ name = "" },
				{ name = "what" },
				{ name = "due" },
				{ name = "note" },
			},
			rows = rows,
			more = last < #found,
		},
			nil
	end,
	watch = function(_, changed: () -> ()): () -> ()
		return core.registry.put(watching, changed)
	end,
})

return M
