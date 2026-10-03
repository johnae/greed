-- A counter
local kern = require("@kern")

local function count(items: { string }): number
	local n = 0
	for _, item in items do
		if item ~= "" then
			n += 1
		end
	end
	return n
end

kern.echo(count({ "a", "b" }), true, nil)
