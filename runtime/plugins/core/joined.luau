local greed = require("@greed")

--- `f`, made so that a call while another with the same `key` is still
--- running waits for that one and gives what it gave, rather than doing
--- the work again: a program asked for by several at once starts once.
local function joined<T>(f: (key: string) -> (T?, string?)): (key: string) -> (T?, string?)
	-- Who waits on the run of each key going on, one signal each.
	local running: { [string]: { greed.Signal } } = {}
	return function(key: string): (T?, string?)
		local others = running[key]
		if others then
			local signal = greed.signal()
			table.insert(others, signal)
			local got = signal:wait()
			return got.value, got.why
		end
		local waiting: { greed.Signal } = {}
		running[key] = waiting
		local ok, value, why = pcall(f, key)
		running[key] = nil
		local got = if ok then { value = value, why = why } else { why = tostring(value) }
		for _, signal in waiting do
			signal:send(got)
		end
		if not ok then
			error(value, 0)
		end
		return value, why
	end
end

return joined
