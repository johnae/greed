-- Flashes text as it's copied, so you can see what went to the clipboard.
--
-- With a "#rrggbb" background for "ui.flash" in the theme it fades out;
-- with the 16 terminal colors it shows briefly and goes. Either way it's a
-- decoration and a theme entry changing over time, which is all an
-- animation is.
--
-- To change how long it lasts, set "flash-duration" from your config:
--
--     require("@greed").option.set("flash-duration", 150)

local greed = require("@greed")
local core = require("@core")

greed.option.define({
	name = "flash-duration",
	doc = "How long copied text flashes, in milliseconds",
	default = 300,
})

-- Each flash gets a number, so an older one finishing doesn't clear a newer.
local latest = 0

local rgb, mix = core.effects.rgb, core.effects.mix

greed.on("command.run", function(event: greed.CommandRun)
	if event.name ~= "copy" then
		return
	end
	local view = greed.view()
	local marks: { greed.Mark } = {}
	for _, range in view:selection().ranges do
		local from, to = core.text.span(range)
		if from < to then
			table.insert(marks, { from = from, to = to, style = "ui.flash.now", above = true })
		end
	end
	if #marks == 0 then
		return
	end
	latest += 1
	local mine = latest
	local duration = greed.option.get("flash-duration") :: number
	local buffer = view:buffer()
	local flash = greed.theme.get("ui.flash") or { bg = "yellow", fg = "black" }
	local text = greed.theme.get("ui.text")
	greed.theme.set({ ["ui.flash.now"] = { bg = flash.bg, fg = flash.fg } })
	buffer:decorate("flash", marks)
	local from_bg = flash.bg and rgb(flash.bg)
	local to_bg = rgb(text and text.bg or "#000000")
	if from_bg and to_bg then
		greed.animate(duration, function(t)
			if latest == mine then
				greed.theme.set({
					["ui.flash.now"] = { bg = mix(from_bg, to_bg, t), fg = flash.fg },
				})
			end
		end)
	else
		greed.sleep(duration)
	end
	-- The buffer may have gone away while it flashed.
	if latest == mine and buffer:valid() then
		buffer:decorate("flash", {})
	end
end)

return {}
