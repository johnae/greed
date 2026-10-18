-- What notes say on a line, read the same way by everything that reads
-- notes (the index, the look, todos, reminders, links): todos with their
-- due dates and reminders, `[[links]]`, `#tags`, `^block-ids` and
-- `key:: value` fields. Plain functions of text: no files, no buffers.

local M = {}

--- A reminder on a line: where it is (its start and the index after its
--- end) and when, with a time if it says one.
export type Reminder = { from: number, to: number, date: string, time: string? }

--- The todo on `line` (a line of text), if it is one.
function M.parse(line: string): (boolean?, string?)
	local box, text = string.match(line, "^%s*[-*+] %[([ xX])%] (.*)$")
	if box == nil then
		return nil, nil
	end
	return box ~= " ", text
end

--- When `text` says it's due ("due:2026-10-03"), if it does.
function M.due(text: string): string?
	return string.match(text, "due:(%d%d%d%d%-%d%d%-%d%d)")
end

--- Where the marker `kind` ("due" or "remind") is in `text`: its start,
--- the index after its end, its date, and a reminder's time ("18:00" in
--- "remind:2026-10-06 18:00") if it has one.
function M.marker(text: string, kind: "due" | "remind"): (number?, number?, string?, string?)
	-- Position captures, `()`, give numbers.
	local from: any, date, to: any = string.match(text, `(){kind}:(%d%d%d%d%-%d%d%-%d%d)()`)
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
		if from == nil or to == nil or date == nil then
			return out
		end
		table.insert(
			out,
			{ from = start + from - 1, to = start + to - 1, date = date, time = time }
		)
		start += to - 1
	end
end

--- When `text` says to remind you, each as "2026-10-06 18:00" or a date
--- alone.
function M.reminds(text: string): { string }
	local out = {}
	for _, reminder in M.reminders(text) do
		table.insert(
			out,
			if reminder.time then `{reminder.date} {reminder.time}` else reminder.date
		)
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

--- `text` without its due and remind markers, as a todo reads.
function M.plain(text: string): string
	local out = text
	if string.find(text, "due:", 1, true) or string.find(text, "remind:", 1, true) then
		out = M.with_reminds(M.with_due(text, nil), {})
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

--- The `[[links]]` and `![[embeds]]` on a line, outside inline code.
function M.links(text: string): { WikiLink }
	local out: { WikiLink } = {}
	for from: any, inside: any, to: any in string.gmatch(without_code(text), "()%[%[([^%]]+)%]%]()") do
		local embed = from > 1 and string.sub(text, from - 1, from - 1) == "!"
		local target, shown = string.match(inside, "^([^|]*)|(.*)$")
		local shown_from = from + 2
		if target and shown then
			shown_from += #target + 1
		else
			target = inside
		end
		local name, anchor = string.match(target :: string, "^([^#]*)#(.*)$")
		local block = if anchor then string.match(anchor, "^%^([%w%-]+)$") else nil
		table.insert(out, {
			from = if embed then from - 1 else from,
			to = to,
			target = trim(name or target :: string),
			heading = if anchor and not block then trim(anchor) else nil,
			block = block,
			shown = shown,
			shown_from = shown_from,
			shown_to = to - 2,
			embed = embed,
		})
	end
	return out
end

-- What ends a tag: space and punctuation other than `_`, `-` and `/`.
local TAG = "^[^%s%.,;:!%?%(%)%[%]{}\"'`~@%$%%%^&%*=+<>|\\#]+"

--- The `#tags` on a line, as written, outside inline code: a `#` at the
--- start or after a space, then letters (any language), digits, `_`, `-`
--- and `/`, with something other than digits. A heading's `# ` isn't one.
function M.tags(text: string): { string }
	local out: { string } = {}
	for raw in string.gmatch(" " .. without_code(text), "%s#(%S+)") do
		local tag = string.match(raw, TAG)
		if tag and string.find(tag, "%D") then
			table.insert(out, tag)
		end
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
