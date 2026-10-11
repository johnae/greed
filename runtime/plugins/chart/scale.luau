-- Scales: from the data's least and greatest to round ticks, and numbers
-- written short enough for an axis.

local M = {}

--- A range of values rounded out to ticks a step apart, the step 1, 2 or
--- 5 times a power of ten.
export type Ticks = { lo: number, hi: number, step: number, values: { number } }

--- Round ticks from about `lo` to `hi`, about `count` of them. A range of
--- one value gets room around it.
function M.ticks(lo: number, hi: number, count: number): Ticks
	if lo > hi then
		lo, hi = hi, lo
	end
	if lo == hi then
		local room = if lo == 0 then 1 else math.abs(lo) * 0.1
		lo, hi = lo - room, hi + room
	end
	local rough = (hi - lo) / math.max(count, 1)
	local power = 10 ^ math.floor(math.log10(rough))
	local norm = rough / power
	local step = power
		* (if norm < 1.5 then 1 elseif norm < 3 then 2 elseif norm < 7 then 5 else 10)
	local first = math.floor(lo / step + 1e-9) * step
	local last = math.ceil(hi / step - 1e-9) * step
	local values: { number } = {}
	local v = first
	while v <= last + step * 1e-6 do
		-- Away from rounding errors like 0.30000000000000004.
		table.insert(values, math.floor(v / step + 0.5) * step)
		v += step
	end
	return { lo = first, hi = last, step = step, values = values }
end

-- `n` with as many decimals as `step` needs, without trailing zeros.
local function decimals(n: number, step: number): string
	-- As a whole number, so no -0 gets into the format.
	local places = math.clamp(-math.floor(math.log10(step) + 1e-9), 0, 6) // 1
	local text = string.format("%." .. string.format("%d", places) .. "f", n)
	if string.find(text, ".", 1, true) then
		text = string.gsub(string.gsub(text, "0+$", ""), "%.$", "")
	end
	return if text == "-0" then "0" else text
end

-- What big numbers are written with.
local UNITS: { { size: number, suffix: string } } = {
	{ size = 1e12, suffix = "T" },
	{ size = 1e9, suffix = "G" },
	{ size = 1e6, suffix = "M" },
	{ size = 1e3, suffix = "k" },
}

--- `n` written short for an axis or a label: `1.2k`, `3.4M`, `0.25`, with
--- as many decimals as ticks `step` apart need (the number itself's own
--- size without a step).
function M.format(n: number, step: number?): string
	local size = math.abs(n)
	local by = step or (if size == 0 then 1 else size / 100)
	for _, unit in UNITS do
		if size >= unit.size then
			return decimals(n / unit.size, math.max(by / unit.size, 0.01)) .. unit.suffix
		end
	end
	return decimals(n, math.min(by, 1))
end

return M
