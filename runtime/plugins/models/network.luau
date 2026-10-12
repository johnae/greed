-- Requests to models' servers as they go over the network: where tests
-- stand in for the server, and which failures are worth trying again.

local greed = require("@greed")

local M = {}

--- Sends `request` with greed.http.stream. Tests replace it.
function M.stream(request: greed.HttpRequest): (greed.HttpStream?, string?)
	return greed.http.stream(request)
end

--- How long to wait before trying again, in milliseconds, when the server
--- doesn't say.
M.PAUSE = 2000

--- The longest a server's Retry-After is waited for.
M.MOST = 30000

-- Too many requests, and a server in between that couldn't reach the
-- model's or gave up waiting for it.
local AGAIN = { [429] = true, [502] = true, [503] = true, [504] = true }

--- How long to wait before sending a request again that the server answered
--- with `status` and `headers`, or nil when sending it again won't help.
function M.again_in(status: number, headers: { [string]: string }): number?
	if not AGAIN[status] then
		return nil
	end
	local after = tonumber(headers["retry-after"])
	if after and (status == 429 or status == 503) then
		return math.clamp(after * 1000, 0, M.MOST)
	end
	return M.PAUSE
end

return M
