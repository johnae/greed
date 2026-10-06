-- Todos are list items with a box: "- [ ] call the bank due:2026-10-03".
-- The agenda lists the open ones from every note, soonest due first;
-- capture adds one to the inbox note from anywhere.

local greed = require("@greed")
local picker = require("@picker")
local prompt = require("@core").prompt
local notes = require("./notes")

export type Todo = { note: string, line: number, text: string, done: boolean, due: string? }

local M = {}

--- The todo on `line` (a line of text), if it is one.
function M.parse(line: string): (boolean?, string?)
	local box, text = string.match(line, "^%s*[-*] %[([ xX])%] (.*)$")
	if box == nil then
		return nil, nil
	end
	return box ~= " ", text
end

--- When `text` says it's due ("due:2026-10-03"), if it does.
function M.due(text: string): string?
	return string.match(text, "due:(%d%d%d%d%-%d%d%-%d%d)")
end

--- Every todo in the notes, in every place, open ones only unless `all`,
--- soonest due first (undated last), then by note and line.
function M.list(all: boolean?): { Todo }
	local found = notes.grep("^\\s*[-*] \\[[ xX]\\] ") or {}
	local out: { Todo } = {}
	for _, line in found do
		local done, text = M.parse(line.text)
		if text and (all or not done) then
			table.insert(out, {
				note = line.note,
				line = line.line,
				text = text,
				done = done == true,
				due = M.due(text),
			})
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

--- Adds a todo to note `name` (the inbox by default).
function M.add(text: string, name: string?, due: string?)
	local line = `- [ ] {text}`
	if due then
		line ..= ` due:{due}`
	end
	notes.append(name or M.inbox(), line)
end

--- Adds a thought to note `name` (the inbox by default): a plain item with
--- today's date, for ideas that aren't things to do.
function M.add_thought(text: string, name: string?)
	notes.append(name or M.inbox(), `- {text} ({notes.today()})`)
end

local function open_at(name: string, line: number)
	greed.open(notes.path(name))
	local view = greed.view()
	local at = view:buffer():line_start(math.min(line, view:buffer():line_count() - 1))
	view:set_selection({ ranges = { { anchor = at, head = at } }, primary = 1 })
end

greed.command({
	name = "todo-toggle",
	doc = "Tick the todo on each selected line, or untick it; a plain line becomes a todo",
	run = function(ctx)
		local buffer = ctx.buffer
		local lines = require("@core").motions.selected_lines(ctx)
		buffer:edit(function(e)
			for _, line in lines do
				local start = buffer:line_start(line)
				local text = buffer:slice(start, buffer:line_end(line))
				local box_from = string.find(text, "%[[ xX]%]")
				local done = M.parse(text)
				if done ~= nil and box_from then
					e:replace(start + box_from, start + box_from + 1, if done then " " else "x")
				else
					local indent = string.match(text, "^%s*") :: string
					local rest = string.sub(text, #indent + 1)
					local item = string.match(rest, "^[-*] ") and "" or "- "
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
			open_at(todo.note, todo.line)
		end)
	end,
})

-- A todo, as capture adds one.
local function todo(text: string, name: string?)
	M.add(text, name)
end

-- Asks for a `what` (a todo, a thought) and adds it to note `inbox` with
-- `add`.
local function capture(inbox: string, what: string, add: (text: string, name: string?) -> ())
	prompt.open({
		title = `{what} for {inbox}`,
		on_submit = function(text)
			if string.match(text, "%S") then
				add(text, inbox)
				greed.echo(`added to {inbox}`)
			end
		end,
	})
end

greed.command({
	name = "notes-capture",
	doc = "Add a todo to the inbox note, from wherever you are: the project's when it keeps notes",
	run = function()
		capture(M.inbox(), "todo", todo)
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
		greed.open(path)
	end,
})

greed.command({
	name = "notes-find",
	doc = "Open a note by name",
	run = function()
		local items = {}
		for _, name in notes.all() do
			table.insert(items, { label = name, value = name })
		end
		picker.pick("Notes", items, function(item)
			greed.open(notes.path(item.value))
		end, {
			preview = function(item)
				return { text = notes.read(item.value) or "", language = "markdown" }
			end,
			-- A name that isn't a note yet makes one.
			fallback = function(query)
				greed.open(notes.path(query))
			end,
		})
	end,
})

greed.command({
	name = "notes-search",
	doc = "Search every note as you type",
	run = function()
		picker.pick("Search notes", {}, function(item)
			open_at(item.value.note, item.value.line)
		end, {
			source = function(query)
				local items = {}
				for _, line in notes.grep(query) or {} do
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
