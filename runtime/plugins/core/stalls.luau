-- :stalls lists the times plugin code held the editor up, newest first,
-- with the plugin and what it was running, to trace a freeze to its cause.

local greed = require("@greed")

-- The list while it's shown.
local shown: greed.View? = nil

local function close()
	if shown then
		shown:close()
		shown = nil
	end
end

greed.on("view.closed", function(event: greed.ViewClosed)
	if shown and shown:id() == event.view then
		shown = nil
	end
end)

--- The lines of the list, newest first.
local function lines(): { string }
	local stalls = greed.stalls()
	if #stalls == 0 then
		return { "Nothing has held the editor up for 50 ms or more." }
	end
	local out = {}
	for _, stall in stalls do
		local at = os.date("%H:%M:%S", math.floor(stall.time))
		table.insert(
			out,
			`{at}  {math.floor(stall.ms)} ms  {stall.plugin or "Greed"}  {stall.what}`
		)
	end
	return out
end

greed.command({
	name = "stalls",
	doc = "List the times plugin code held the editor up, with the plugin and what it ran",
	run = function()
		close()
		local buffer =
			greed.create_buffer("stalls", table.concat(lines(), "\n"), { readonly = true })
		shown =
			greed.float(buffer, { title = "Stalls, newest first", width = "80%", height = "60%" })
	end,
})

-- The profile taken, as lines: the most time first.
local function profile_lines(rows: { greed.ProfileRow }, seconds: number): { string }
	local out = {
		string.format("%.1f s of use. Time spent per plugin and what it was doing:", seconds),
		"",
		string.format("%10s %8s %10s  %s", "total", "runs", "longest", "what"),
	}
	for _, row in rows do
		table.insert(
			out,
			string.format(
				"%8.1fms %8d %8.2fms  %s: %s",
				row.ms,
				row.runs,
				row.longest,
				row.plugin or "Greed",
				row.what
			)
		)
	end
	return out
end

-- When the profile being taken started, on the editor's clock.
local started: number? = nil

greed.command({
	name = "profile",
	doc = "Start counting where the editor's time goes; again, stop and show it, the most time first",
	run = function()
		if started == nil then
			greed.profile.start()
			started = greed.now()
			greed.echo("profiling: use the editor as usual, then :profile again")
			return
		end
		local seconds = (greed.now() - started) / 1000
		started = nil
		close()
		local text = table.concat(profile_lines(greed.profile.stop(), seconds), "\n")
		local buffer = greed.create_buffer("stalls", text, { readonly = true })
		shown = greed.float(buffer, { title = "Profile", width = "90%", height = "70%" })
	end,
})

greed.command({
	name = "stalls-close",
	doc = "Close the list of stalls",
	run = close,
})

greed.keymap.bind(
	{ mode = "normal", kind = "stalls" },
	{ esc = "stalls-close", q = "stalls-close" }
)

return {}
