-- Small animations that say where you are and what just happened, like a
-- wave of light through the status line's file name when you switch files.
-- They take their colors from the theme and only work with "#rrggbb" ones.
-- They are off unless you turn them on:
--
--     require("@greed").option.set("effects", true)

local greed = require("@greed")

greed.option.define({
	name = "effects",
	doc = "Small animations, like a wave of light through the status line when you switch files",
	default = false,
})

local M = {}

--- Whether effects are on.
function M.enabled(): boolean
	return greed.option.get("effects") == true
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

--- How far apart two colors are, from 0 (the same) to about 441 (black and
--- white).
function M.distance(a: { number }, b: { number }): number
	return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2)
end

-- How many characters either side of a wave's middle light up.
local REACH = 3

-- Smooth at both ends rather than a sharp peak.
local function smooth(level: number): number
	return level * level * (3 - 2 * level)
end

--- How lit each of `count` characters is, from 0 to 1, as a wave `t` of
--- the way through them: brightest in its middle and fading either side.
function M.wave(count: number, t: number): { number }
	-- The middle starts before the first character and ends after the last,
	-- so the wave comes in and goes out.
	local middle = -REACH + t * (count - 1 + 2 * REACH)
	local lit = {}
	for i = 1, count do
		lit[i] = smooth(math.max(0, 1 - math.abs((i - 1) - middle) / REACH))
	end
	return lit
end

--- How lit each of `count` characters is, from 0 to 1, as a glow `t` of the
--- way through: it starts in their middle and spreads out both ways at
--- once, two crests fading out past the ends.
function M.burst(count: number, t: number): { number }
	local middle = (count - 1) / 2
	-- From the middle to past the ends.
	local reached = t * (middle + REACH)
	local lit = {}
	for i = 1, count do
		local from_middle = math.abs((i - 1) - middle)
		lit[i] = smooth(math.max(0, 1 - math.abs(from_middle - reached) / REACH)) * (1 - t)
	end
	return lit
end

return M
