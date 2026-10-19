-- Dates as notes say them: core.dates (reading plain words, repeats, days
-- and weeks), with how a todo's due date and a reminder read in words.

local core = require("@core")

local dates = core.dates

local function count(n: number, unit: string): string
	return if n == 1 then `1 {unit}` else `{n} {unit}s`
end

--- A due date in words: "due today", "due Friday 9 Oct, in 3 days",
--- "due yesterday, 1 day overdue".
local function due_words(date: string): string
	local days = dates.days(date) or 0
	local words = `due {dates.day(date)}`
	if days > 1 then
		return `{words}, in {count(days, "day")}`
	elseif days < 0 then
		return `{words}, {count(-days, "day")} overdue`
	end
	return words
end

--- A reminder in words: "remind tomorrow, 18:00, in 25 hours".
local function remind_words(date: string, time: string): string
	local at = dates.moment(date, time)
	local words = `remind {dates.day(date)}, {time}`
	return if at then `{words}, {dates.from_now(at - dates.clock())}` else words
end

local M: typeof(dates) & { due_words: typeof(due_words), remind_words: typeof(remind_words) } = setmetatable(
	{ due_words = due_words, remind_words = remind_words },
	{ __index = dates }
) :: any

return M
