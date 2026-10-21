-- What notes say on a line, read the same way by everything that reads
-- notes (the index, the look, todos, reminders, links): todos with their
-- due dates and reminders, `[[links]]`, `#tags`, `^block-ids` and
-- `key:: value` fields. Plain functions of text: no files, no buffers.

local M = {}

--- A reminder on a line: where it is (its start and the index after its
--- end) and when: a date, with a time if it says one, or a time alone,
--- which goes off on the line's own days (its due date, each day it
--- repeats on, or else every day).
export type Reminder = { from: number, to: number, date: string?, time: string? }

--- The todo on `line` (a line of text), if it is one.
function M.parse(line: string): (boolean?, string?)
	local box, text = string.match(line, "^%s*[-*+] %[([ xX])%] (.*)$")
	if box == nil then
		return nil, nil
	end
	return box ~= " ", text
end

--- A date as markers write it, "2026-10-03", as a pattern.
local DATE = "%d%d%d%d%-%d%d%-%d%d"
M.DATE = DATE

--- The markers a date follows besides `due:`: when a repeat starts and
--- ends, and when a habit was last done ("from:2026-11-01").
M.DATED = { "from", "until", "done" }

--- When `text` says it's due ("due:2026-10-03", or the Tasks plugin's
--- "📅 2026-10-03"), if it does.
function M.due(text: string): string?
	return string.match(text, `due:({DATE})`) or string.match(text, `📅%s*({DATE})`)
end

-- A repeat as the Tasks plugin writes it after 🔁 ("every week on Monday",
-- "every 2 days"), as `every:` would.
local function tasks_every(words: string): string?
	local said = string.lower(words)
	local n, unit = string.match(said, "^every (%d+) (%a+)")
	if n and unit then
		return `{n}{(string.gsub(unit, "s$", ""))}s`
	end
	local on = string.match(said, "^every week on (.*)$")
	if on then
		local names = {}
		for name in string.gmatch(on, "%a+") do
			if name ~= "and" and name ~= "when" and name ~= "done" then
				table.insert(names, name)
			end
		end
		return table.concat(names, ",")
	end
	return string.match(said, "^every (%a+)")
end

--- How often `text` says it repeats, and whether as a habit: "every:monday"
--- (see `dates.Every`), "every:day!" for a habit, which comes up on each
--- of its days whether or not the one before was done, or the Tasks
--- plugin's "🔁 every week on Monday".
function M.every(text: string): (string?, boolean)
	local every, bang = string.match(text, "every:([%w,]+)(!?)")
	if every then
		return every, bang == "!"
	end
	-- Up to the next of the Tasks plugin's signs, which start with byte 240.
	local tasks = string.match(text, "🔁%s*([^\240]*)")
	if tasks then
		return tasks_every((string.gsub(tasks, "%s+$", ""))), false
	end
	return nil, false
end

--- When `text` says a repeat starts ("from:2026-11-01", or the Tasks
--- plugin's "🛫 2026-11-01"), if it does.
function M.starts(text: string): string?
	return string.match(text, `from:({DATE})`) or string.match(text, `🛫%s*({DATE})`)
end

--- When `text` says a repeat ends ("until:2027-06-30"), if it does: its
--- last day.
function M.ends(text: string): string?
	return (string.match(text, `until:({DATE})`))
end

--- The day a habit (see `every`) was last done, "done:2026-10-18", if it
--- says one.
function M.done_on(text: string): string?
	return (string.match(text, `done:({DATE})`))
end

--- `text` saying a habit was last done on `date`: changed where it says
--- it, or added at the end; without a date, not saying it.
function M.with_done(text: string, date: string?): string
	local from: any, to: any = string.match(text, `()%s*done:{DATE}()`)
	if from then
		text = string.sub(text, 1, from - 1) .. string.sub(text, to)
	end
	if date == nil then
		return text
	end
	local trimmed = string.gsub(text, "%s+$", "") :: string
	return if trimmed == "" then `done:{date}` else `{trimmed} done:{date}`
end

--- Where the marker `kind` ("due" or "remind") is in `text`: its start,
--- the index after its end, its date, and a reminder's time ("18:00" in
--- "remind:2026-10-06 18:00", or "remind:18:00", which has no date) if it
--- has one.
function M.marker(text: string, kind: "due" | "remind"): (number?, number?, string?, string?)
	-- Position captures, `()`, give numbers.
	local from: any, date, to: any = string.match(text, `(){kind}:({DATE})()`)
	if kind == "remind" then
		local at: any, time, after: any = string.match(text, "()remind:(%d%d?:%d%d)()")
		if at and (from == nil or at < from) then
			return at, after, nil, time
		end
	end
	if from == nil then
		return nil, nil, nil, nil
	end
	if kind == "remind" then
		local time, after: any = string.match(text, "^[ T](%d%d?:%d%d)()", to)
		if time then
			return from, after, date, time
		end
	end
	return from, to, date, nil
end

--- Every reminder in `text`, in the order they're written.
function M.reminders(text: string): { Reminder }
	local out: { Reminder } = {}
	if not string.find(text, "remind:", 1, true) then
		return out
	end
	local start = 1
	while true do
		local from, to, date, time = M.marker(string.sub(text, start), "remind")
		if from == nil or to == nil then
			return out
		end
		table.insert(
			out,
			{ from = start + from - 1, to = start + to - 1, date = date, time = time }
		)
		start += to - 1
	end
end

--- When `text` says to remind you, each as "2026-10-06 18:00", a date
--- alone, or a time alone ("18:00").
function M.reminds(text: string): { string }
	local out = {}
	for _, reminder in M.reminders(text) do
		local date, time = reminder.date, reminder.time
		table.insert(out, if date and time then `{date} {time}` else (date or time) :: string)
	end
	return out
end

--- `text` reminding you at each of `reminds` ("2026-10-06 18:00" or a
--- date alone) and no other time: the reminders it has go, and these are
--- added at the end, once each.
function M.with_reminds(text: string, reminds: { string }): string
	local reminders = M.reminders(text)
	for i = #reminders, 1, -1 do
		local reminder = reminders[i]
		local before = string.gsub(string.sub(text, 1, reminder.from - 1), " $", "") :: string
		text = before .. string.sub(text, reminder.to)
	end
	local seen = {}
	for _, when in reminds do
		if not seen[when] then
			seen[when] = true
			local trimmed = string.gsub(text, "%s+$", "") :: string
			text = if trimmed == "" then `remind:{when}` else `{trimmed} remind:{when}`
		end
	end
	return text
end

--- `text` with its due date set to `value` ("2026-10-06"): changed where
--- it is, or added at the end. Without a value the marker goes. A line can
--- have several reminders; `with_reminds` sets those.
function M.with_due(text: string, value: string?): string
	local from, to = M.marker(text, "due")
	local marker = if value then `due:{value}` else ""
	if from and to then
		local before, after = string.sub(text, 1, from - 1), string.sub(text, to)
		if value == nil then
			before = string.gsub(before, " $", "") :: string
		end
		return before .. marker .. after
	end
	if value == nil then
		return text
	end
	local trimmed = string.gsub(text, "%s+$", "") :: string
	return if trimmed == "" then marker else `{trimmed} {marker}`
end

--- `text` with its `[[links]]` as the words they show: `[[Anna]]` is
--- "Anna", `[[Books#The Overstory|The Overstory]]` "The Overstory", as a
--- line reads on a page that doesn't hide brackets as notes do.
function M.as_read(text: string): string
	if not string.find(text, "[[", 1, true) then
		return text
	end
	local found = M.links(text)
	for i = #found, 1, -1 do
		local link = found[i]
		text = string.sub(text, 1, link.from - 1)
			.. (link.shown or link.target)
			.. string.sub(text, link.to)
	end
	return text
end

-- The signs the Tasks plugin (as in Obsidian) puts before dates.
local TASKS_DATES = { "📅", "⏳", "🛫", "✅", "➕" }

--- `text` without its markers (due, remind, every, from, until and done,
--- and the Tasks plugin's dates and repeats), as a todo reads.
function M.plain(text: string): string
	local out = text
	if string.find(text, "every:", 1, true) then
		out = string.gsub(out, "%s*every:[%w,]+!?", "") :: string
	end
	for _, marker in M.DATED do
		if string.find(out, marker .. ":", 1, true) then
			out = string.gsub(out, `%s*{marker}:{DATE}`, "") :: string
		end
	end
	if string.find(out, "due:", 1, true) or string.find(out, "remind:", 1, true) then
		out = M.with_reminds(M.with_due(out, nil), {})
	end
	for _, sign in TASKS_DATES do
		if string.find(out, sign, 1, true) then
			out = string.gsub(out, `%s*{sign}%s*{DATE}`, "") :: string
		end
	end
	if string.find(out, "🔁", 1, true) then
		out = string.gsub(out, "%s*🔁[^\240]*", "") :: string
	end
	return (string.gsub(out, "^%s+", ""))
end

-- `text` with its inline code blanked out, the same length, so what's in
-- it isn't read as a link, a tag or a field.
local function without_code(text: string): string
	if not string.find(text, "`", 1, true) then
		return text
	end
	return (
		string.gsub(text, "`[^`]*`", function(code: string): string
			return string.rep(" ", #code)
		end)
	)
end

--- A `[[link]]` on a line, or an `![[embed]]`: where it is (`from` to the
--- index after its end, `to`, as position captures give them), the note
--- it names, the heading (`#Heading`) or block (`#^id`) in it, and the
--- text shown in its place (`|shown`, from `shown_from` to `shown_to`).
export type WikiLink = {
	from: number,
	to: number,
	target: string,
	heading: string?,
	block: string?,
	shown: string?,
	shown_from: number,
	shown_to: number,
	embed: boolean,
}

local function trim(text: string): string
	return string.match(text, "^%s*(.-)%s*$") :: string
end

-- The link whose `[[` is at `from` in `text`, matched in `scan` (`text`
-- with its inline code blanked), or nil when there's none there.
local function link_in(text: string, scan: string, from: number): WikiLink?
	local inside: any, to: any = string.match(scan, "^%[%[([^%]]+)%]%]()", from)
	if inside == nil then
		return nil
	end
	local embed = from > 1 and string.sub(text, from - 1, from - 1) == "!"
	local target, shown = string.match(inside, "^([^|]*)|(.*)$")
	local shown_from = from + 2
	if target and shown then
		shown_from += #target + 1
		-- In a table the bar is written `\|`, so as not to end a cell.
		target = string.gsub(target, "\\$", "") :: string
	else
		target = inside
	end
	local name, anchor = string.match(target :: string, "^([^#]*)#(.*)$")
	local block = if anchor then string.match(anchor, "^%^([%w%-]+)$") else nil
	return {
		from = if embed then from - 1 else from,
		to = to,
		target = trim(name or target :: string),
		heading = if anchor and not block then trim(anchor) else nil,
		block = block,
		shown = shown,
		shown_from = shown_from,
		shown_to = to - 2,
		embed = embed,
	}
end

--- The `[[link]]` whose `[[` is at `from` on a line without inline code,
--- or nil when there's none there.
function M.link_at(text: string, from: number): WikiLink?
	return link_in(text, text, from)
end

--- The `[[links]]` and `![[embeds]]` on a line, outside inline code.
function M.links(text: string): { WikiLink }
	local out: { WikiLink } = {}
	local scan = without_code(text)
	for from: any in string.gmatch(scan, "()%[%[[^%]]+%]%]") do
		table.insert(out, link_in(text, scan, from) :: WikiLink)
	end
	return out
end

-- What ends a tag: space and punctuation other than `_`, `-` and `/`.
local TAG = "^[^%s%.,;:!%?%(%)%[%]{}\"'`~@%$%%%^&%*=+<>|\\#]+"

--- A `#tag` on a line: its words, and the bytes they take (after the `#`).
export type Tag = { tag: string, from: number, to: number }

--- The `#tags` on a line, where they are, outside inline code: a `#` at
--- the start or after a space, then letters (any language), digits, `_`,
--- `-` and `/`, with something other than digits. A heading's `# ` isn't
--- one.
function M.tag_spans(text: string): { Tag }
	local out: { Tag } = {}
	-- The space put in front makes each place one more than in `text`.
	for at: any, raw: any in string.gmatch(" " .. without_code(text), "%s#()(%S+)") do
		local tag = string.match(raw, TAG)
		if tag and string.find(tag, "%D") then
			table.insert(out, { tag = tag, from = at - 1, to = at + #tag - 2 })
		end
	end
	return out
end

--- The `#tags` on a line, as written (see `M.tag_spans`).
function M.tags(text: string): { string }
	local out: { string } = {}
	for _, span in M.tag_spans(text) do
		table.insert(out, span.tag)
	end
	return out
end

--- The `^block-id` a line ends with, naming it for links (`[[note#^id]]`).
function M.block_id(text: string): string?
	return string.match(text, "%s%^([%w%-]+)%s*$") or string.match(text, "^%^([%w%-]+)%s*$")
end

--- The `key:: value` fields on a line: the whole line as one (after a list
--- item's bullet), or any number in brackets, `[key:: value]`. Keys are
--- trimmed and in lower case.
function M.fields(text: string): { [string]: string }
	local out: { [string]: string } = {}
	local plain = without_code(text)
	local key, value = string.match(plain, "^%s*[-*+]?%s*([^%[%]():]-)::%s*(.-)%s*$")
	if key and key ~= "" and not string.find(key, "%s%s") then
		out[string.lower(trim(key))] = value :: string
		return out
	end
	for inner in string.gmatch(plain, "[%[%(]([^%[%]%(%)]-::[^%[%]%(%)]*)[%]%)]") do
		local k, v = string.match(inner, "^([^:]+)::%s*(.-)%s*$")
		if k then
			out[string.lower(trim(k))] = v :: string
		end
	end
	return out
end

return M
