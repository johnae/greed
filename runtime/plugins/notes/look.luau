-- How notes look: on every line but the cursor's, Markdown's markup shows
-- as symbols, the way org-mode shows its own. Todo boxes become ☐ and ☑,
-- headings a symbol for their level, list dashes bullets, and due dates a
-- calendar and the day. The file stays plain Markdown; move the cursor onto
-- a line to edit what's really there. The symbols are buttons too:
-- clicking a box ticks it, a heading's symbol folds its section.
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
local notes = require("./notes")

local M = {}

local MONTHS =
	{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- "3 Oct" for this year, "3 Oct 2027" for another.
local function day(year: string, month: string, date: string): string
	local name = MONTHS[tonumber(month) or 0] or month
	local shown = `{tonumber(date)} {name}`
	return if year == string.sub(notes.today(), 1, 4) then shown else `{shown} {year}`
end

-- The marks for one line of text starting at `at`.
local function line_marks(text: string, at: number, out: { greed.Mark })
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
		local spaces = string.match(text, "^(%s*)[-*] ")
		if spaces then
			show(#spaces, #spaces + 2, symbols.bullet .. " ", "notes.bullet")
		end
	end
	for from, year, month, date, to in string.gmatch(text, "()due:(%d%d%d%d)%-(%d%d)%-(%d%d)()") do
		local overdue = `{year}-{month}-{date}` < notes.today()
		show(
			(from :: number) - 1,
			(to :: number) - 1,
			`{symbols.due} {day(year :: string, month :: string, date :: string)}`,
			if overdue then "notes.overdue" else "notes.due"
		)
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

greed.on("option.changed", function(event)
	if event.name == "notes-conceal" or event.name == "notes-everywhere" then
		M.refresh()
	end
end)

return M
