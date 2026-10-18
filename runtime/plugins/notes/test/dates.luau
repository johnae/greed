local test = require("@greed/test")
local notes = require("@notes")
local dates = notes.dates

-- Runs `f` with the clock at Wednesday 14 October 2026, 10:00.
local function on_a_wednesday(f: () -> ())
	local clock = notes.clock
	notes.clock = function(): number
		return os.time({ year = 2026, month = 10, day = 14, hour = 10, min = 0 } :: any)
	end
	local ok, err = pcall(function()
		f()
	end)
	notes.clock = clock
	assert(ok, tostring(err))
end

-- What `text` reads as: "text|date|time|every", "-" for what it doesn't say.
local function read(text: string): string
	local when = dates.read_words(text)
	return `{when.text}|{when.date or "-"}|{when.time or "-"}|{when.every or "-"}`
end

test("plain words say when: days, weekdays, dates and times", function()
	on_a_wednesday(function()
		local cases = {
			{ "call the bank tomorrow 18:00", "call the bank|2026-10-15|18:00|-" },
			{ "pay rent today", "pay rent|2026-10-14|-|-" },
			{ "dentist on friday at 9", "dentist|2026-10-16|09:00|-" },
			{ "dentist fri 2pm", "dentist|2026-10-16|14:00|-" },
			{ "standup wednesday", "standup|2026-10-14|-|-" },
			{ "plan the trip next week", "plan the trip|2026-10-19|-|-" },
			{ "taxes next month", "taxes|2026-11-01|-|-" },
			{ "renew passport in 3 weeks", "renew passport|2026-11-04|-|-" },
			{ "garden in 2 days", "garden|2026-10-16|-|-" },
			{ "party 31 dec", "party|2026-12-31|-|-" },
			{ "trip jan 5", "trip|2027-01-05|-|-" },
			{ "report due 2026-11-02", "report|2026-11-02|-|-" },
			{ "call mum 9:30pm", "call mum|2026-10-14|21:30|-" },
			{ "early call 8:00", "early call|2026-10-15|08:00|-" },
			{ "movie tonight", "movie|2026-10-14|20:00|-" },
			{ "buy 3 apples", "buy 3 apples|-|-|-" },
			{ "I may go", "I may go|-|-|-" },
		}
		for _, case in cases do
			assert(read(case[1]) == case[2], `{case[1]}: {read(case[1])}`)
		end
	end)
end)

test("repeats say how often, and when the first one is", function()
	on_a_wednesday(function()
		local cases = {
			{ "water plants every monday", "water plants|2026-10-19|-|monday" },
			{ "standup every weekday at 9:15", "standup|2026-10-14|09:15|weekday" },
			{ "take vitamins every day", "take vitamins|2026-10-14|-|day" },
			{ "pay rent every month on the 1st", "pay rent|2026-11-01|-|month" },
			{ "review goals every month on the 20th", "review goals|2026-10-20|-|month" },
			{ "birthday every year", "birthday|2026-10-14|-|year" },
		}
		for _, case in cases do
			assert(read(case[1]) == case[2], `{case[1]}: {read(case[1])}`)
		end
	end)
end)

test("a repeating todo comes back on its next date", function()
	assert(dates.next("2026-10-14", "day") == "2026-10-15")
	assert(dates.next("2026-10-16", "weekday") == "2026-10-19", "past the weekend")
	assert(dates.next("2026-10-14", "week") == "2026-10-21")
	assert(dates.next("2026-10-19", "monday") == "2026-10-26")
	assert(dates.next("2026-01-31", "month") == "2026-02-28", "the month's last day")
	assert(dates.next("2026-10-14", "year") == "2027-10-14")
end)
