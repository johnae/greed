-- Server-sent events, the way model APIs stream: blocks of "field: value"
-- lines, ended by a blank line.

export type Event = { event: string?, data: string }

local M = {}

--- Splits what arrived so far into whole events, and returns them with what's
--- left over for the next piece.
function M.parse(buffered: string): ({ Event }, string)
	local text = string.gsub(buffered, "\r\n", "\n")
	local events: { Event } = {}
	while true do
		local stop = string.find(text, "\n\n", 1, true)
		if stop == nil then
			break
		end
		local block = string.sub(text, 1, stop - 1)
		text = string.sub(text, stop + 2)
		local name: string? = nil
		local data = {}
		for line in string.gmatch(block, "[^\n]+") do
			local field, value = string.match(line, "^(%w+):%s?(.*)$")
			if field == "event" then
				name = value
			elseif field == "data" then
				table.insert(data, value)
			end
		end
		if #data > 0 then
			table.insert(events, { event = name, data = table.concat(data, "\n") })
		end
	end
	return events, text
end

return M
