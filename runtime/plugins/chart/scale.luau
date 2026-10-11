-- Scales: from the data's least and greatest to round ticks, and numbers
-- written short enough for an axis, in their unit when they have one:
-- bytes as `128Mi`, kubectl's CPU as `250m`, percents as `45%`.

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

-- Sizes in bytes, a power of 1024 apart.
local BINARY = { "", "Ki", "Mi", "Gi", "Ti", "Pi" }

-- The power of 1024 `n` bytes are written in.
local function binary(n: number): number
	return math.clamp(math.floor(math.log(math.max(math.abs(n), 1), 1024)), 0, #BINARY - 1)
end

--- What a column's numbers are, by how its cells are written: "bytes"
--- (`128Mi`, `4KB`), "cores" (kubectl's CPU, `250m`) or "percent"
--- (`45%`); nil for plain numbers. The first cell with a unit decides.
function M.unit(cells: { string }): string?
	for _, cell in cells do
		local suffix = string.match(cell, "^%s*[-+]?[%d.]+(%a*%%?)")
		if suffix and suffix ~= "" then
			if string.match(suffix, "^[KMGTPE]iB?$") or string.match(suffix, "^[KMGTPE]?B$") then
				return "bytes"
			elseif suffix == "m" then
				return "cores"
			elseif suffix == "%" then
				return "percent"
			end
		end
	end
	return nil
end

--- Round ticks as `ticks` gives them, for numbers in `unit`: bytes a
--- round number of KiB, MiB or GiB apart.
function M.ticks_in(lo: number, hi: number, count: number, unit: string?): Ticks
	if unit ~= "bytes" then
		return M.ticks(lo, hi, count)
	end
	local size = 1024 ^ binary(math.max(math.abs(lo), math.abs(hi)))
	local ticks = M.ticks(lo / size, hi / size, count)
	local values: { number } = {}
	for i, v in ticks.values do
		values[i] = v * size
	end
	return { lo = ticks.lo * size, hi = ticks.hi * size, step = ticks.step * size, values = values }
end

--- `n` written short for an axis or a label: `1.2k`, `3.4M`, `0.25`, with
--- as many decimals as ticks `step` apart need (the number itself's own
--- size without a step), in `unit` when it has one.
function M.format(n: number, step: number?, unit: string?): string
	local size = math.abs(n)
	local by = step or (if size == 0 then 1 else size / 100)
	if unit == "bytes" then
		if n == 0 then
			return "0"
		end
		local power = binary(n)
		local scale = 1024 ^ power
		return decimals(n / scale, math.max(by / scale, 0.01)) .. BINARY[power + 1]
	elseif unit == "cores" and size < 1 and n ~= 0 then
		return decimals(n * 1000, math.max(by * 1000, 1)) .. "m"
	elseif unit == "percent" then
		return decimals(n, math.min(by, 1)) .. "%"
	end
	for _, big in UNITS do
		if size >= big.size then
			return decimals(n / big.size, math.max(by / big.size, 0.01)) .. big.suffix
		end
	end
	return decimals(n, math.min(by, 1))
end

return M
