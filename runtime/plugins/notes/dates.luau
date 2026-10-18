-- Dates and times as notes write them ("2026-10-06", "18:00"), and in
-- words ("tomorrow, 18:00, in 6 hours").

local notes = require("./notes")

local M = {}

--- Today's date.
function M.today(): string
	return notes.today()
end

-- A "YYYY-MM-DD" date at an "HH:MM" time (noon without one) in seconds, as
-- if it were UTC, which is how os.time reads a table; nil for something
-- that isn't a date.
local function utc(date: string, time: string?): number?
	local y, m, d = string.match(date, "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	local hour, min = 12, 0
	if time then
		local h, mi = string.match(time, "^(%d%d?):(%d%d)$")
		if h == nil then
			return nil
		end
		hour, min = tonumber(h) :: number, tonumber(mi) :: number
	end
	local month, day = tonumber(m) or 0, tonumber(d) or 0
	if y == nil or month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or min > 59 then
		return nil
	end
	local parts = { year = tonumber(y), month = month, day = day, hour = hour, min = min }
	return os.time(parts :: any)
end

--- How many days from today `date` is: 0 for today, 1 for tomorrow, -1
--- for yesterday. Nil for something that isn't a date.
function M.days(date: string): number?
	local day, today = utc(date), utc(M.today())
	if day == nil or today == nil then
		return nil
	end
	return math.floor((day - today) / 86400 + 0.5)
end

--- The moment `date` at `time` ("HH:MM") is, in local time, in seconds.
function M.moment(date: string, time: string): number?
	local as_utc = utc(date, time)
	if as_utc == nil then
		return nil
	end
	-- How far ahead of UTC local time is then, which daylight saving can
	-- change from now.
	local guess = as_utc - (os.time(os.date("*t", as_utc) :: any) - as_utc)
	local offset = os.time(os.date("*t", guess) :: any) - guess
	return as_utc - offset
end

local MONTHS =
	{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

--- "3 Oct" for this year, "3 Oct 2027" for another.
function M.short(date: string): string
	local y, m, d = string.match(date, "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if y == nil then
		return date
	end
	local shown = `{tonumber(d)} {MONTHS[tonumber(m) or 0] or m}`
	return if y == string.sub(M.today(), 1, 4) then shown else `{shown} {y}`
end

--- The day `date` is in words: "today", "tomorrow", "yesterday", the
--- weekday and date within the week either side ("Friday 9 Oct"), or the
--- date.
function M.day(date: string): string
	local days = M.days(date)
	if days == 0 then
		return "today"
	elseif days == 1 then
		return "tomorrow"
	elseif days == -1 then
		return "yesterday"
	end
	local at = utc(date)
	if days and at and math.abs(days) < 7 then
		return `{os.date("!%A", at)} {M.short(date)}`
	end
	return M.short(date)
end

local function count(n: number, unit: string): string
	return if n == 1 then `1 {unit}` else `{n} {unit}s`
end

--- How far `seconds` from now is: "in 20 minutes", "6 hours ago", "now".
function M.from_now(seconds: number): string
	local ahead = math.abs(seconds)
	local amount
	if ahead < 60 then
		return "now"
	elseif ahead < 3600 then
		amount = count(math.floor(ahead / 60), "minute")
	elseif ahead < 2 * 86400 then
		amount = count(math.floor(ahead / 3600), "hour")
	else
		amount = count(math.floor(ahead / 86400), "day")
	end
	return if seconds > 0 then `in {amount}` else `{amount} ago`
end

--- A due date in words: "due today", "due Friday 9 Oct, in 3 days",
--- "due yesterday, 1 day overdue".
function M.due_words(date: string): string
	local days = M.days(date) or 0
	local words = `due {M.day(date)}`
	if days > 1 then
		return `{words}, in {count(days, "day")}`
	elseif days < 0 then
		return `{words}, {count(-days, "day")} overdue`
	end
	return words
end

--- A reminder in words: "remind tomorrow, 18:00, in 25 hours".
function M.remind_words(date: string, time: string): string
	local at = M.moment(date, time)
	local words = `remind {M.day(date)}, {time}`
	return if at then `{words}, {M.from_now(at - notes.clock())}` else words
end

--- `date` moved `n` days on (back, for a negative `n`).
function M.add_days(date: string, n: number): string
	local at = utc(date)
	if at == nil then
		return date
	end
	return os.date("!%Y-%m-%d", at + n * 86400) :: string
end

--- `date` moved `n` months on, on the same day, or the month's last when
--- it hasn't that many.
function M.add_months(date: string, n: number): string
	local y, m, d = string.match(date, "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if y == nil then
		return date
	end
	local months = (tonumber(y) :: number) * 12 + (tonumber(m) :: number) - 1 + n
	local year, month = months // 12, months % 12 + 1
	local last = tonumber(
		os.date("!%d", os.time({ year = year, month = month + 1, day = 0, hour = 12 } :: any))
	)
	return string.format(
		"%04d-%02d-%02d",
		year,
		month,
		math.min(tonumber(d) :: number, last :: number)
	)
end

local WEEKDAYS = { "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday" }

--- The weekday `date` falls on, 1 for Monday to 7 for Sunday.
function M.weekday(date: string): number
	local at = utc(date) or 0
	local wday = tonumber(os.date("!%w", at)) :: number -- 0 for Sunday
	return if wday == 0 then 7 else wday
end

-- The weekday a word names (1 for Monday), as written in full or cut short
-- to three letters.
local function weekday_of(word: string): number?
	for i, name in WEEKDAYS do
		if word == name or word == string.sub(name, 1, 3) then
			return i
		end
	end
	return nil
end

-- The first date from `from` (that day included, with `same`) on weekday
-- `wanted`.
local function next_weekday(from: string, wanted: number, same: boolean): string
	local ahead = (wanted - M.weekday(from)) % 7
	if ahead == 0 and not same then
		ahead = 7
	end
	return M.add_days(from, ahead)
end

local MONTH_NAMES =
	{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" }

local function month_of(word: string): number?
	for i, name in MONTH_NAMES do
		if string.sub(word, 1, 3) == name and #word >= 3 then
			return i
		end
	end
	return nil
end

-- The next date on day `day` of month `month` from today: this year's,
-- or next year's once it's past.
local function next_date(month: number, day: number): string?
	local today = M.today()
	local year = tonumber(string.sub(today, 1, 4)) :: number
	local date = string.format("%04d-%02d-%02d", year, month, day)
	if utc(date) == nil then
		return nil
	end
	return if date < today then string.format("%04d-%02d-%02d", year + 1, month, day) else date
end

--- How often a repeating todo comes back: "day", "weekday" (Monday to
--- Friday), "week", "month", "year", or a weekday's name ("monday").
export type Every = string

--- The date after `date` that a todo repeating `every` comes back on.
function M.next(date: string, every: Every): string
	if every == "day" then
		return M.add_days(date, 1)
	elseif every == "weekday" then
		local next = M.add_days(date, 1)
		while M.weekday(next) > 5 do
			next = M.add_days(next, 1)
		end
		return next
	elseif every == "month" then
		return M.add_months(date, 1)
	elseif every == "year" then
		return M.add_months(date, 12)
	end
	-- A week, or a weekday's name: a week on.
	return M.add_days(date, 7)
end

--- When plain words in some text say: the text without them, the date,
--- the time ("18:00") and how often it repeats, each when they say one.
export type When = { text: string, date: string?, time: string?, every: Every? }

-- A time in words, as "18:00": "18:00", "18.30", "6pm", "6:30pm", "at 6".
local function time_of(words: string, at_word: boolean): string?
	local h, m = string.match(words, "^(%d%d?)[:.](%d%d)$")
	local suffix: string? = nil
	if h == nil then
		h, m, suffix = string.match(words, "^(%d%d?)[:.](%d%d)([ap]m)$")
	end
	if h == nil then
		h, suffix = string.match(words, "^(%d%d?)([ap]m)$")
		m = "00"
	end
	if h == nil and at_word then
		h = string.match(words, "^(%d%d?)$")
		m = "00"
	end
	local hour = tonumber(h)
	if hour == nil or m == nil then
		return nil
	end
	if suffix == "pm" and hour < 12 then
		hour += 12
	elseif suffix == "am" and hour == 12 then
		hour = 0
	end
	if hour > 23 or (tonumber(m) :: number) > 59 then
		return nil
	end
	return string.format("%02d:%s", hour, m :: string)
end

--- Reads when `text` says something is, in plain words, and takes those
--- words out: "call the bank tomorrow 18:00" is "call the bank" tomorrow
--- at 18:00. It knows today, tonight, tomorrow, weekdays ("friday", "on
--- fri"), "next week" and "next month", "in 3 days" (weeks, months), dates
--- ("2026-10-20", "20 oct", "oct 20"), times ("18:00", "6pm", "at 6") and
--- repeats ("every day", "every weekday", "every monday", "every week",
--- "every month", "every month on the 1st", "every year"). A time alone is
--- today's, or tomorrow's once it has gone by.
function M.read_words(text: string): When
	local words = string.split(text, " ")
	local keep: { boolean } = {}
	for i in words do
		keep[i] = true
	end
	local lower: { string } = {}
	for i, word in words do
		lower[i] = string.lower(word)
	end
	local today = M.today()
	local date: string?, time: string?, every: Every? = nil, nil, nil
	-- Takes words `from` to `to` out, and the "on", "at", "by" or "due" before them.
	local function take(from: number, to: number)
		for i = from, to do
			keep[i] = false
		end
		local before = lower[from - 1]
		if before == "on" or before == "at" or before == "by" or before == "due" then
			keep[from - 1] = false
		end
	end
	local i = 1
	while i <= #words do
		local w, w2, w3 = lower[i], lower[i + 1], lower[i + 2]
		local day = weekday_of(w)
		if w == "every" and w2 then
			local repeat_day = weekday_of(w2)
			if
				w2 == "month"
				and w3 == "on"
				and lower[i + 3] == "the"
				and string.match(lower[i + 4] or "", "^%d%d?%a%a$")
			then
				local n = tonumber(string.match(lower[i + 4], "^(%d+)")) :: number
				every = "month"
				local this = string.format("%s-%02d", string.sub(today, 1, 7), n)
				date = if this >= today then this else M.add_months(this, 1)
				take(i, i + 4)
				i += 5
				continue
			elseif repeat_day then
				every = WEEKDAYS[repeat_day]
				date = date or next_weekday(today, repeat_day, true)
				take(i, i + 1)
				i += 2
				continue
			elseif
				w2 == "day"
				or w2 == "weekday"
				or w2 == "week"
				or w2 == "month"
				or w2 == "year"
			then
				every = w2
				date = date
					or (
						if w2 == "weekday" and M.weekday(today) > 5
							then M.next(today, "weekday")
							else today
					)
				take(i, i + 1)
				i += 2
				continue
			end
		end
		if w == "today" then
			date = today
			take(i, i)
		elseif w == "tonight" then
			date, time = today, time or "20:00"
			take(i, i)
		elseif w == "tomorrow" then
			date = M.add_days(today, 1)
			take(i, i)
		elseif w == "next" and w2 == "week" then
			date = next_weekday(today, 1, false)
			take(i, i + 1)
			i += 1
		elseif w == "next" and w2 == "month" then
			date = M.add_months(string.sub(today, 1, 8) .. "01", 1)
			take(i, i + 1)
			i += 1
		elseif w == "in" and tonumber(w2) and w3 and string.match(w3, "^%a+$") then
			local n = tonumber(w2) :: number
			local unit = string.gsub(w3, "s$", "")
			local found = if unit == "day"
				then M.add_days(today, n)
				elseif unit == "week" then M.add_days(today, 7 * n)
				elseif unit == "month" then M.add_months(today, n)
				else nil
			if found then
				date = found
				take(i, i + 2)
				i += 2
			end
		elseif day then
			date = next_weekday(today, day, true)
			take(i, i)
		elseif string.match(w, "^%d%d%d%d%-%d%d%-%d%d$") and utc(w) then
			date = w
			take(i, i)
		elseif string.match(w, "^%d%d?$") and w2 and month_of(w2) then
			local found = next_date(month_of(w2) :: number, tonumber(w) :: number)
			if found then
				date = found
				take(i, i + 1)
				i += 1
			end
		elseif month_of(w) and w2 and string.match(w2, "^%d%d?$") then
			local found = next_date(month_of(w) :: number, tonumber(w2) :: number)
			if found then
				date = found
				take(i, i + 1)
				i += 1
			end
		else
			local found = time_of(w, lower[i - 1] == "at")
			if found then
				time = found
				take(i, i)
			end
		end
		i += 1
	end
	if time and date == nil then
		local now = os.date("%H:%M", notes.clock()) :: string
		date = if time > now then today else M.add_days(today, 1)
	end
	local kept: { string } = {}
	for n, word in words do
		if keep[n] and word ~= "" then
			table.insert(kept, word)
		end
	end
	return { text = table.concat(kept, " "), date = date, time = time, every = every }
end

return M
