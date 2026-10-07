-- Pages that ask you something for an agent, like a plugin's install
-- review or code it wants to run, show one at a time: an agent can ask for
-- two at once, and a page hidden behind another would wait, or time out,
-- unseen. The next shows when the one before is answered.

local greed = require("@greed")

local M = {}

-- Whether a page is up, and who waits to show one, first first.
local showing = false
local waiting: { greed.Signal } = {}

--- Runs `ask`, which shows a page and waits for your answer, once no other
--- page is up, and returns what it returns. Waits like greed.sleep.
function M.one_at_a_time<T>(ask: () -> T): T
	if showing then
		local turn = greed.signal()
		table.insert(waiting, turn)
		turn:wait()
	end
	showing = true
	local ok, result = pcall(ask)
	local next_one = table.remove(waiting, 1)
	if next_one then
		next_one:send(true)
	else
		showing = false
	end
	if not ok then
		error(result, 0)
	end
	return result
end

return M
