-- Flashes text as it's copied, so you can see what went to the clipboard.
--
-- With a "#rrggbb" background for "ui.flash" in the theme it fades out;
-- with the 16 terminal colors it shows briefly and goes. Either way it's a
-- decoration and a theme entry changing over time, which is all an
-- animation is.
--
-- To change how long it lasts, set "flash-duration" from your config:
--
--     require("@kern").option.set("flash-duration", 150)

local kern = require("@kern")

kern.option.define({
	name = "flash-duration",
	doc = "How long copied text flashes, in milliseconds",
	default = 300,
})

-- Each flash gets a number, so an older one finishing doesn't clear a newer.
local latest = 0

-- The red, green and blue of a "#rrggbb" color.
local function rgb(hex: string): { number }?
	local r, g, b = string.match(hex, "^#(%x%x)(%x%x)(%x%x)$")
	if r == nil then
		return nil
	end
	return { tonumber(r, 16) :: number, tonumber(g, 16) :: number, tonumber(b, 16) :: number }
end

-- The color `t` of the way from `from` to `to`.
local function mix(from: { number }, to: { number }, t: number): string
	local out = {}
	for i = 1, 3 do
		out[i] = math.floor(from[i] + (to[i] - from[i]) * t + 0.5)
	end
	return string.format("#%02x%02x%02x", out[1], out[2], out[3])
end

kern.on("command.run", function(event: kern.CommandRun)
	if event.name ~= "copy" then
		return
	end
	local view = kern.view()
	local marks: { kern.Mark } = {}
	for _, range in view:selection().ranges do
		local from, to = math.min(range.anchor, range.head), math.max(range.anchor, range.head)
		if from < to then
			table.insert(marks, { from = from, to = to, style = "ui.flash.now", above = true })
		end
	end
	if #marks == 0 then
		return
	end
	latest += 1
	local mine = latest
	local duration = kern.option.get("flash-duration") :: number
	local buffer = view:buffer()
	local flash = kern.theme.get("ui.flash") or { bg = "yellow", fg = "black" }
	local text = kern.theme.get("ui.text")
	kern.theme.set({ ["ui.flash.now"] = { bg = flash.bg, fg = flash.fg } })
	buffer:decorate("flash", marks)
	local from_bg = flash.bg and rgb(flash.bg)
	local to_bg = rgb(text and text.bg or "#000000")
	if from_bg and to_bg then
		kern.animate(duration, function(t)
			if latest == mine then
				kern.theme.set({ ["ui.flash.now"] = { bg = mix(from_bg, to_bg, t), fg = flash.fg } })
			end
		end)
	else
		kern.sleep(duration)
	end
	if latest == mine then
		buffer:decorate("flash", {})
	end
end)

return {}
