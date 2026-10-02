-- Small animations that say where you are and what just happened, like a
-- wave of light through the status line's file name when you switch files.
-- They take their colors from the theme and only work with "#rrggbb" ones.
-- They are off unless you turn them on:
--
--     require("@kern").option.set("effects", true)

local kern = require("@kern")

kern.option.define({
	name = "effects",
	doc = "Small animations, like a wave of light through the status line when you switch files",
	default = false,
})

local M = {}

--- Whether effects are on.
function M.enabled(): boolean
	return kern.option.get("effects") == true
end

--- The red, green and blue of a "#rrggbb" color, or nil for another kind.
function M.rgb(color: string?): { number }?
	local r, g, b = string.match(color or "", "^#(%x%x)(%x%x)(%x%x)$")
	if r == nil then
		return nil
	end
	return { tonumber(r, 16) :: number, tonumber(g, 16) :: number, tonumber(b, 16) :: number }
end

--- The color `t` of the way from `from` to `to`, as "#rrggbb".
function M.mix(from: { number }, to: { number }, t: number): string
	local out = {}
	for i = 1, 3 do
		out[i] = math.floor(from[i] + (to[i] - from[i]) * t + 0.5)
	end
	return string.format("#%02x%02x%02x", out[1], out[2], out[3])
end

--- How light a color looks, from 0 to 1.
function M.lightness(color: { number }): number
	return (0.2126 * color[1] + 0.7152 * color[2] + 0.0722 * color[3]) / 255
end

--- How far from `a` to `b` in lightness, the bigger the more they stand
--- apart.
function M.contrast(a: { number }, b: { number }): number
	return math.abs(M.lightness(a) - M.lightness(b))
end

-- How many characters either side of a wave's middle light up.
local REACH = 3

--- How lit each of `count` characters is, from 0 to 1, as a wave `t` of
--- the way through them: brightest in its middle and fading either side.
function M.wave(count: number, t: number): { number }
	-- The middle starts before the first character and ends after the last,
	-- so the wave comes in and goes out.
	local middle = -REACH + t * (count - 1 + 2 * REACH)
	local lit = {}
	for i = 1, count do
		local away = math.abs((i - 1) - middle) / REACH
		local level = math.max(0, 1 - away)
		-- Smooth at both ends rather than a sharp peak.
		lit[i] = level * level * (3 - 2 * level)
	end
	return lit
end

return M
