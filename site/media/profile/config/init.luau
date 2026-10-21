-- The config the demos run with: a fresh Greed in Catppuccin Frappé with
-- pills on the status line, a little bigger to read in a video, and
-- nothing of the machine it's recorded on.
local greed = require("@greed")

require("@theme").use("catppuccin-frappe")
greed.option.set("statusline-pills", true)
greed.option.set("gui-font-size", 17)
require("@statusline").remove("host")

-- Always the same morning, so the notes' agenda, due dates and the mail
-- list's times record the same each time; the clock still runs from there.
local core = require("@core")
local started = os.time()
local morning = os.time({ year = 2026, month = 10, day = 21, hour = 9, min = 30 })
core.dates.set_clock(function(): number
	return morning + os.time() - started
end)

-- Hoard's home fits the recording's 800 pixels with five recent notes.
require("@hoard").home.RECENT = 5

-- The agent demo's model, scripted.
require("@self/model")
