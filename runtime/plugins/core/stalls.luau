-- :stalls lists the times plugin code held the editor up, newest first,
-- with the plugin and what it was running, to trace a freeze to its cause;
-- :errors lists the errors from plugin code that nothing caught.

local greed = require("@greed")
local floats = require("./floats")

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
		floats.show_text("Stalls, newest first", table.concat(lines(), "\n"), { kind = "stalls" })
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
		local text = table.concat(profile_lines(greed.profile.stop(), seconds), "\n")
		floats.show_text("Profile", text, { kind = "stalls", width = "90%", height = "70%" })
	end,
})

-- :errors lists errors from plugin code that nothing caught, newest first,
-- each with where in its Luau it failed.
greed.command({
	name = "errors",
	doc = "List errors from plugin code that nothing caught, with the plugin, what it ran and where it failed",
	run = function()
		local out = {}
		for _, failure in greed.errors() do
			local at = os.date("%H:%M:%S", math.floor(failure.time))
			table.insert(out, `{at}  {failure.plugin or "Greed"} ({failure.what})`)
			table.insert(out, `  {failure.message}`)
			for _, line in string.split(failure.traceback, "\n") do
				if string.match(line, "%S") then
					table.insert(out, `    {line}`)
				end
			end
			table.insert(out, "")
		end
		if #out == 0 then
			out = { "No errors from plugin code." }
		end
		floats.show_text("Errors, newest first", table.concat(out, "\n"), { kind = "errors" })
	end,
})

-- :debug turns debug topics on and off; :debug-log shows their lines in a
-- pane below, following new ones while it's open.
greed.command({
	name = "debug",
	doc = "Turn debug topics on (:debug keys frames), off (:debug -keys, :debug off), or say which are on",
	args = {
		{
			name = "topics",
			doc = "keys, runs, frames, rpc, jobs, client, plugins, plugin:NAME or all; -NAME turns one off",
		},
	},
	run = function(ctx)
		greed.debug.switch(table.concat(ctx.args, " "))
		local on = greed.debug.enabled()
		if #on == 0 then
			greed.echo(`debug: nothing on; topics are {table.concat(greed.debug.topics(), ", ")}`)
		else
			greed.echo(`debug: {table.concat(on, ", ")} on; :debug-log shows what they say`)
		end
	end,
})

-- One debug line as the log shows it: when, in seconds since the editor
-- started, then its topic or plugin.
local function log_line(line: greed.DebugLine): string
	return string.format("%10.3f  %-8s %s", line.at / 1000, line.plugin or line.topic, line.text)
end

-- How often an open log looks for new lines, in milliseconds.
local FOLLOW_EVERY = 200

greed.command({
	name = "debug-log",
	doc = "Show what the debug topics on have said, in a pane below, following new lines",
	run = function(ctx)
		local lines = greed.debug.lines()
		local text = {}
		for _, line in lines do
			table.insert(text, log_line(line))
		end
		if #text == 0 then
			table.insert(text, "Nothing said yet. :debug keys (or another topic) turns one on.")
		end
		local buffer =
			greed.create_buffer("debug-log", table.concat(text, "\n") .. "\n", { readonly = true })
		local view = ctx.view:split("down", buffer)
		view:set_cursor(buffer:len())
		local last = if #lines > 0 then lines[#lines].id else 0
		greed.spawn(function()
			while view:valid() do
				greed.sleep(FOLLOW_EVERY)
				local new = greed.debug.lines({ after = last })
				if #new > 0 and view:valid() then
					last = new[#new].id
					local more = {}
					for _, line in new do
						table.insert(more, log_line(line) .. "\n")
					end
					local following = view:cursor() >= buffer:len() - 1
					buffer:set_readonly(false)
					buffer:edit(function(e)
						e:insert(buffer:len(), table.concat(more))
					end)
					buffer:set_readonly(true)
					if following then
						view:set_cursor(buffer:len())
					end
				end
			end
		end)
	end,
})

return {}
