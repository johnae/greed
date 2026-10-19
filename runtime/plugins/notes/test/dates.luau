-- Dates as notes say them: due dates and reminders in words, and the clock
-- notes share with core.dates (reading plain words is core.dates', tested
-- there).

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

test("due dates and reminders read in words", function()
	on_a_wednesday(function()
		assert(dates.due_words("2026-10-14") == "due today", dates.due_words("2026-10-14"))
		local soon = dates.due_words("2026-10-17")
		assert(string.find(soon, "in 3 days", 1, true), soon)
		local late = dates.due_words("2026-10-12")
		assert(string.find(late, "2 days overdue", 1, true), late)
		local remind = dates.remind_words("2026-10-15", "18:00")
		assert(string.find(remind, "remind tomorrow, 18:00, in ", 1, true), remind)
	end)
end)

test("setting the notes' clock sets the one core.dates reads", function()
	on_a_wednesday(function()
		assert(notes.today() == "2026-10-14", notes.today())
		assert(dates.today() == "2026-10-14", dates.today())
		assert(require("@core").dates.today() == "2026-10-14")
	end)
end)
