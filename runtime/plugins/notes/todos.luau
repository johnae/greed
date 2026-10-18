-- Todos are list items with a box: "- [ ] call the bank due:2026-10-03",
-- maybe with reminders, "remind:2026-10-02 18:00", as many as you like
-- (see reminders.luau).
-- The agenda lists the open ones from every note, soonest due first;
-- capture adds one to the inbox note from anywhere.

local greed = require("@greed")
local picker = require("@picker")
local core = require("@core")
local prompt = core.prompt
local notes = require("./notes")
local syntax = require("./syntax")
local index = require("./index")

type Found = notes.Found

export type Todo = {
	note: string,
	line: number,
	text: string,
	done: boolean,
	due: string?,
	--- When it reminds you, each "2026-10-06 18:00" or a date alone.
	reminds: { string },
}

export type Reminder = syntax.Reminder

local M = {}

-- Reading a todo's line, kept in syntax.luau with the rest of what notes
-- say on a line.
M.parse = syntax.parse
M.due = syntax.due
M.marker = syntax.marker
M.reminders = syntax.reminders
M.reminds = syntax.reminds
M.with_reminds = syntax.with_reminds
M.with_due = syntax.with_due
M.plain = syntax.plain

--- The todo on line `line` (0-based) of note `note`, whose text is
--- `text`, if that line is one.
function M.at(note: string, line: number, text: string): Todo?
	local done, rest = M.parse(text)
	if rest == nil then
		return nil
	end
	return {
		note = note,
		line = line,
		text = rest,
		done = done == true,
		due = M.due(rest),
		reminds = M.reminds(rest),
	}
end

--- Every todo in the notes, in every place, open ones only unless `all`,
--- soonest due first (undated last), then by note and line.
function M.list(all: boolean?): { Todo }
	index.ensure()
	local out: { Todo } = {}
	for _, note in index.all() do
		for _, node in note.nodes do
			local task = node.task
			if task and (all or not task.done) then
				table.insert(out, {
					note = note.name,
					line = node.line,
					text = task.text,
					done = task.done,
					due = task.due,
					reminds = table.clone(task.reminds),
				})
			end
		end
	end
	table.sort(out, function(a: Todo, b: Todo)
		local da, db = a.due or "9999", b.due or "9999"
		if da ~= db then
			return da < db
		elseif a.note ~= b.note then
			return a.note < b.note
		end
		return a.line < b.line
	end)
	return out
end

--- The inbox todos are captured to: the project's, when it keeps notes
--- (its notes folder is there), otherwise yours.
function M.inbox(): string
	if greed.fs.stat(notes.project_folder()) and notes.place("project") then
		return "project:inbox"
	end
	return "inbox"
end

--- Adds a todo to note `name` (the inbox by default), due on `due` and
--- reminding you at each of `reminds` ("2026-10-06 18:00") if given.
function M.add(text: string, name: string?, due: string?, reminds: { string }?)
	local line = `- [ ] {text}`
	if due then
		line ..= ` due:{due}`
	end
	notes.append(name or M.inbox(), M.with_reminds(line, reminds or {}))
end

--- Adds a thought to note `name` (the inbox by default): a plain item with
--- today's date, for ideas that aren't things to do.
function M.add_thought(text: string, name: string?)
	notes.append(name or M.inbox(), `- {text} ({notes.today()})`)
end

--- Opens note `name` with the cursor at the start of `line` (0-based).
function M.open_at(name: string, line: number)
	core.file.open_at(notes.path(name), line)
end

greed.command({
	name = "todo-toggle",
	doc = "Tick the todo on each selected line, or untick it; a plain line becomes a todo",
	run = function(ctx)
		local buffer = ctx.buffer
		local lines = core.motions.selected_lines(ctx)
		buffer:edit(function(e)
			for _, line in lines do
				local start = buffer:line_start(line)
				local text = buffer:line_text(line)
				local box_from = string.find(text, "%[[ xX]%]")
				local done = M.parse(text)
				if done ~= nil and box_from then
					e:replace(start + box_from, start + box_from + 1, if done then " " else "x")
				else
					local indent = string.match(text, "^%s*") :: string
					local rest = string.sub(text, #indent + 1)
					local item = string.match(rest, "^[-*+] ") and "" or "- "
					local bullet = if item == "" then 2 else 0
					e:insert(start + #indent + bullet, item .. "[ ] ")
				end
			end
		end)
	end,
})

greed.command({
	name = "notes-agenda",
	doc = "Pick from the open todos in every note, soonest due first",
	run = function()
		local items = {}
		for _, todo in M.list() do
			local due = if todo.due then `{todo.due}  ` else ""
			table.insert(items, { label = `{due}{todo.text}  ({todo.note})`, value = todo })
		end
		if #items == 0 then
			greed.echo("nothing to do")
			return
		end
		picker.pick("Agenda", items, function(item)
			local todo = item.value :: Todo
			M.open_at(todo.note, todo.line)
		end)
	end,
})

-- A todo, as capture adds one.
local function todo(text: string, name: string?)
	M.add(text, name)
end

-- Adds `text` to note `inbox` with `add`, or asks for a `what` (a todo, a
-- thought) to add when there's no text.
local function capture(
	inbox: string,
	what: string,
	add: (text: string, name: string?) -> (),
	text: string?
)
	local function take(typed: string)
		if string.match(typed, "%S") then
			add(typed, inbox)
			greed.echo(`added to {inbox}`)
		end
	end
	if text then
		take(text)
		return
	end
	prompt.open({ title = `{what} for {inbox}`, on_submit = take })
end

greed.command({
	name = "notes-capture",
	doc = "Add a todo to the inbox note, from wherever you are: the project's when it keeps notes",
	args = {
		{
			name = "text",
			doc = "The todo; asked for when left out",
			type = "rest",
			optional = true,
		},
	},
	run = function(ctx)
		capture(M.inbox(), "todo", todo, ctx.values.text)
	end,
})

greed.command({
	name = "notes-thought",
	doc = "Jot a thought or an idea down in the inbox note, with today's date, from wherever you are",
	run = function()
		capture(M.inbox(), "thought", M.add_thought)
	end,
})

greed.command({
	name = "notes-capture-mine",
	doc = "Add a todo to your own inbox note, even in a project that keeps notes",
	run = function()
		capture("inbox", "todo", todo)
	end,
})

greed.command({
	name = "notes-daily",
	doc = "Open today's note, making it if there isn't one",
	run = function()
		local today = notes.today()
		local path = notes.path(`daily/{today}`)
		if greed.fs.stat(path) == nil then
			greed.fs.write(path, `# {today}\n\n`)
		end
		core.file.open(path)
	end,
})

greed.command({
	name = "notes-find",
	doc = "Open a note by name, or pick one",
	args = { { name = "note", doc = "The note", type = "object", kind = "note", optional = true } },
	run = function(ctx)
		local note: core.Object? = ctx.values.note
		if note then
			core.file.open(notes.path(note.value))
			return
		end
		local items = {}
		for _, name in notes.all() do
			table.insert(items, { label = name, value = name })
		end
		picker.pick("Notes", items, function(item)
			core.file.open(notes.path(item.value))
		end, {
			preview = function(item)
				return { text = notes.read(item.value) or "", language = "markdown" }
			end,
			-- A name that isn't a note yet makes one.
			fallback = function(query)
				core.file.open(notes.path(query))
			end,
		})
	end,
})

core.search.kind("notes", "ignore", "searching notes")

greed.command({
	name = "notes-search",
	doc = "Search every note as you type",
	run = function()
		picker.pick("Search notes", {}, function(item)
			M.open_at(item.value.note, item.value.line)
		end, {
			source = function(query)
				local items = {}
				local found: { Found } = notes.grep(core.search.pattern(query, "notes")) or {}
				for _, line in found do
					table.insert(items, {
						label = `{line.note}:{line.line + 1}: {line.text}`,
						value = { note = line.note, line = line.line },
					})
				end
				return items
			end,
		})
	end,
})

return M
