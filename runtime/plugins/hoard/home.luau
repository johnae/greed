-- Hoard's home: what notes open to. A search over every note, boxes to add
-- a todo or jot something down in today's note, today's note itself, the
-- agenda (overdue, due today and in the next days, with boxes to tick),
-- what waits in the inbox and the notes you were in lately. It's drawn
-- from the notes' index, and drawn again as the notes change.

local greed = require("@greed")
local core = require("@core")
local notes = require("@notes")

local ui = core.ui
local index = notes.index
local todos = notes.todos
local dates = notes.dates

local M = {}

--- How many days ahead the agenda looks, after today.
M.DAYS_AHEAD = 7

--- How many recent notes are listed, and search results.
M.RECENT = 8
M.FOUND = 12

-- A todo as the home shows it.
type Task = { note: string, line: number, text: string, due: string }

-- The open todos due up to `M.DAYS_AHEAD` days from now: those overdue,
-- due today and coming, each soonest first.
local function agenda(): ({ Task }, { Task }, { Task })
	local today = notes.today()
	local last = os.date("%Y-%m-%d", notes.clock() + M.DAYS_AHEAD * 86400) :: string
	local overdue, now, coming = {}, {}, {}
	for _, note in index.all() do
		for _, node in note.nodes do
			local task = node.task
			local due = if task and not task.done then task.due else nil
			if task and due and due <= last then
				local item: Task = {
					note = note.name,
					line = node.line,
					text = todos.plain(task.text),
					due = due,
				}
				table.insert(
					if due < today then overdue elseif due == today then now else coming,
					item
				)
			end
		end
	end
	local function soonest(a: Task, b: Task): boolean
		if a.due ~= b.due then
			return a.due < b.due
		end
		return if a.note ~= b.note then a.note < b.note else a.line < b.line
	end
	table.sort(overdue, soonest)
	table.sort(now, soonest)
	table.sort(coming, soonest)
	return overdue, now, coming
end

--- Something search found: what it shows, where it is, and what it is.
export type Found = { label: string, note: string, line: number?, kind: string }

--- What `query` finds in the notes: their titles, headings and open
--- todos, best first, at most `M.FOUND`.
function M.search(query: string): { Found }
	local candidates: { Found } = {}
	local labels: { string } = {}
	local function add(found: Found)
		table.insert(candidates, found)
		table.insert(labels, found.label)
	end
	for _, note in index.all() do
		add({ label = note.title, note = note.name, kind = "note" })
		for _, node in note.nodes do
			if node.kind == "heading" and node.text ~= note.title then
				add({ label = node.text, note = note.name, line = node.line, kind = "heading" })
			elseif node.task and not node.task.done then
				add({ label = node.text, note = note.name, line = node.line, kind = "todo" })
			end
		end
	end
	local out: { Found } = {}
	for _, i in greed.fuzzy(query, labels, { case = "smart" }) do
		table.insert(out, candidates[i])
		if #out >= M.FOUND then
			break
		end
	end
	return out
end

-- The notes changed last, newest first.
local function recent(): { notes.Note }
	local all = index.all()
	table.sort(all, function(a: notes.Note, b: notes.Note): boolean
		return a.modified > b.modified
	end)
	local out = {}
	for i = 1, math.min(#all, M.RECENT) do
		table.insert(out, all[i])
	end
	return out
end

-- How many open todos the inbox holds.
local function waiting(): number
	local inbox = index.note(todos.inbox())
	local count = 0
	for _, node in (if inbox then inbox.nodes else {}) :: { notes.Node } do
		if node.task and not node.task.done then
			count += 1
		end
	end
	return count
end

-- Today's note, as lines to show: its text after the heading, a few lines.
local function today_lines(): { string }
	local text = notes.read(notes.daily()) or ""
	local out = {}
	for _, line in string.split(text, "\n") do
		if #out == 0 and (string.match(line, "^#") or line == "") then
			continue
		end
		table.insert(out, line)
		if #out >= 8 then
			break
		end
	end
	while #out > 0 and out[#out] == "" do
		table.remove(out)
	end
	return out
end

-- Opens note `name` in the main view, at `line` when given.
local function open(name: string, line: number?)
	if line then
		todos.open_at(name, line)
	else
		core.file.open(notes.path(name))
	end
end

-- A line for a todo: its box to tick, its words, and when it's due.
local function task_line(task: Task, when: string?): { core.UiSpan }
	local tick = ui.span("☐ ", "notes.todo")
	tick.press = function()
		local ok, err = pcall(function()
			todos.update(task.note, task.line, { done = true })
		end)
		if not ok then
			greed.echo(tostring(err))
		end
	end
	local spans = { tick, ui.span(task.text) }
	if when then
		local overdue = task.due < notes.today()
		table.insert(spans, ui.span(`  {when}`, if overdue then "notes.overdue" else "notes.due"))
	end
	return spans
end

-- Adds a part of the agenda to `into`: a heading and its todos, when it
-- has any.
local function agenda_part(
	into: { core.UiNode },
	title: string,
	tasks: { Task },
	when: (task: Task) -> string?
)
	if #tasks == 0 then
		return
	end
	table.insert(into, ui.text(title, "ui.menu.doc"))
	table.insert(
		into,
		ui.list(tasks, function(task: Task)
			return task_line(task, when(task))
		end, {
			open = function(task: Task)
				open(task.note, task.line)
			end,
		})
	)
end

--- What the home shows, for its state (`query`, what search found).
function M.render(view: core.UiView, state: { [string]: any }): core.UiNode
	local parts: { core.UiNode } = {
		ui.line({
			ui.span("Hoard", "markup.heading"),
			ui.span(`  {os.date("%A %d %B", notes.clock())}`, "comment"),
		}),
		ui.gap(),
		ui.field("Search", state.query or "", function(query: string)
			view:set({ query = query, found = if query == "" then nil else M.search(query) })
		end),
	}
	local found: { Found }? = state.found
	if found then
		if #found == 0 then
			table.insert(parts, ui.text("  nothing found", "comment"))
		end
		table.insert(
			parts,
			ui.list(found, function(item: Found)
				local where = if item.kind == "note" then "" else `  {item.note}`
				return { ui.span(`  {item.label}`), ui.span(where, "comment") }
			end, {
				open = function(item: Found)
					open(item.note, item.line)
				end,
			})
		)
	end
	table.insert(parts, ui.gap())
	table.insert(
		parts,
		ui.row({
			ui.field("Add a todo", "", function(text: string)
				if string.match(text, "%S") then
					notes.make_daily()
					greed.echo(todos.capture(text, notes.daily()))
				end
			end),
			ui.field("Jot down", "", function(text: string)
				if string.match(text, "%S") then
					notes.make_daily()
					notes.append(notes.daily(), `- {text}`)
				end
			end),
		})
	)
	table.insert(parts, ui.gap())

	local today_parts: { core.UiNode } = {}
	for _, line in today_lines() do
		table.insert(today_parts, ui.text(line))
	end
	if #today_parts == 0 then
		table.insert(today_parts, ui.text("Nothing written today yet.", "comment"))
	end
	table.insert(
		today_parts,
		ui.button("Open today's note", function()
			core.file.open(notes.make_daily())
		end)
	)
	table.insert(parts, ui.box("Today", ui.column(today_parts)))
	table.insert(parts, ui.gap())

	local overdue, now, coming = agenda()
	local agenda_parts: { core.UiNode } = {}
	agenda_part(agenda_parts, "Overdue", overdue, function(task: Task)
		return dates.short(task.due)
	end)
	agenda_part(agenda_parts, "Today", now, function()
		return nil
	end)
	agenda_part(agenda_parts, "Next days", coming, function(task: Task)
		return dates.day(task.due)
	end)
	if #agenda_parts == 0 then
		table.insert(agenda_parts, ui.text("Nothing due this week.", "comment"))
	end
	table.insert(parts, ui.box("Agenda", ui.column(agenda_parts)))
	table.insert(parts, ui.gap())

	local inbox = waiting()
	table.insert(
		parts,
		ui.row({
			ui.button(if inbox == 1 then "Inbox: 1 todo" else `Inbox: {inbox} todos`, function()
				open(todos.inbox())
			end),
			ui.button("All todos", function()
				greed.run("notes-agenda")
			end),
		}, { fit = true })
	)
	table.insert(parts, ui.gap())
	table.insert(parts, ui.text("Recent notes", "ui.menu.doc"))
	table.insert(
		parts,
		ui.list(recent(), function(note: notes.Note)
			-- A note without a title of its own goes by its name alone.
			local named = string.match(note.name, "([^/:]+)$")
			local where = if note.title == named then "" else `  {note.name}`
			return { ui.span(`  {note.title}`), ui.span(where, "comment") }
		end, {
			open = function(note: notes.Note)
				open(note.name)
			end,
		})
	)
	return ui.column(parts)
end

-- The home's buffer and its view, made once.
local home: { buffer: greed.Buffer, view: core.UiView }? = nil

--- The home's buffer, made and drawn the first time; it's drawn again as
--- the notes change.
function M.buffer(): greed.Buffer
	local made = home
	if made and made.buffer:valid() then
		return made.buffer
	end
	local buffer = greed.create_buffer("hoard", "", { readonly = true })
	buffer:set_line_numbers(false)
	local view: core.UiView
	view = ui.mount(buffer, function(state)
		return M.render(view, state)
	end, { query = "" }, { ns = "hoard", draw = false })
	home = { buffer = buffer, view = view }
	greed.spawn(function()
		index.ensure()
		view:redraw()
	end)
	return buffer
end

--- Whether `buffer` is the home.
function M.is(buffer: greed.Buffer): boolean
	return home ~= nil and home.buffer == buffer
end

--- Shows the home in `view`, the one you're in by default.
function M.show(view: greed.View?)
	local buffer = M.buffer()
	local target = view or greed.view()
	target:show(buffer)
	target:set_cursor(0)
end

-- Going back to the home after it has gone, from a note opened there,
-- shows it again.
core.jumps.reopen("hoard", function(view: greed.View)
	M.show(view)
end)

-- The notes changed: the home shows them as they are now.
index.on_changed(function()
	local shown = home
	if shown and shown.buffer:valid() then
		shown.view:soon({})
	end
end)

return M
