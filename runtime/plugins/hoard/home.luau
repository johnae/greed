-- Hoard's home: what notes open to. The agenda (overdue, due today and
-- in the next days, with boxes to tick), what waits in the inbox, the notes
-- you were in lately and today's note, and under them a box to write in:
-- what's written there finds notes as it's written, and alt-enter adds it
-- to today's note, a line starting [] as a todo. It's drawn from the
-- notes' index, and drawn again as the notes change.

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

--- Adds what was written in the home's box to today's note: each line
--- starting `[]` (or `[ ]`, `- [ ]`) as a todo, read for when in plain words
--- (`dates.read_words`); the rest as written, a single line as a list
--- item. Returns what it did, in words, or nil for nothing written.
function M.add(text: string): string?
	local todo_lines: { string } = {}
	local other: { string } = {}
	for _, line in string.split(text, "\n") do
		local rest = string.match(line, "^%s*[-*+]?%s*%[ ?%]%s*(.*)$")
		if rest and string.match(rest, "%S") then
			table.insert(todo_lines, rest)
		else
			table.insert(other, line)
		end
	end
	while #other > 0 and not string.match(other[1], "%S") do
		table.remove(other, 1)
	end
	while #other > 0 and not string.match(other[#other], "%S") do
		table.remove(other)
	end
	if #todo_lines == 0 and #other == 0 then
		return nil
	end
	notes.make_daily()
	local today = notes.daily()
	if #other == 1 and not string.match(other[1], "^%s*[-*+#>]") then
		notes.append(today, `- {other[1]}`)
	elseif #other > 0 then
		notes.append(today, table.concat(other, "\n"))
	end
	local said: { string } = {}
	for _, line in todo_lines do
		table.insert(said, todos.capture(line, today))
	end
	if #said == 1 then
		return `{said[1]}: added to today's note`
	end
	return if #said > 1 then `{#said} todos added to today's note` else "added to today's note"
end

--- What the home shows, for its state (`query`: what's written in its box,
--- searched for as it's written).
function M.render(view: core.UiView, state: { [string]: any }): core.UiNode
	local parts: { core.UiNode } = {
		ui.line({
			ui.span("Hoard", "markup.heading"),
			ui.span(`  {os.date("%A %d %B", notes.clock())}`, "comment"),
		}),
		ui.gap(),
	}

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

	-- What's written in the box finds notes as it's written, right above it:
	-- a line, as a search is typed, rather than a thought being written down.
	local query: string = state.query or ""
	local found = if string.match(query, "%S") and not string.find(query, "\n", 1, true)
		then M.search(query)
		else {}
	if #found > 0 then
		table.insert(parts, ui.text("Notes that match", "ui.menu.doc"))
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
		table.insert(parts, ui.gap())
	end
	table.insert(parts, ui.box_top("Write a thought, or search", "markdown.table"))
	return ui.column(parts)
end

-- The home's buffer and its view, made once.
local home: { buffer: greed.Buffer, view: core.UiView }? = nil

-- Frames what's written after the home as a box (the home ends with its
-- top), with what alt-enter does on its bottom; a click there does it.
local function frame(buffer: greed.Buffer, view: core.UiView)
	local cells = ui.width(buffer)
	local start = view:input_start()
	local hint = " [] makes a todo · ↑ goes to what's above, enter opens it "
	local add = " Add to today, alt-enter "
	local rule = math.max(cells - 4 - core.text.width(hint) - core.text.width(add), 1)
	local bottom: greed.MarkLine = {
		{ text = "╰─" .. hint .. string.rep("─", rule) },
		{ text = add, style = "ui.button", action = "hoard-add" },
		{ text = "─╯" },
	}
	local marks = ui.input_sides(buffer, buffer:line_of(start), cells, "markdown.table", bottom)
	buffer:decorate("hoard-box", marks)
end

--- The home's buffer, made and drawn the first time; it's drawn again as
--- the notes change. What's written after it is the box.
function M.buffer(): greed.Buffer
	local made = home
	if made and made.buffer:valid() then
		return made.buffer
	end
	local buffer = greed.create_buffer("hoard", "")
	buffer:set_line_numbers(false)
	local view: core.UiView
	view = ui.mount(buffer, function(state)
		return M.render(view, state)
	end, { query = "" }, {
		ns = "hoard",
		input = true,
		keys = false,
		draw = false,
		after = function(drawn: core.UiView)
			frame(buffer, drawn)
		end,
	})
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

--- Shows the home in `view`, the one you're in by default, ready to write
--- in its box.
function M.show(view: greed.View?)
	local buffer = M.buffer()
	local target = view or greed.view()
	target:show(buffer)
	target:set_cursor(buffer:len())
end

greed.command({
	name = "hoard-add",
	doc = "Add what's written in the home's box to today's note: lines starting [] as todos",
	run = function()
		local shown = home
		if shown == nil or not shown.buffer:valid() then
			return
		end
		local view = shown.view
		local said = M.add(view:input())
		if said == nil then
			return
		end
		local buffer = shown.buffer
		buffer:edit(function(e)
			e:replace(view:input_start(), buffer:len(), "")
		end)
		greed.echo(said)
	end,
})

-- Where the box starts in the home's buffer, and whether `view`'s cursor
-- is in it.
local function in_box(view: greed.View): (boolean, number)
	local shown = home
	local start = if shown then shown.view:input_start() else 0
	return view:cursor() >= start, start
end

greed.command({
	name = "hoard-up",
	doc = "On the home: up a line in the box, from its first line to the nearest thing above to "
		.. "open or press, and from there to the one before",
	run = function(ctx)
		local inside, start = in_box(ctx.view)
		local buffer = ctx.buffer
		if inside and buffer:line_of(ctx.view:cursor()) > buffer:line_of(start) then
			greed.run("move-up")
		else
			greed.run("ui-prev")
		end
	end,
})

greed.command({
	name = "hoard-down",
	doc = "On the home: down a line in the box, or to the next thing to open or press, and past "
		.. "the last back to the box",
	run = function(ctx)
		if in_box(ctx.view) then
			greed.run("move-down")
			return
		end
		local before = ctx.view:cursor()
		greed.run("ui-next")
		if ctx.view:cursor() <= before then
			ctx.view:set_cursor(ctx.buffer:len())
		end
	end,
})

greed.command({
	name = "hoard-box",
	doc = "On the home: back to the end of the box to write in",
	run = function(ctx)
		ctx.view:set_cursor(ctx.buffer:len())
	end,
})

-- The next place of a snippet being filled in in `view`, or else the next
-- thing to open or press; with `back`, the one before.
local function step(view: greed.View, back: boolean)
	if not core.snippet.move(view, back) then
		greed.run(if back then "ui-prev" else "ui-next")
	end
end

greed.command({
	name = "hoard-tab",
	doc = "On the home: the next place of a snippet being filled in, or the next thing to open",
	run = function(ctx)
		step(ctx.view, false)
	end,
})

greed.command({
	name = "hoard-tab-back",
	doc = "On the home: the place of a snippet before, or the thing to open before",
	run = function(ctx)
		step(ctx.view, true)
	end,
})

greed.command({
	name = "hoard-enter",
	doc = "On the home: a new line in the box, or else open or press what the cursor is on",
	run = function(ctx)
		greed.run(if in_box(ctx.view) then "insert-newline" else "ui-press")
	end,
})

-- Moving about the home: tab and shift-tab, and the arrows, go between
-- what can be opened or pressed, enter opens it, and esc goes back to the
-- box. The completion menu keeps its own (complete.luau).
greed.keymap.bind({ role = "typing", kind = "hoard" }, {
	up = "hoard-up",
	down = "hoard-down",
	tab = "hoard-tab",
	["shift-tab"] = "hoard-tab-back",
	enter = "hoard-enter",
	esc = "hoard-box",
})

-- In every mode, as the agent's box has it; enter starts a new line.
greed.keymap.bind({ kind = "hoard" }, {
	["alt-enter"] = "hoard-add",
	["ctrl-enter"] = "hoard-add",
})

-- What's written in the box is searched for as it's written, and the box
-- grows around it.
greed.on("buffer.changed", function(event: greed.BufferChanged)
	local shown = home
	if shown and shown.buffer == event.buffer then
		local query = shown.view:input()
		if query ~= shown.view.state.query then
			shown.view:soon({ query = query })
		end
		frame(shown.buffer, shown.view)
	end
end)

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
