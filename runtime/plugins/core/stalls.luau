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
		table.insert(out, `{at}  {math.floor(stall.ms)} ms  {stall.plugin or "Greed"}  {stall.what}`)
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

greed.command({
	name = "stalls-close",
	doc = "Close the list of stalls",
	run = close,
})

greed.keymap.bind({ mode = "normal", kind = "stalls" }, { esc = "stalls-close", q = "stalls-close" })

return {}
