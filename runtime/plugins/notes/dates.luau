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

--- The week `date` is in, as ISO 8601 counts them: its year, its number
--- (1 to 53), and its Monday.
function M.week(date: string): (number, number, string)
	local monday = M.add_days(date, 1 - M.weekday(date))
	-- A week belongs to the year its Thursday is in.
	local thursday = M.add_days(monday, 3)
	local year = tonumber(string.sub(thursday, 1, 4)) :: number
	local first = string.format("%04d-01-01", year)
	local days = math.floor(((utc(thursday) or 0) - (utc(first) or 0)) / 86400 + 0.5)
	return year, days // 7 + 1, monday
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

--- How often something repeats, as `every:` writes it: "day", "weekday"
--- (Monday to Friday), "week", "month", "year", weekdays by name, one or
--- several ("monday", "mon,thu"), or a count of days, weeks, months or
--- years ("2weeks", "3days").
export type Every = string

-- What an `every` says: the weekdays it falls on (1 for Monday), or a
-- step of `n` days, weeks, months or years.
type Rule = { days: { [number]: boolean }?, n: number, unit: string }

-- The units a repeat steps in.
local UNITS = { day = true, week = true, month = true, year = true }

-- The unit `word` names, one or several ("weeks" is "week"), if it's one.
local function unit_of(word: string): string?
	local unit = string.gsub(word, "s$", "") :: string
	return if UNITS[unit] then unit else nil
end

local function rule_of(every: Every): Rule?
	if UNITS[every] then
		return { days = nil, n = 1, unit = every :: string }
	elseif every == "weekday" then
		return { days = { true, true, true, true, true }, n = 1, unit = "day" }
	end
	local n, word = string.match(every, "^(%d+)(%a+)$")
	if n and word then
		local count, unit = tonumber(n) :: number, unit_of(word)
		if count < 1 or unit == nil then
			return nil
		end
		return { days = nil, n = count, unit = unit }
	end
	local days: { [number]: boolean } = {}
	for name in string.gmatch(every, "[^,]+") do
		local day = weekday_of(name)
		if day == nil then
			return nil
		end
		days[day] = true
	end
	return if next(days) then { days = days, n = 1, unit = "day" } else nil
end

--- Whether `every` is a repeat this knows (see `Every`).
function M.known(every: Every): boolean
	return rule_of(every) ~= nil
end

-- Whether `every` falls on days of the week rather than stepping on.
local function by_weekday(every: Every): boolean
	local rule = rule_of(every)
	return rule ~= nil and rule.days ~= nil
end

--- Whether something repeating `every` counts from the day it began
--- (every week, month or year, every 2 days), rather than falling on
--- days of the week.
function M.counted(every: Every): boolean
	local rule = rule_of(every)
	return rule ~= nil and rule.days == nil and not (rule.unit == "day" and rule.n == 1)
end

--- How often `every` repeats, in words: "every day", "every Mon, Thu",
--- "every 2 weeks".
function M.every_words(every: Every): string
	local rule = rule_of(every)
	if rule == nil then
		return `every {every}`
	end
	local days = rule.days
	if every == "weekday" then
		return "every weekday"
	elseif days then
		local names = {}
		for day = 1, 7 do
			if days[day] then
				local name = WEEKDAYS[day]
				table.insert(names, string.upper(string.sub(name, 1, 1)) .. string.sub(name, 2, 3))
			end
		end
		return `every {table.concat(names, ", ")}`
	end
	return if rule.n == 1 then `every {rule.unit}` else `every {rule.n} {rule.unit}s`
end

-- `date` moved on `n` units.
local function step(date: string, n: number, unit: string): string
	if unit == "day" then
		return M.add_days(date, n)
	elseif unit == "week" then
		return M.add_days(date, 7 * n)
	elseif unit == "month" then
		return M.add_months(date, n)
	end
	return M.add_months(date, 12 * n)
end

--- The date after `date` that something repeating `every` comes back on.
function M.next(date: string, every: Every): string
	local rule: Rule = rule_of(every) or { days = nil, n = 1, unit = "week" }
	local days = rule.days
	if days then
		local after = M.add_days(date, 1)
		while not days[M.weekday(after)] do
			after = M.add_days(after, 1)
		end
		return after
	end
	return step(date, rule.n, rule.unit)
end

-- Whole days from `from` to `to`.
local function between(from: string, to: string): number
	return math.floor(((utc(to) or 0) - (utc(from) or 0)) / 86400 + 0.5)
end

--- Whether something repeating `every` falls on `date`. Steps of days,
--- weeks, months and years count from `start`, the day it began (`date`
--- itself without one); nothing falls before it.
function M.falls_on(date: string, every: Every, start: string?): boolean
	local rule = rule_of(every)
	if rule == nil then
		return false
	end
	local from = start or date
	if date < from then
		return false
	end
	local days = rule.days
	if days then
		return days[M.weekday(date)] == true
	elseif rule.unit == "day" or rule.unit == "week" then
		local length = if rule.unit == "day" then rule.n else 7 * rule.n
		return between(from, date) % length == 0
	end
	local per = if rule.unit == "month" then rule.n else 12 * rule.n
	local months = (
		tonumber(string.sub(date, 1, 4)) :: number - tonumber(string.sub(from, 1, 4)) :: number
	)
			* 12
		+ tonumber(string.sub(date, 6, 7)) :: number
		- tonumber(string.sub(from, 6, 7)) :: number
	return months % per == 0 and M.add_months(from, months) == date
end

--- Whether `date` is one of a line's days: from `starts` to `ends`, each
--- when it says one, and on a day `every` falls on (any day without).
function M.on_days(date: string, every: Every?, starts: string?, ends: string?): boolean
	if (starts and date < starts) or (ends and date > ends) then
		return false
	end
	return every == nil or M.falls_on(date, every, starts)
end

--- When plain words in some text say: the text without them, the date,
--- the times ("18:00", the first also as `time`), how often it repeats and
--- whether as a habit, and from and until when, each when they say one.
export type When = {
	text: string,
	date: string?,
	time: string?,
	times: { string },
	every: Every?,
	habit: boolean,
	from: string?,
	["until"]: string?,
}

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
--- ("2026-10-20", "20 oct", "oct 20"), times ("18:00", "6pm", "at 6",
--- several: "at 9 and 17:00"), repeats ("every day", "every weekday",
--- "every monday and thursday", "every 2 weeks", "every other day", "every
--- month", "every month on the 1st", "every year"; a "!" after one makes
--- it a habit: "every day!"), and "from" and "until" a date or a month
--- ("until december" is to its end). A time alone is today's, or
--- tomorrow's once it has gone by.
function M.read_words(text: string): When
	local words = string.split(text, " ")
	local keep: { boolean } = {}
	for i in words do
		keep[i] = true
	end
	-- Each word in lower case, without a "!" or "," at its end; `bang` says
	-- where there was a "!".
	local lower: { string } = {}
	local bang: { boolean } = {}
	for i, word in words do
		local w = string.lower(word)
		bang[i] = string.sub(w, -1) == "!"
		lower[i] = (string.gsub(w, "[!,]+$", ""))
	end
	local today = M.today()
	local date: string?, every: Every?, habit = nil, nil, false
	local from: string?, till: string? = nil, nil
	local times: { string } = {}
	-- Takes words `first` to `last` out, and the "on", "at", "by" or "due"
	-- before them.
	local function take(first: number, last: number)
		for i = first, last do
			keep[i] = false
		end
		local before = lower[first - 1]
		if before == "on" or before == "at" or before == "by" or before == "due" then
			keep[first - 1] = false
		end
	end
	-- A date written at word `i`: how many words it takes, and the date
	-- (a month alone is its first day, or its last with `ending`).
	local function date_at(i: number, ending: boolean): (number, string?)
		local w, w2 = lower[i], lower[i + 1]
		if w == nil then
			return 0, nil
		elseif string.match(w, "^%d%d%d%d%-%d%d%-%d%d$") and utc(w) then
			return 1, w
		elseif w == "today" then
			return 1, today
		elseif w == "tomorrow" then
			return 1, M.add_days(today, 1)
		elseif string.match(w, "^%d%d?$") and w2 and month_of(w2) then
			return 2, next_date(month_of(w2) :: number, tonumber(w) :: number)
		elseif month_of(w) and w2 and string.match(w2, "^%d%d?$") then
			return 2, next_date(month_of(w) :: number, tonumber(w2) :: number)
		elseif month_of(w) then
			local first = next_date(month_of(w) :: number, 1)
			if first == nil then
				return 0, nil
			end
			-- This month, while it lasts, rather than next year's.
			if string.sub(first, 1, 7) == string.sub(M.add_months(today, 12), 1, 7) then
				first = M.add_months(first, -12)
			end
			return 1, if ending then M.add_days(M.add_months(first, 1), -1) else first
		end
		local day = weekday_of(w)
		if day then
			return 1, next_weekday(today, day, true)
		end
		return 0, nil
	end
	-- The repeat starting at word `i` (after "every"): how many words it
	-- takes, and what it is.
	local function repeat_at(i: number): (number, Every?)
		local w, w2 = lower[i], lower[i + 1]
		if w == nil then
			return 0, nil
		end
		local count = if w == "other" then 2 else tonumber(w)
		local unit = if count and w2 then unit_of(w2) else nil
		if unit then
			return 2, if count == 1 then unit else `{count}{unit}s`
		end
		if w == "weekday" or UNITS[w] then
			return 1, w
		end
		-- Weekdays, one or several: "monday and thursday", "mon, thu".
		local names: { string } = {}
		local n = i
		while lower[n] do
			local day = weekday_of(lower[n])
			if day then
				table.insert(names, WEEKDAYS[day])
				n += 1
			elseif lower[n] == "and" and lower[n + 1] and weekday_of(lower[n + 1]) then
				n += 1
			else
				break
			end
		end
		if #names > 0 then
			return n - i, table.concat(names, ",")
		end
		return 0, nil
	end
	local i = 1
	while i <= #words do
		local w, w2, w3 = lower[i], lower[i + 1], lower[i + 2]
		if w == "every" and w2 then
			local used, found = repeat_at(i + 1)
			if found then
				every = found
				habit = bang[i + used]
				local last = i + used
				if
					found == "month"
					and lower[last + 1] == "on"
					and lower[last + 2] == "the"
					and string.match(lower[last + 3] or "", "^%d%d?%a%a$")
				then
					local n = tonumber(string.match(lower[last + 3], "^(%d+)")) :: number
					local this = string.format("%s-%02d", string.sub(today, 1, 7), n)
					date = if this >= today then this else M.add_months(this, 1)
					habit = habit or bang[last + 3]
					last += 3
				elseif by_weekday(found) then
					date = date or M.next(M.add_days(today, -1), found)
				else
					date = date or today
				end
				take(i, last)
				i = last + 1
				continue
			end
		end
		if (w == "from" or w == "until" or w == "till") and w2 then
			local used, found = date_at(i + 1, w ~= "from")
			if found then
				if w == "from" then
					from = found
				else
					till = found
				end
				take(i, i + used)
				i += used + 1
				continue
			end
		end
		if w == "tonight" then
			date = today
			table.insert(times, "20:00")
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
		else
			local used: number, found: string? = 0, nil
			-- A month alone isn't a date here: "may" is a word too.
			if not (month_of(w) and not (w2 and string.match(w2, "^%d%d?$"))) then
				used, found = date_at(i, false)
			end
			if found then
				date = found
				take(i, i + used - 1)
				i += used - 1
			else
				local after = lower[i - 1] == "at" or (lower[i - 1] == "and" and #times > 0)
				local time = time_of(w, after)
				if time then
					table.insert(times, time)
					take(i, i)
					if lower[i - 1] == "and" and #times > 1 then
						keep[i - 1] = false
					end
				end
			end
		end
		i += 1
	end
	if #times > 0 and date == nil and every == nil then
		local now = os.date("%H:%M", notes.clock()) :: string
		date = if times[1] > now then today else M.add_days(today, 1)
	end
	if from and every and date and date < from then
		date = if by_weekday(every) and not M.falls_on(from, every)
			then M.next(from, every)
			else from
	end
	local kept: { string } = {}
	for n, word in words do
		if keep[n] and word ~= "" then
			table.insert(kept, word)
		end
	end
	return {
		text = table.concat(kept, " "),
		date = date,
		time = times[1],
		times = times,
		every = every,
		habit = habit,
		from = from,
		["until"] = till,
	}
end

return M
