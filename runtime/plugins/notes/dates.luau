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

return M
