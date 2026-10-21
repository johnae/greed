-- Hoard's home: what notes open to. The agenda (overdue, due today and
-- in the next days, with boxes to tick), what waits in the inbox, the notes
-- you were in lately and today's note, and under them a box to write in:
-- what's written there finds notes as it's written, and alt-enter adds it
-- to today's note, a line starting [] as a todo. It's drawn from the
-- notes' index, and drawn again as the notes change.

local greed = require("@greed")
local core = require("@core")
local notes = require("@notes")
local review = require("./review")
local agenda_note = require("./agenda")
local picker = require("@picker")

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
type Task = { note: string, line: number, text: string, due: string, every: string? }

-- The open todos due up to `M.DAYS_AHEAD` days from now: those overdue,
-- due today and coming, each soonest first. Today's also has the open
-- todos written in today's note without a date, so what you add shows up,
-- and habits on their days until done (see `todos.due_on`).
local function agenda(): ({ Task }, { Task }, { Task })
	local today = notes.today()
	local daily = notes.daily()
	local last = os.date("%Y-%m-%d", notes.clock() + M.DAYS_AHEAD * 86400) :: string
	local overdue, now, coming = {}, {}, {}
	for _, note in index.all() do
		for _, node in note.nodes do
			local task = node.task
			if task == nil then
				continue
			end
			local due = todos.due_on(task, today)
			if due == nil and not task.done and not task.habit and note.name == daily then
				due = today
			end
			if due and due <= last then
				local item: Task = {
					note = note.name,
					line = node.line,
					text = todos.plain(task.text),
					due = due,
					every = task.every,
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

--- What `query` finds in the notes, best first, at most `M.FOUND`: what
--- they say, word for word, and their fields and flags, as the query
--- language reads it (the last word matching as it's typed); while it isn't
--- a query that runs (`due:` half typed), their titles, headings and open
--- todos by `query` as a fuzzy match. Searching waits like greed.sleep.
function M.search(query: string): { Found }
	local items = notes.query.search(query, M.FOUND, true)
	if items then
		local out: { Found } = {}
		for _, item in items do
			local node = item.node
			local found: Found = {
				label = notes.query.label(item),
				note = item.note.name,
				line = if node then node.line else nil,
				kind = item.kind :: string,
			}
			table.insert(out, found)
		end
		return out
	end
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

-- The notes changed last, newest first; templates aren't notes you write in.
local function recent(): { notes.Note }
	local all = index.all()
	table.sort(all, function(a: notes.Note, b: notes.Note): boolean
		return a.modified > b.modified
	end)
	local out = {}
	for _, note in all do
		if #out >= M.RECENT then
			break
		elseif not notes.is_template(note.name) then
			table.insert(out, note)
		end
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

-- Today's note, as lines to show: its text after the heading, a few lines,
-- without its todos (the agenda has them).
local function today_lines(): { string }
	local text = notes.read(notes.daily()) or ""
	local out = {}
	for _, line in string.split(text, "\n") do
		if (#out == 0 and (string.match(line, "^#") or line == "")) or todos.parse(line) ~= nil then
			continue
		end
		table.insert(out, notes.syntax.as_read(line))
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

--- Asks when `task` is due, offering today, tomorrow, the weekend, next
--- week and no date, or a day typed in plain words ("friday", "in 3
--- days"), and moves it there.
function M.schedule(task: Task)
	local today = notes.today()
	local items = {
		{ label = "Today", value = today },
		{ label = "Tomorrow", value = dates.add_days(today, 1) },
		{ label = "This weekend", value = dates.next(today, "saturday") },
		{ label = "Next week", value = dates.next(today, "monday") },
		{ label = "No date", value = "" },
	}
	local function move(due: string)
		local ok, err = pcall(function()
			todos.update(task.note, task.line, { due = due })
		end)
		if not ok then
			greed.echo(tostring(err))
		elseif due ~= "" then
			greed.echo(`{task.text}: {dates.due_words(due)}`)
		end
	end
	picker.pick(`When is it due? ({task.text})`, items, function(item)
		move(item.value)
	end, {
		fallback = function(typed: string)
			local said = dates.read_words(typed)
			if said.date then
				move(said.date)
			else
				greed.echo(`not a day I know: {typed}`)
			end
		end,
	})
end

-- A line for a todo: its box to tick, its words, when it's due, and a
-- button to say when.
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
	local spans = { tick, ui.span(notes.syntax.as_read(task.text)) }
	if task.every then
		table.insert(spans, ui.span(" ↻", "comment"))
	end
	if when then
		local overdue = task.due < notes.today()
		table.insert(spans, ui.span(`  {when}`, if overdue then "notes.overdue" else "notes.due"))
	end
	local later = ui.span(" when ", "ui.button")
	later.press = function()
		M.schedule(task)
	end
	table.insert(spans, ui.span("  "))
	table.insert(spans, later)
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

-- A note's first words worth showing: its first line that isn't a heading,
-- front matter or empty, without markup, cut to `cells`.
local function excerpt(name: string, cells: number): string
	local text = notes.read(name) or ""
	local in_front = string.sub(text, 1, 4) == "---\n"
	for n, line in string.split(text, "\n") do
		if in_front then
			in_front = not (n > 1 and line == "---")
		elseif not string.match(line, "^#") and string.match(line, "%S") then
			local plain = string.gsub(todos.plain(line), "^%s*[-*+] %[?.?%]?%s*", "") :: string
			return core.text.clip(plain, cells)
		end
	end
	return ""
end

-- A note to look at again today: one not changed for a month or more, a
-- different one each day, other than those in `skip`.
local function remembered(skip: { [string]: boolean }): notes.Note?
	local before = notes.clock() - 30 * 86400
	local old: { notes.Note } = {}
	for _, note in index.all() do
		if
			note.modified > 0
			and note.modified < before
			and not notes.routine(note.name)
			and not skip[note.name]
		then
			table.insert(old, note)
		end
	end
	if #old == 0 then
		return nil
	end
	table.sort(old, function(a: notes.Note, b: notes.Note): boolean
		return a.name < b.name
	end)
	local day = math.floor(notes.clock() / 86400)
	return old[day % #old + 1]
end

-- Something from before on the home: what it is, and the note.
type Back = { label: string, name: string, title: string? }

-- What the home brings back: the days' notes a week, a month and a year
-- ago, todos that have waited long, and an old note, each opened with
-- enter; and the weekly review.
local function from_before(): core.UiNode
	local today = notes.today()
	local lines: { core.UiNode } = {}
	local days = {
		{ "A week ago", dates.add_days(today, -7) },
		{ "A month ago", dates.add_months(today, -1) },
		{ "A year ago", dates.add_months(today, -12) },
	}
	local back: { Back } = {}
	for _, day in days do
		local name = notes.daily(day[2])
		if index.note(name) then
			table.insert(back, { label = day[1], name = name })
		end
	end
	local waiting = review.waiting(3)
	local waiting_in: { [string]: boolean } = {}
	for _, item in waiting do
		waiting_in[item.note] = true
	end
	local old = remembered(waiting_in)
	if old then
		table.insert(back, { label = "Remember this?", name = old.name, title = old.title })
	end
	if #back > 0 then
		table.insert(
			lines,
			ui.list(back, function(item: Back)
				local title = if item.title then `{item.title}: ` else ""
				return {
					ui.span(`{item.label}  `, "ui.menu.doc"),
					ui.span(title .. excerpt(item.name, 60)),
				}
			end, {
				open = function(item: Back)
					open(item.name)
				end,
			})
		)
	end
	if #waiting > 0 then
		table.insert(lines, ui.text("Waiting a while", "ui.menu.doc"))
		table.insert(
			lines,
			ui.list(waiting, function(item: review.Item)
				local task: Task =
					{ note = item.note, line = item.line, text = item.text, due = "" }
				local spans = task_line(task, nil)
				table.insert(
					spans,
					ui.span(`  untouched for {review.untouched(item.note)}`, "comment")
				)
				return spans
			end, {
				open = function(item: review.Item)
					open(item.note, item.line)
				end,
			})
		)
	end
	table.insert(
		lines,
		ui.button("Review the week", function()
			greed.run("hoard-review")
		end)
	)
	return ui.box("From before", ui.column(lines))
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

-- The file saying the first-run words were put away, in Greed's data
-- folder; nil without one.
local function welcomed_file(): string?
	local data = greed.fs.dirs().data
	return if data then `{data}/hoard/welcomed` else nil
end

-- Whether the first-run words were put away, read once.
local welcomed: boolean? = nil

--- Whether the home starts with the first-run words: until they're put
--- away (`M.welcomed`).
function M.welcoming(): boolean
	if welcomed == nil then
		local file = welcomed_file()
		welcomed = file == nil or greed.fs.stat(file) ~= nil
	end
	return not welcomed
end

-- What Hoard is, where the notes are and how to add to them, for the
-- first time it opens.
local function welcome(): core.UiNode
	local leader = core.style.current().leader or "space"
	return ui.box(
		"Welcome to Hoard",
		ui.column({
			ui.text(`Your notes are Markdown files in {core.project.tilde(notes.folder())}.`),
			ui.text("Write in the box at the bottom: alt-enter adds it to today's note."),
			ui.text(
				"A line starting [] is a todo, and it can say when: [] call Anna tomorrow 18:00."
			),
			ui.text("What you type there also searches your notes."),
			ui.text(
				`From anywhere in Greed, {leader} n c adds a todo; from a shell, greed capture TEXT.`
			),
			ui.text("up and down go through what's here, enter opens it, esc comes back."),
			ui.row({
				ui.button("Got it", function()
					M.welcomed()
				end),
				ui.button("Read more", function()
					greed.run("docs", { args = { "hoard" } })
				end),
			}, { fit = true }),
		})
	)
end

--- What the home shows, for its state (`found`: what what's written in its
--- box finds, searched for as it's written).
function M.render(view: core.UiView, state: { [string]: any }): core.UiNode
	local parts: { core.UiNode } = {
		ui.line({
			ui.span("Hoard", "markup.heading"),
			ui.span(`  {os.date("%A %d %B", notes.clock())}`, "comment"),
		}),
		ui.gap(),
	}
	if M.welcoming() then
		table.insert(parts, welcome())
		table.insert(parts, ui.gap())
	end

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
	table.insert(parts, from_before())
	table.insert(parts, ui.gap())

	local inbox = waiting()
	table.insert(
		parts,
		ui.row({
			ui.button(if inbox == 1 then "Inbox: 1 todo" else `Inbox: {inbox} todos`, function()
				open(todos.inbox())
			end),
			ui.button("Agenda note", function()
				agenda_note.open()
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
		local daily = index.note(notes.daily())
		local has_todos = false
		for _, node in (if daily then daily.nodes else {}) :: { notes.Node } do
			has_todos = has_todos or node.task ~= nil
		end
		table.insert(
			today_parts,
			ui.text(
				if has_todos
					then "Only todos so far; they're in the agenda."
					else "Nothing written today yet.",
				"comment"
			)
		)
	end
	table.insert(
		today_parts,
		ui.button("Open today's note", function()
			core.file.open(notes.make_daily())
		end)
	)
	table.insert(parts, ui.box("Today", ui.column(today_parts)))
	table.insert(parts, ui.gap())

	-- What's written in the box finds notes as it's written, right above it
	-- (searched away from drawing, below): a line, as a search is typed,
	-- rather than a thought being written down.
	local found: { Found } = state.found or {}
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

--- Puts the first-run words away, for good.
function M.welcomed()
	welcomed = true
	local file = welcomed_file()
	if file then
		greed.fs.write(file, "")
	end
	if home then
		home.view:redraw()
	end
end

-- The question when what's written in the box starts with `?`: it's asked
-- of the notes, by Greed's agent, rather than added.
local function asking(text: string): string?
	return string.match(text, "^%s*%?%s*(.-)%s*$")
end

-- Frames what's written after the home as a box (the home ends with its
-- top), with what alt-enter does on its bottom; a click there does it.
local function frame(buffer: greed.Buffer, view: core.UiView)
	local start = view:input_start()
	local first = buffer:line_of(start)
	-- As wide as its top, however wide the view was when that was drawn.
	local width = core.text.width
	local cells = if first > 0 then width(buffer:line_text(first - 1)) else ui.width(buffer)
	local add = if asking(view:input())
		then " Ask your notes, alt-enter "
		else " Add to today, alt-enter "
	-- Cells left for the hint and the rule, beside the corners and the button.
	local room = cells - 4 - width(add)
	-- The longest hint that fits.
	local hint = ""
	for _, said in
		{
			" [] makes a todo · ? asks your notes · ↑ goes to what's above ",
			" [] makes a todo · ? asks your notes ",
			" [] makes a todo ",
			"",
		}
	do
		if room - width(said) >= 1 then
			hint = said
			break
		end
	end
	local rule = math.max(room - width(hint), 1)
	local bottom: greed.MarkLine = {
		{ text = "╰─" .. hint .. string.rep("─", rule) },
		{ text = add, style = "ui.button", action = "hoard-add" },
		{ text = "─╯" },
	}
	local marks = ui.input_sides(buffer, first, cells, "markdown.table", bottom)
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
	doc = "Add what's written in the home's box to today's note: lines starting [] as todos; "
		.. "starting with ?, ask your notes",
	run = function()
		local shown = home
		if shown == nil or not shown.buffer:valid() then
			return
		end
		local view = shown.view
		local text = view:input()
		local question = asking(text)
		local said: string?
		if question then
			local ok, why = notes.jobs.run("ask", nil, question)
			if not ok then
				greed.echo(why :: string)
				return
			end
		else
			said = M.add(text)
			if said == nil then
				return
			end
		end
		local buffer = shown.buffer
		buffer:edit(function(e)
			e:replace(view:input_start(), buffer:len(), "")
		end)
		if said then
			greed.echo(said)
		end
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

greed.command({
	name = "hoard-schedule",
	doc = "On the home: say when the todo on the agenda the cursor is on is due; in the box, "
		.. "delete the next word as usual",
	run = function(ctx)
		local shown = home
		if in_box(ctx.view) then
			greed.run("delete-word-forward")
			return
		end
		if shown == nil or shown.buffer ~= ctx.buffer then
			return
		end
		local value = shown.view:value_on(ctx.buffer:line_of(ctx.view:cursor()))
		if type(value) == "table" and type(value.due) == "string" and value.text then
			M.schedule(value :: Task)
		else
			greed.echo("go to a todo on the agenda first")
		end
	end,
})

-- Moving about the home: tab and shift-tab, and the arrows, go between
-- what can be opened or pressed, enter opens it, alt-d says when a todo on
-- the agenda is due, and esc goes back to the box. The completion menu
-- keeps its own (complete.luau).
greed.keymap.bind({ role = "typing", kind = "hoard" }, {
	up = "hoard-up",
	down = "hoard-down",
	tab = "hoard-tab",
	["shift-tab"] = "hoard-tab-back",
	enter = "hoard-enter",
	esc = "hoard-box",
	["alt-d"] = "hoard-schedule",
})

-- In every mode, as the agent's box has it; enter starts a new line.
greed.keymap.bind({ kind = "hoard" }, {
	["alt-enter"] = "hoard-add",
	["ctrl-enter"] = "hoard-add",
})

-- What an agent is told the user is in.
core.about.kind("hoard", function(): string
	return "Hoard's home page: the user's todos for today, their agenda and recent notes "
		.. "(the notes tools find and read them)"
end)

-- What's written in the box is searched for as it's written, and the box
-- grows around it.
greed.on("buffer.changed", function(event: greed.BufferChanged)
	local shown = home
	if shown and shown.buffer == event.buffer then
		local query = shown.view:input()
		if query ~= shown.view.state.query then
			local view = shown.view
			view:soon({ query = query })
			if string.match(query, "%S") and not string.find(query, "\n", 1, true) then
				greed.spawn(function()
					local found = M.search(query)
					-- What's been written since has a search of its own.
					if view:input() == query then
						view:soon({ found = found })
					end
				end)
			else
				view:soon({ found = {} })
			end
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
