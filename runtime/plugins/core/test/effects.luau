local test = require("@greed/test")
local core = require("@core")
local effects = core.effects

test("a wave is brightest in its middle and fades either side", function()
	local lit = effects.wave(9, 0.5)
	assert(lit[5] == 1, "the middle character is fully lit: " .. lit[5])
	assert(lit[4] < 1 and lit[4] > lit[3] and lit[3] > lit[2], "fading to the left")
	assert(lit[6] == lit[4] and lit[7] == lit[3], "and the same to the right")
	assert(lit[1] == 0 and lit[9] == 0, "the ends are dark")
	local start, finish = effects.wave(9, 0), effects.wave(9, 1)
	for i = 1, 9 do
		assert(start[i] == 0 and finish[i] == 0, "it comes in and goes out")
	end
end)

test("colors mix, and lightness tells light from dark", function()
	assert(effects.mix({ 0, 0, 0 }, { 255, 255, 255 }, 0.5) == "#808080")
	assert((effects.rgb("#ff8000") :: { number })[2] == 128)
	assert(effects.rgb("red") == nil, "only #rrggbb")
	assert(
		math.abs(effects.lightness({ 255, 255, 255 }) - 1) < 1e-9
			and effects.lightness({ 0, 0, 0 }) == 0
	)
end)

test("a burst starts in the middle and spreads out both ways", function()
	local start = effects.burst(9, 0)
	assert(start[5] == 1 and start[4] < 1, "lit in the middle first")
	local later = effects.burst(9, 0.4)
	assert(later[5] < later[3] and later[3] == later[7], "the crests have moved out, together")
	local finish = effects.burst(9, 1)
	for i = 1, 9 do
		assert(finish[i] == 0, "gone at the end")
	end
end)
