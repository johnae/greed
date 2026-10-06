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
local core = require("@core")
local markdown = require("@markdown")
local notes = require("./notes")
local todos = require("./todos")
local dates = require("./dates")

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

-- The marks for one line of text starting at `at`.
local function line_marks(text: string, at: number, out: { greed.Mark })
	local shows: "line" | "cursor" | "never" = core.reveal()
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
			reveal = shows,
			action = action,
		})
	end
	local symbols = notes.look.symbols
	local indent, box, rest = string.match(text, "^(%s*)[-*] %[([ xX])%] ()")
	local hashes = string.match(text, "^(#+) ")
	if box then
		local done = box ~= " "
		local box_end = (rest :: number) - 1
		local symbol = if done then symbols.done else symbols.todo
		show(
			#(indent :: string),
			box_end,
			symbol .. " ",
			if done then "notes.done.box" else "notes.todo",
			"todo-toggle"
		)
		if done then
			table.insert(out, { from = at + box_end, to = at + #text, style = "notes.done" })
		end
	elseif hashes then
		local level = math.min(#hashes, #symbols.headings)
		show(0, #hashes + 1, symbols.headings[level] .. " ", "notes.heading", "fold-toggle")
	else
		-- Choices, `- ( )`, are Markdown's to draw.
		local spaces = if string.match(text, "^%s*[-*] %([ xX]%) ")
			then nil
			else string.match(text, "^(%s*)[-*] ")
		if spaces then
			show(#spaces, #spaces + 2, symbols.bullet .. " ", "notes.bullet")
		end
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
	local remind_from, remind_to, date, time = todos.marker(text, "remind")
	if remind_from and remind_to and date then
		local shown = if time then `{dates.short(date)} {time}` else dates.short(date)
		show(remind_from - 1, remind_to - 1, `{symbols.remind} {shown}`, "notes.remind")
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

local function mark(buffer: greed.Buffer)
	if not notes.is_note(buffer) or greed.option.get("notes-conceal") ~= true then
		buffer:decorate("notes-look", {})
		return
	end
	local marks: { greed.Mark } = {}
	for line = 0, buffer:line_count() - 1 do
		local start = buffer:line_start(line)
		line_marks(buffer:slice(start, buffer:line_end(line)), start, marks)
	end
	buffer:decorate("notes-look", marks)
end

--- Draws every open note again, as after changing symbols or rules.
function M.refresh()
	for _, buffer in greed.buffers() do
		mark(buffer)
	end
end

notes.look.changed = M.refresh

local function on_buffer(event: greed.BufferChanged)
	pcall(mark, event.buffer)
end

greed.on("buffer.opened", on_buffer)
greed.on("buffer.changed", on_buffer)

-- Typing shows markup as written, so it's drawn again as modes change.
greed.on("mode.changed", function()
	M.refresh()
end)

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
