local test = require("@greed/test")
local dates = require("@core").dates

-- Runs `f` with the clock at Wednesday 14 October 2026, 10:00.
local function on_a_wednesday(f: () -> ())
	local clock = dates.clock
	dates.clock = function(): number
		return os.time({ year = 2026, month = 10, day = 14, hour = 10, min = 0 } :: any)
	end
	local ok, err = pcall(function()
		f()
	end)
	dates.clock = clock
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

test("repeats come back on their next day: weekdays, several, every few", function()
	local cases = {
		{ "2026-10-14", "monday", "2026-10-19" },
		{ "2026-10-14", "monday,thursday", "2026-10-15" },
		{ "2026-10-15", "monday,thursday", "2026-10-19" },
		{ "2026-10-16", "weekday", "2026-10-19" },
		{ "2026-10-14", "2weeks", "2026-10-28" },
		{ "2026-10-14", "3days", "2026-10-17" },
		{ "2026-01-31", "month", "2026-02-28" },
	}
	for _, case in cases do
		local got = dates.next(case[1], case[2])
		assert(got == case[3], `{case[2]} after {case[1]}: {got}`)
	end
	assert(dates.known("mon,thu") and dates.known("2weeks") and not dates.known("sometimes"))
end)

test("a repeat falls on its days, counting from its start", function()
	assert(dates.falls_on("2026-10-15", "monday,thursday"), "a Thursday")
	assert(not dates.falls_on("2026-10-14", "monday,thursday"), "a Wednesday")
	assert(dates.falls_on("2026-10-28", "2weeks", "2026-10-14"), "two weeks on")
	assert(not dates.falls_on("2026-10-21", "2weeks", "2026-10-14"), "one week on")
	assert(dates.falls_on("2026-12-14", "month", "2026-10-14"), "two months on")
	assert(not dates.falls_on("2026-10-13", "day", "2026-10-14"), "before it starts")
	assert(dates.every_words("monday,thursday") == "every Mon, Thu", dates.every_words("mon,thu"))
	assert(dates.every_words("2weeks") == "every 2 weeks")
end)

-- What `text` reads as: "text|date|times|every|habit|from|until".
local function read_all(text: string): string
	local w = dates.read_words(text)
	return table.concat({
		w.text,
		w.date or "-",
		table.concat(w.times, ","),
		w.every or "-",
		if w.habit then "habit" else "-",
		w.from or "-",
		w["until"] or "-",
	}, "|")
end

test("plain words say how often, as a habit or not, several times, from and until", function()
	on_a_wednesday(function()
		local cases = {
			{ "vitamins every day! at 8", "vitamins|2026-10-14|08:00|day|habit|-|-" },
			{
				"water plants every monday and thursday at 18",
				"water plants|2026-10-15|18:00|monday,thursday|-|-|-",
			},
			{ "pay rent every 2 weeks", "pay rent|2026-10-14||2weeks|-|-|-" },
			{ "air the room every other day", "air the room|2026-10-14||2days|-|-|-" },
			{
				"stretch every weekday at 10:30 and 15:00 from nov 2",
				"stretch|2026-11-02|10:30,15:00|weekday|-|2026-11-02|-",
			},
			{ "pills every day until december", "pills|2026-10-14||day|-|-|2026-12-31" },
			{
				"gym every mon, wed until 2027-01-31",
				"gym|2026-10-14||monday,wednesday|-|-|2027-01-31",
			},
		}
		for _, case in cases do
			local got = read_all(case[1])
			assert(got == case[2], `{case[1]}: {got}`)
		end
	end)
end)

test("weeks are counted as ISO 8601 counts them", function()
	local year, week, monday = dates.week("2026-10-18")
	assert(year == 2026 and week == 42 and monday == "2026-10-12", `{year} {week} {monday}`)
	local year2, week2, monday2 = dates.week("2027-01-01")
	assert(year2 == 2026 and week2 == 53 and monday2 == "2026-12-28", `{year2} {week2} {monday2}`)
	local year3, week3 = dates.week("2026-01-01")
	assert(year3 == 2026 and week3 == 1, `{year3} {week3}`)
end)
