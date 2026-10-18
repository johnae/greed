-- How notes look: Markdown's markup shows as symbols. Todo boxes become ☐
-- and ☑, headings a symbol for their level, list dashes bullets, due
-- dates a calendar and the day (colored by how close it is), reminders an
-- alarm clock and the time. The file stays plain Markdown; typing on a
-- line shows what's really there (see `core.reveal`). The symbols are
-- buttons too: clicking a box ticks it, a heading's symbol folds its
-- section.
--
-- Change the symbols, add rules of your own, and style both from your
-- config:
--
--     local notes = require("@notes")
--     notes.symbols({ todo = "", done = "", bullet = "-" })
--     notes.rule({ pattern = "#[%w_-]+", style = "notes.tag" })
--     notes.rule({ pattern = "!!", show = "🔥", style = "notes.urgent" })
--     require("@greed").theme.set({ ["notes.tag"] = { fg = "magenta" } })

local greed = require("@greed")
local markdown = require("@markdown")
local notes = require("./notes")
local todos = require("./todos")
local dates = require("./dates")
local syntax = require("./syntax")

local M = {}

-- How close a due date is, as its style: overdue, today, in the next
-- three days, or later.
local function due_style(date: string): string
	local days = dates.days(date) or 0
	if days < 0 then
		return "notes.overdue"
	elseif days == 0 then
		return "notes.due.today"
	elseif days <= 3 then
		return "notes.due.soon"
	end
	return "notes.due"
end

-- The marks for line `n` of a note whose structure is `s`.
local function line_marks(s: markdown.Structure, n: number, out: { greed.Mark })
	if s.code_at[n] then
		return
	end
	local text, at = s.lines[n + 1], s.starts[n + 1]
	local function show(
		from: number,
		to: number,
		replacement: string,
		style: string,
		action: string?
	)
		table.insert(out, {
			from = at + from,
			to = at + to,
			style = style,
			text = replacement,
			conceal = true,
			reveal = "auto" :: "auto",
			action = action,
		})
	end
	local symbols = notes.look.symbols
	local item, heading = s.item_at[n], s.heading_at[n]
	local col = if item then item.from - at else 0
	if item and item.check then
		local done = item.check ~= " "
		-- The bullet, the box and a space after it.
		local _, box_end = string.find(text, "^[-*+]%s+%[[ xX]%]%s?", col + 1)
		local symbol = if done then symbols.done else symbols.todo
		show(
			col,
			box_end :: number,
			symbol .. " ",
			if done then "notes.done.box" else "notes.todo",
			"todo-toggle"
		)
		if done then
			table.insert(
				out,
				{ from = at + (box_end :: number), to = at + #text, style = "notes.done" }
			)
		end
	elseif heading and not heading.underlined then
		local level = math.min(heading.level, #symbols.headings)
		local from = heading.from - at
		local _, marker_end = string.find(text, "^#+%s?", from + 1)
		show(
			from,
			marker_end :: number,
			symbols.headings[level] .. " ",
			"notes.heading",
			"fold-toggle"
		)
	elseif
		item
		and string.find(item.bullet, "^[-*+]$")
		-- Choices, `- ( )`, are Markdown's to draw.
		and not string.find(text, "^[-*+] %([ xX]%) ", col + 1)
	then
		show(col, col + 2, symbols.bullet .. " ", "notes.bullet")
	end
	for from, date, to in string.gmatch(text, "()due:(%d%d%d%d%-%d%d%-%d%d)()") do
		local day = date :: string
		show(
			(from :: number) - 1,
			(to :: number) - 1,
			`{symbols.due} {dates.short(day)}`,
			due_style(day)
		)
	end
	for _, reminder in todos.reminders(text) do
		local date, time = reminder.date, reminder.time
		local shown = if date and time
			then `{dates.short(date)} {time}`
			elseif date then dates.short(date)
			else time :: string
		show(reminder.from - 1, reminder.to - 1, `{symbols.remind} {shown}`, "notes.remind")
	end
	-- How often it repeats, and from and until when, in words.
	if string.find(text, "every:", 1, true) then
		local from: any, every, bang, to: any = string.match(text, "()every:([%w,]+)(!?)()")
		if from then
			local said = `{symbols.every} {string.sub(dates.every_words(every :: string), 7)}`
			show(from - 1, to - 1, if bang == "!" then `{said} (habit)` else said, "notes.remind")
		end
	end
	for _, marker in syntax.DATED do
		if string.find(text, marker .. ":", 1, true) then
			for from: any, date, to: any in string.gmatch(text, `(){marker}:({syntax.DATE})()`) do
				local day = if marker == "done" and dates.days(date) == 0
					then "today"
					else dates.short(date)
				show(from - 1, to - 1, `{marker} {day}`, "notes.remind")
			end
		end
	end
	for _, rule in notes.look.rules do
		local start = 1
		while start <= #text do
			local from, to = string.find(text, rule.pattern, start)
			if from == nil or to == nil or to < from then
				break
			end
			if rule.show then
				show(from - 1, to, rule.show, rule.style, rule.action)
			else
				table.insert(
					out,
					{ from = at + from - 1, to = at + to, style = rule.style, action = rule.action }
				)
			end
			start = to + 1
		end
	end
end

local redraw = markdown.conceal({
	ns = "notes-look",
	wants = function(buffer: greed.Buffer): boolean
		return notes.is_note(buffer) and greed.option.get("notes-conceal") == true
	end,
	draw = function(
		_buffer: greed.Buffer,
		s: markdown.Structure,
		first: number,
		last: number
	): { greed.Mark }
		local marks: { greed.Mark } = {}
		for n = first, last do
			line_marks(s, n, marks)
		end
		return marks
	end,
})

--- Draws every open note again, as after changing symbols or rules.
function M.refresh()
	redraw()
end

notes.look.changed = M.refresh

-- Notes draw headings and bullets as symbols; the Markdown plugin draws
-- the rest of their markup.
markdown.claim(function(buffer: greed.Buffer): markdown.Parts?
	if notes.is_note(buffer) and greed.option.get("notes-conceal") == true then
		return { headings = true, bullets = true }
	end
	return nil
end)

greed.on("option.changed", function(event)
	if event.name == "notes-conceal" or event.name == "notes-everywhere" then
		M.refresh()
		-- Which buffers are notes changed, and with it what Markdown draws.
		markdown.refresh()
	end
end)

return M
