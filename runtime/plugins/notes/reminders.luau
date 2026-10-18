-- Reminders: "remind:2026-10-06 18:00" anywhere on a line of a note, as
-- many as you like (a date alone goes off at `notes-remind-time`). When one
-- comes due, a notice stays at the top right until you dismiss it (space n
-- r) or click a reminder in it to open its note, and it goes to your
-- desktop: through the terminal while it isn't focused
-- (`greed.client.notify`), and with notify-send or osascript where they're
-- installed. Reminders that came due while the editor wasn't running show
-- the next time it starts.
--
-- The status line says how many todos are due today, in a warning style
-- when some are overdue; clicking it opens the agenda. space k on a due
-- date or a reminder says when it is in words.

local greed = require("@greed")
local core = require("@core")
local statusline = require("@statusline")
local notes = require("./notes")
local todos = require("./todos")
local index = require("./index")
local dates = require("./dates")
local look = require("./look")

greed.option.define({
	name = "notes-remind-time",
	doc = "When a reminder with a date and no time goes off, as HH:MM",
	default = "09:00",
})

greed.option.define({
	name = "notes-remind-desktop",
	doc = "Show reminders as desktop notifications with notify-send or osascript, where installed",
	default = true,
})

local M = {}

export type Reminder = {
	note: string,
	--- 0-based.
	line: number,
	--- The line without its box and markers.
	text: string,
	date: string,
	time: string,
	--- When it goes off, in seconds.
	at: number,
	--- What it's remembered by once it went off.
	key: string,
}

--- Every reminder in the notes, on lines that aren't ticked todos.
function M.scan(): { Reminder }
	index.ensure()
	local out: { Reminder } = {}
	local default = greed.option.get("notes-remind-time") :: string
	for _, note in index.all() do
		for _, reminder in note.reminders do
			local date = reminder.date
			local time = reminder.time or default
			local at = dates.moment(date, time)
			if at then
				table.insert(out, {
					note = note.name,
					line = reminder.line,
					text = reminder.text,
					date = date,
					time = time,
					at = at,
					key = `{note.name}\t{date} {time}\t{reminder.text}`,
				})
			end
		end
	end
	table.sort(out, function(a: Reminder, b: Reminder)
		return a.at < b.at
	end)
	return out
end

-- The reminders that went off, by key: those this session set off, and
-- what the cache folder's record says, which every session here shares.
local fired: { [string]: boolean } = {}

local function record_file(): string?
	local cache = greed.fs.dirs().cache
	return if cache then `{cache}/notes-reminders` else nil
end

-- What went off, read again each time, so one another session set off
-- doesn't go off here too.
local function load_fired(): { [string]: boolean }
	local file = record_file()
	local text = if file then greed.fs.read(file) else nil
	for _, key in string.split(text or "", "\n") do
		if key ~= "" then
			fired[key] = true
		end
	end
	return fired
end

-- Whether `key` is a reminder in a project's notes.
local function in_project(key: string): boolean
	return string.sub(key, 1, 8) == "project:"
end

-- Keeps the reminders that went off and are still in the notes, and those
-- in projects' notes, which another session may be looking at.
local function save_fired(reminders: { Reminder })
	local file = record_file()
	if file == nil then
		return
	end
	local went = load_fired()
	local still: { [string]: boolean } = {}
	for _, reminder in reminders do
		still[reminder.key] = true
	end
	local keys = {}
	for key in went do
		if still[key] or in_project(key) then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	greed.fs.write(file, table.concat(keys, "\n") .. "\n")
end

--- The program that shows a desktop notification here, if one is
--- installed: notify-send (Linux and the BSDs), or osascript (macOS).
function M.desktop_command(title: string, body: string): { string }?
	if greed.which("notify-send") then
		return { "notify-send", "--app-name=Greed", title, body }
	elseif greed.which("osascript") then
		return {
			"osascript",
			"-e",
			"on run argv",
			"-e",
			"display notification (item 2 of argv) with title (item 1 of argv)",
			"-e",
			"end run",
			title,
			body,
		}
	end
	return nil
end

-- What a reminder shows as: when, if that isn't today, what, and where.
local function describe(reminder: Reminder): string
	local day = if dates.days(reminder.date) == 0 then "" else `{dates.day(reminder.date)} `
	return `{day}{reminder.time}  {reminder.text}  ({reminder.note})`
end

-- The notice: its view while it's shown, what draws it (each reminder's
-- line's value the reminder), and the reminders in it.
local notice: { view: greed.View?, drawn: core.UiView?, shown: { Reminder } } =
	{ view = nil, drawn = nil, shown = {} }

--- The reminders the notice shows, oldest first.
function M.shown(): { Reminder }
	return notice.shown
end

-- What draws the notice: the reminders, then how to dismiss them.
local function drawing(): core.UiView
	local drawn = notice.drawn
	if drawn then
		return drawn
	end
	local buffer = greed.create_buffer("reminders", "", { readonly = true })
	buffer:set_line_numbers(false)
	local made = core.ui.mount(buffer, function()
		return core.ui.column({
			core.ui.list(notice.shown, function(reminder: Reminder): { core.UiSpan }
				return { core.ui.span(describe(reminder), "notes.remind") }
			end),
			core.ui.line({ core.ui.span("space n r dismisses", "comment") }),
		})
	end, nil, { ns = "reminders", keys = false, draw = false })
	notice.drawn = made
	return made
end

-- Shows the notice with what's in it, opening it or changing its size.
local function draw()
	local width = 20
	for _, reminder in notice.shown do
		width = math.max(width, core.text.width(describe(reminder)) + 2)
	end
	local view = notice.view
	local drawn = drawing()
	drawn:redraw()
	local spec: greed.FloatSpec = {
		title = if #notice.shown == 1 then "Reminder" else "Reminders",
		width = math.min(width, 70),
		height = #notice.shown + 3,
		x = "100%",
		y = 0,
		focus = false,
	}
	if view then
		view:configure(spec)
	else
		notice.view = greed.float(drawn.buffer, spec)
	end
end

--- Closes the notice.
function M.dismiss()
	if notice.view then
		pcall(notice.view.close, notice.view)
	end
	notice.view, notice.drawn = nil, nil
	notice.shown = {}
end

-- Closed some other way, it's dismissed too.
greed.on("view.closed", function(event: greed.ViewClosed)
	if notice.view and notice.view:id() == event.view then
		notice.view, notice.drawn = nil, nil
		notice.shown = {}
	end
end)

--- Tells you about `reminders`, which just came due: in the notice, and on
--- your desktop.
function M.notify(reminders: { Reminder })
	if #reminders == 0 then
		return
	end
	local bodies = {}
	for _, reminder in reminders do
		table.insert(notice.shown, reminder)
		table.insert(bodies, reminder.text)
	end
	draw()
	local title = if #reminders == 1 then "Reminder" else `{#reminders} reminders`
	local body = table.concat(bodies, "\n")
	greed.client.notify(title, body)
	local command = if greed.option.get("notes-remind-desktop") == true
		then M.desktop_command(title, body)
		else nil
	if command then
		-- A desktop without notifications isn't worth an error.
		pcall(function()
			greed.process.run(command)
		end)
	end
end

-- How many open todos are due today, and how many are overdue, as of the
-- last check.
local counts = { today = 0, overdue = 0 }
local last_day: string? = nil

--- Whether the session `current` sets off reminders in your own notes,
--- with the sessions `running` here: only the first of them by name does,
--- so several sessions don't tell you twice. A project's notes remind in
--- its own session. The editor not running as a session always does.
function M.reminds_yours(current: string?, running: { string }): boolean
	if current == nil then
		return true
	end
	for _, name in running do
		if name < current then
			return false
		end
	end
	return true
end

-- Whether this session sets off reminders in your own notes.
local function yours_here(): boolean
	local running = {}
	for _, session in greed.session.list() do
		table.insert(running, session.name)
	end
	return M.reminds_yours(greed.session.current(), running)
end

--- Looks for reminders that came due and haven't gone off, and tells you
--- about them; counts what's due for the status line. Returns how many
--- went off.
function M.check(): number
	-- Counted straight from the index: dates as notes write them sort as
	-- they fall, so comparing them with today's is enough.
	index.ensure()
	local today_date = dates.today()
	local today, overdue = 0, 0
	for _, note in index.all() do
		for _, node in note.nodes do
			local task = node.task
			local due = if task and not task.done then task.due else nil
			if due == today_date then
				today += 1
			elseif due and due < today_date then
				overdue += 1
			end
		end
	end
	counts.today, counts.overdue = today, overdue
	-- Due dates are colored by how close they are, which changes overnight.
	local day = dates.today()
	if last_day and last_day ~= day then
		look.refresh()
	end
	last_day = day
	local reminders = M.scan()
	local went = load_fired()
	local now = notes.clock()
	local yours = yours_here()
	local due: { Reminder } = {}
	-- A line with several reminders that went off since the last look
	-- shows once, at its latest.
	local lines: { [string]: number } = {}
	for _, reminder in reminders do
		local here = yours or in_project(reminder.key)
		if here and reminder.at <= now and not went[reminder.key] then
			went[reminder.key] = true
			local line = `{reminder.note}\t{reminder.line}`
			local at = lines[line]
			if at then
				due[at] = reminder
			else
				table.insert(due, reminder)
				lines[line] = #due
			end
		end
	end
	if #due > 0 then
		save_fired(reminders)
		M.notify(due)
	end
	return #due
end

--- What the status line shows about what's due: "2 due today", or
--- "1 overdue, 2 due today" in a warning style. Nothing when nothing is.
function M.status(): statusline.Pill?
	local today, overdue = counts.today, counts.overdue
	if overdue > 0 then
		local text = if today > 0
			then `{overdue} overdue, {today} due today`
			else `{overdue} overdue`
		return { text = text, style = "ui.statusline.warning", action = "notes-agenda" }
	elseif today > 0 then
		return { text = `{today} due today`, action = "notes-agenda" }
	end
	return nil
end

statusline.add("right", "agenda", function()
	return M.status()
end, "problems")

local function check()
	local ok, err = pcall(M.check)
	if not ok then
		greed.echo(`reminders: {err}`)
	end
end

-- Once a minute, on the minute, so an 18:00 reminder goes off at 18:00.
greed.spawn(function()
	while true do
		greed.sleep((60 - notes.clock() % 60) * 1000)
		check()
	end
end)

-- Missed reminders show as the editor starts, once the config has set
-- where the notes are.
greed.on("editor.started", check)

greed.on("buffer.saved", function(event: greed.BufferChanged)
	if notes.is_note(event.buffer) then
		check()
	end
end)

greed.on("option.changed", function(event)
	if event.name == "notes-folder" or event.name == "notes-remind-time" then
		check()
	end
end)

--- When the due date or reminder at `pos` in `text` (a line) is, in words;
--- nil when there's none there. `pos` is a 1-based index into `text`.
function M.words_at(text: string, pos: number): string?
	for from, date, to in string.gmatch(text, "()due:(%d%d%d%d%-%d%d%-%d%d)()") do
		if (from :: number) <= pos and pos < (to :: number) then
			return dates.due_words(date :: string)
		end
	end
	for _, reminder in todos.reminders(text) do
		if reminder.from <= pos and pos < reminder.to then
			local default = greed.option.get("notes-remind-time") :: string
			return dates.remind_words(reminder.date, reminder.time or default)
		end
	end
	return nil
end

-- space k on a due date or reminder says when it is, in words.
core.lookup.add("hover", function(ctx)
	local head = ctx.view:cursor()
	local line = ctx.buffer:line_of(head)
	local start = ctx.buffer:line_start(line)
	local words = M.words_at(ctx.buffer:slice(start, ctx.buffer:line_end(line)), head - start + 1)
	if words then
		greed.echo(words)
	end
	return words ~= nil
end)

greed.command({
	name = "notes-reminders-dismiss",
	doc = "Close the reminders notice",
	run = M.dismiss,
})

-- Closes the notice and opens the note of the `index`th reminder in it.
local function open(index: number)
	local reminder = notice.shown[index]
	M.dismiss()
	if reminder then
		todos.open_at(reminder.note, reminder.line)
	end
end

greed.command({
	name = "notes-reminder-open",
	doc = "Open the first reminder in the notice, and close the notice",
	run = function()
		open(1)
	end,
})

-- Clicking a reminder in the notice opens it.
core.mouse.claim("reminders", function(event: greed.MouseEvent): boolean
	local view = event.view
	if event.kind == "press" and event.button == "left" and view and event.pos then
		local drawn = notice.drawn
		local reminder: Reminder? = drawn and drawn:value_at(event.pos)
		local index = reminder and table.find(notice.shown, reminder) or 0
		-- Once the other handlers are done with the view this closes.
		greed.spawn(function()
			greed.sleep(0)
			open(index)
		end)
	end
	return true
end)

return M
