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

-- The day a note last changed, nil when that isn't known.
local function modified_of(note: index.Note): string?
	return if note.modified > 0 then os.date("%Y-%m-%d", note.modified) :: string else nil
end

-- The day a note is about: a day's note's day, otherwise the day it last
-- changed.
local function date_of(note: index.Note): string?
	return string.match(note.name, "daily/(%d%d%d%d%-%d%d%-%d%d)$") or modified_of(note)
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
			return modified_of(item.note)
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

--- What an item is called where it's listed: a todo's plain words, a
--- heading's words, a note's title.
function M.label(item: Item): string
	local node = item.node
	if node == nil then
		return item.note.title
	end
	local task = node.task
	return if task then todos.plain(task.text) else node.text
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
		key = key_of,
		stored = STORED,
		name = function(item: Item)
			return if item.kind == "note" then item.note.name else nil
		end,
	}
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

-- The index of the notes' words: the file, the index once opened, the
-- notes changed since it was last written, and the keys each note put in.
local kept: {
	path: string?,
	index: greed.Index?,
	built: boolean,
	writing: boolean,
	changed: { [string]: boolean },
	keys: { [string]: { string } },
} =
	{ built = false, writing = false, changed = {}, keys = {} }

-- Where the index of these notes lives: Greed's cache folder, a file for
-- each set of places notes are in.
local function index_path(): string?
	local cache = greed.fs.dirs().cache
	if cache == nil then
		return nil
	end
	local folders = {}
	for _, place in notes.places() do
		table.insert(folders, `{place.name}={place.folder}`)
	end
	local id = string.sub(greed.hash.sha256(table.concat(folders, "\n")), 1, 16)
	return `{cache}/notes/{id}.db`
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
	local path = index_path()
	if path == nil then
		return nil
	end
	if kept.path ~= path then
		kept.path, kept.index, kept.built, kept.changed, kept.keys = path, nil, false, {}, {}
	end
	while kept.writing do
		greed.sleep(10)
	end
	local db = kept.index
	if db == nil then
		local opened, err = greed.index.writer(path)
		if opened == nil then
			greed.echo(`notes index: {err}`)
			return nil
		end
		db = opened
		kept.index = opened
	end
	local writing: greed.Index = db :: greed.Index
	kept.writing = true
	local ok, err = pcall(function()
		local source = M.source()
		local notes_now: { [string]: Item } = {}
		for _, item in M.items() do
			if item.kind == "note" then
				notes_now[item.note.name] = item
			end
		end
		-- The first time, everything, over what another session left there,
		-- read in the background; then what changed since.
		local texts: { [string]: string } = {}
		local names: { [string]: boolean } = kept.changed
		if not kept.built then
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
		if #fresh > 0 then
			writing:write(fresh)
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
	local by_key: { [string]: Item } = {}
	for _, item in M.items() do
		by_key[key_of(item)] = item
	end
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
-- words, its due date and its note.
local function row_of(item: Item): { [string]: any }
	local node = item.node
	local task = if node then node.task else nil
	local due = if task then FIELDS.due.get(item) else nil
	return {
		[""] = if task then (if todos.done_now(task.text, task.done) then "☑" else "☐") else "",
		what = M.label(item),
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
