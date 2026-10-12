-- Helpers for commands bound to keys.

local greed = require("@greed")

local M = {}

--- Runs what `keys` would run if `command` weren't bound to them: the
--- binding in the first layer under the one that binds `command`. For a
--- command that does its thing only somewhere (a float, a level) and
--- leaves the key to do what it always does elsewhere. Returns whether
--- something ran.
function M.otherwise(keys: string, command: string): boolean
	local ours: string? = nil
	for _, bound in greed.keymap.describe(keys) do
		if bound.command == command then
			ours = ours or bound.layer
		elseif ours and bound.layer ~= ours then
			greed.run(bound.command)
			return true
		end
	end
	return false
end

return M
