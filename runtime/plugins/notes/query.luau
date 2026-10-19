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
-- `every`, `date` (front matter's `date:`, a day's note's day, or when a
-- note last changed), `modified`, and every `key:: value` field and front
-- matter key in the notes (a list's each value, a link as its note).
-- Flags: what an item is (`note`, `todo`, `heading`), `done` and `open`,
-- and what depends on today: `overdue`, `today` (due today, or
-- written in today's note without a date, as the agenda has it),
-- `due-today`, `habit`, `recurring` and `waiting`. A `notes` block in a
-- note shows what its query finds (below).

local greed = require("@greed")
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
	--- A note's whole text, while it's put in the index.
	body: string?,
	--- A note's todos and headings.
	children: { Item },
}

-- The items, the source with the notes' own fields, and the items by
-- their key, each made again after the notes change.
local made: { Item }? = nil
local made_source: core.QuerySource? = nil
local made_keys: { [string]: Item }? = nil

index.on_changed(function()
	made = nil
	made_source = nil
	made_keys = nil
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
		index.breathe()
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

-- Each note's days, as worked out for its `modified` time: its todos and
-- headings ask for them too, tens of thousands of times in a big index.
type Days = { at: number, modified: string?, date: string? }
local days: { [index.Note]: Days } = setmetatable({}, { __mode = "k" }) :: any

-- The day a note last changed (nil when that isn't known), and the day
-- it's about: the `date:` its front matter says, a day's note's day, or
-- otherwise the day it last changed.
local function days_of(note: index.Note): Days
	local known = days[note]
	if known and known.at == note.modified then
		return known
	end
	local modified = if note.modified > 0 then os.date("%Y-%m-%d", note.modified) :: string else nil
	local said = note.front.date
	local said_day = if type(said) == "string"
		then string.match(said, "^%d%d%d%d%-%d%d%-%d%d")
		else nil
	local found: Days = {
		at = note.modified,
		modified = modified,
		date = said_day or string.match(note.name, "daily/(%d%d%d%d%-%d%d%-%d%d)$") or modified,
	}
	days[note] = found
	return found
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
			return days_of(item.note).date
		end,
	},
	modified = {
		kind = "date",
		get = function(item: Item)
			return days_of(item.note).modified
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
		local due = due_today(item)
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

--- What an item is called where it's listed: a todo's plain words (as the
--- index read them, without dates and markers), a heading's words, a
--- note's title.
function M.label(item: Item): string
	local node = item.node
	return if node then node.text else item.note.title
end

-- The words of an item: a note's title and what's in it (all of it, going
-- in the index), a todo's or a heading's own words.
local function text_of(item: Item): string
	if item.node then
		return M.label(item)
	end
	if item.body then
		return `{item.note.title}\n{item.body}`
	end
	local parts = { item.note.title }
	for _, child in item.note.nodes do
		table.insert(parts, child.text)
	end
	return table.concat(parts, "\n")
end

-- What an item goes by in the index: its note's name, and the line of a
-- todo or heading in it.
local function key_of(item: Item): string
	local node = item.node
	return if node then `{item.note.name}#{node.line}` else item.note.name
end

-- The flags kept in the index; the others depend on today (a habit is done
-- for today only), so they're worked out as a query runs.
local STORED = { "note", "todo", "heading", "habit", "recurring" }

-- A field's value as a query reads it: a link (`"[[Steph Ango]]"`, as
-- Obsidian's properties have them) as the note it names.
local function plain_value(value: string): string
	return string.match(value, "^%[%[([^%]|#]*)") or value
end

--- The source a query runs over notes with: the fields above, and the
--- `key:: value` fields and front matter keys the notes have now, a list
--- in front matter (`genre: ["[[Sci-fi]]", ...]`) as each of its values.
function M.source(): core.QuerySource
	local cached = made_source
	if cached then
		return cached
	end
	local fields = table.clone(FIELDS)
	local function add(name: string)
		if fields[name] ~= nil then
			return
		end
		fields[name] = {
			kind = "text",
			get = function(item: Item): string | { string } | nil
				local node = item.node
				local own = if node then node.fields[name] else nil
				local value = own or item.note.fields[name]
				if value then
					return plain_value(value)
				end
				local list = item.note.front[name]
				if type(list) ~= "table" then
					return nil
				end
				local out: { string } = {}
				for _, each in list do
					table.insert(out, plain_value(each))
				end
				return out
			end,
		}
	end
	for _, note in index.all() do
		for key in note.fields do
			add(string.lower(key))
		end
		for key in note.front do
			add(key)
		end
	end
	local source: core.QuerySource = {
		fields = fields,
		flags = FLAGS,
		text = text_of,
		parent = function(item: Item)
			return item.parent
		end,
		children = function(item: Item)
			return item.children
		end,
		key = key_of,
		stored = STORED,
		name = function(item: Item)
			return if item.kind == "note" then item.note.name else nil
		end,
	}
	made_source = source
	return source
end

-- The items by their key in the index.
local function keyed(): { [string]: Item }
	local cached = made_keys
	if cached then
		return cached
	end
	local out: { [string]: Item } = {}
	for _, item in M.items() do
		index.breathe()
		out[key_of(item)] = item
	end
	made_keys = out
	return out
end

-- Parses and checks `text` against the notes' source: the query, the
-- source, its hints and its mistakes.
local function parse(
	text: string,
	typing: boolean?
): (core.Query, core.QuerySource, { core.QueryProblem }, { core.QueryProblem })
	local parsed = query.parse(text, { typing = typing })
	local source = M.source()
	local said = table.clone(parsed.problems)
	local checked = query.check(parsed, source)
	table.move(checked, 1, #checked, #said + 1, said)
	local hints: { core.QueryProblem } = {}
	local wrong: { core.QueryProblem } = {}
	for _, problem in said do
		table.insert(if problem.hint then hints else wrong, problem)
	end
	return parsed, source, hints, wrong
end

-- A problem with the whole of `text`.
local function whole(text: string, message: string): { core.QueryProblem }
	return { { message = message, at = { from = 1, to = #text + 1 } } }
end

--- Runs `text` over the notes: the items it finds, in the order it asks
--- for, and its hints; or nil and its problems, each with where it is in
--- the text.
function M.run(text: string): ({ Item }?, { core.QueryProblem })
	local parsed, source, hints, wrong = parse(text)
	if #wrong > 0 then
		return nil, wrong
	end
	local found, err = query.run(parsed, M.items(), source)
	if found == nil then
		return nil, whole(text, err or "the query couldn't run")
	end
	return found, hints
end

--- How many items go to the index in one write.
M.BATCH = 2000

-- The index of the notes' words: the folder it's in, the index once opened,
-- the notes changed since it was last written, the keys each note put in,
-- and whether saving them is waiting to happen.
local kept: {
	dir: string?,
	index: greed.Index?,
	built: boolean,
	writing: boolean,
	saving: boolean,
	changed: { [string]: boolean },
	keys: { [string]: { string } },
} =
	{ built = false, writing = false, saving = false, changed = {}, keys = {} }

-- What the index was written from, saved beside it for the next session:
-- each note's name, its file as it was read, and the keys it put in.
type Saved = { name: string, modified: number, size: number, keys: { string } }

-- Saves what the index holds a moment after it's written, like the notes'
-- own index (`index.SAVE_AFTER`). Notes being edited are saved as unread,
-- as their files don't say what the index does yet.
local function save_later()
	if kept.saving then
		return
	end
	kept.saving = true
	greed.spawn(function()
		greed.sleep(index.SAVE_AFTER)
		kept.saving = false
		local saved: { Saved } = {}
		for name, keys in kept.keys do
			index.breathe()
			local note = index.note(name)
			if note then
				table.insert(saved, {
					name = name,
					modified = if index.editing(note.path) then -1 else note.modified,
					size = note.size,
					keys = keys,
				})
			end
		end
		local ok, err = index.save("words", saved)
		if not ok then
			greed.echo(`notes index: saving: {err}`)
		end
	end)
end

-- The names of the notes to write to an index that holds what `saved`
-- says: those new or changed since, and those gone. What's unchanged
-- keeps its keys.
local function changed_since(saved: { Saved }, notes_now: { [string]: Item }): { [string]: boolean }
	local names: { [string]: boolean } = {}
	for name in notes_now do
		names[name] = true
	end
	for _, was in saved do
		kept.keys[was.name] = was.keys
		local item = notes_now[was.name]
		if
			item
			and was.modified ~= -1
			and item.note.modified == was.modified
			and item.note.size == was.size
		then
			names[was.name] = nil
		else
			names[was.name] = true
		end
	end
	return names
end

-- A note's item and its todos and headings as the index keeps them, and
-- their keys; `text` is the note's, when it's read already.
local function index_items(item: Item, source: core.QuerySource, text: string?): { greed.IndexItem }
	local list = { item }
	for _, child in item.children do
		table.insert(list, child)
	end
	item.body = text or notes.read(item.note.name)
	local written = query.index_items(list, source)
	item.body = nil
	return written
end

-- The index, written whole the first time in a session and then note by
-- note as notes change; nil where there's no cache folder. Waits like
-- greed.sleep.
local function index_now(): greed.Index?
	local dir = index.cache_dir()
	if dir == nil then
		return nil
	end
	if kept.dir ~= dir then
		kept.dir, kept.index, kept.built, kept.changed, kept.keys = dir, nil, false, {}, {}
	end
	while kept.writing do
		greed.sleep(10)
	end
	local path = `{dir}/words.db`
	-- What an earlier session left, if it's for this build and the index
	-- it describes is still there.
	local saved = if kept.built then nil else index.load("words") :: { Saved }?
	local db = kept.index
	if db == nil then
		if saved == nil then
			for _, file in { path, `{path}-wal`, `{path}-shm` } do
				greed.fs.remove(file)
			end
		end
		local opened, err = greed.index.writer(path)
		if opened == nil then
			greed.echo(`notes index: {err}`)
			return nil
		end
		db = opened
		kept.index = opened
	end
	local writing: greed.Index = db :: greed.Index
	if saved and (writing:count() or 0) == 0 then
		saved = nil
	end
	kept.writing = true
	local ok, err = pcall(function()
		local source = M.source()
		local notes_now: { [string]: Item } = {}
		for _, item in M.items() do
			if item.kind == "note" then
				notes_now[item.note.name] = item
			end
		end
		-- The first time, what changed since the last session saved the
		-- index, or else everything, read in the background; then what
		-- changed since.
		local texts: { [string]: string } = {}
		local names: { [string]: boolean } = kept.changed
		if saved then
			names = changed_since(saved, notes_now)
		elseif not kept.built then
			names = {}
			for name in notes_now do
				names[name] = true
			end
			for _, place in notes.places() do
				if greed.fs.stat(place.folder) then
					for _, file in greed.fs.scan(place.folder, { ext = "md", read = true }) do
						local path = `{place.folder}/{file.path}`
						-- An open note's buffer may say more than its file.
						if file.text and greed.buffer_for(path) == nil then
							texts[notes.name(path)] = file.text
						end
					end
				end
			end
		end
		kept.changed = {}
		-- What changed goes out, and in again as it is now, in one go each.
		local gone: { string } = {}
		local fresh: { greed.IndexItem } = {}
		for name in names do
			index.breathe()
			for _, key in kept.keys[name] or {} :: { string } do
				table.insert(gone, key)
			end
			kept.keys[name] = nil
			local item = notes_now[name]
			if item then
				local keys = {}
				for _, written in index_items(item, source, texts[name]) do
					table.insert(fresh, written)
					table.insert(keys, written.key)
				end
				kept.keys[name] = keys
			end
		end
		if #gone > 0 then
			writing:remove(gone)
		end
		-- In batches, so handing them over never holds the editor up long.
		for first = 1, #fresh, M.BATCH do
			writing:write(table.move(fresh, first, math.min(first + M.BATCH - 1, #fresh), 1, {}))
			index.breathe()
		end
		if not kept.built or next(names) then
			save_later()
		end
		kept.built = true
	end)
	kept.writing = false
	if not ok then
		greed.echo(`notes index: {err}`)
	end
	return db
end

index.on_changed(function(name: string)
	kept.changed[name] = true
end)

--- Searches the notes' words and fields with `text` (a query, typed so
--- far when `typing`): the items it finds, best first, at most `limit`;
--- or nil and its problems. It reads the index of the notes, writing it
--- first if it isn't yet, so it waits like greed.sleep.
function M.search(
	text: string,
	limit: number?,
	typing: boolean?
): ({ Item }?, { core.QueryProblem })
	local parsed, source, _, wrong = parse(text, typing)
	if #wrong > 0 then
		return nil, wrong
	end
	local index = index_now()
	if index == nil then
		return M.run(text)
	end
	local keys, maybe, err = query.search(index, parsed, source)
	if keys == nil then
		return nil, whole(text, err or "the search couldn't run")
	end
	local by_key = keyed()
	-- Those that only might match are checked here, where today is known.
	local ruled_out: { [string]: boolean } = {}
	if maybe and #maybe > 0 then
		local candidates = {}
		for _, key in maybe do
			local item = by_key[key]
			if item then
				table.insert(candidates, item)
			end
		end
		local matched: { [string]: boolean } = {}
		local sure: { any } = query.run(parsed, candidates, source) or {}
		for _, item in sure do
			matched[key_of(item)] = true
		end
		for _, key in maybe do
			if not matched[key] then
				ruled_out[key] = true
			end
		end
	end
	local out: { Item } = {}
	for _, key in keys do
		local item = by_key[key]
		if item and not ruled_out[key] then
			table.insert(out, item)
			if limit and #out >= limit then
				break
			end
		end
	end
	return out, {}
end

-- What a block of notes' items shows: whether it's done (for a todo), its
-- words, its due date and its note; and, for its actions, the line it's
-- on and whether it's a todo that's done.
local function row_of(item: Item): { [string]: any }
	local node = item.node
	local task = if node then node.task else nil
	local due = if task then FIELDS.due.get(item) else nil
	local done = task ~= nil and todos.done_now(task.text, task.done)
	return {
		[""] = if task then (if done then "☑" else "☐") else "",
		what = M.label(item),
		due = if type(due) == "string" then dates.short(due) else nil,
		note = item.note.name,
		line = if node then node.line else nil,
		todo = task ~= nil,
		done = done,
	}
end

-- What can be done with a row of a block of notes: tick a todo off (or
-- tick it again), and open the note where it is. The data plugin runs
-- them, so they're notes' own doing (`greed.vouch`): ticking only changes
-- a todo's box, and fails on a line that isn't one.
local ACTIONS: { core.DataAction } = {
	{
		name = "Tick or untick",
		run = function(row: { [string]: any }): string?
			if not row.todo then
				return "only a todo has a box to tick"
			end
			local change: todos.Change = { done = not row.done }
			greed.vouch(todos.update, row.note, row.line, change)
			return if row.done then `{row.what}: not done` else `{row.what}: done`
		end,
	},
	{
		name = "Open",
		close = true,
		run = function(row: { [string]: any }): string?
			greed.vouch(function()
				if row.line then
					todos.open_at(row.note, row.line)
				else
					core.file.open(notes.path(row.note))
				end
			end)
			return nil
		end,
	},
}

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
	actions = ACTIONS,
})

return M
