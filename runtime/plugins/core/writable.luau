-- Typing in a buffer whose start is read-only (`buffer:set_readonly_before`),
-- like an agent's transcript above the box you write in, goes where it can:
-- a cursor in the read-only part moves to the end of the buffer first.
-- Typing and pasting commands call `M.cursor` before they edit, and going
-- into a style's typing mode does it too. Edits that only delete or replace
-- up there are refused, as in a read-only buffer.

local greed = require("@greed")
local style = require("./style")

local M = {}

--- Puts the cursor of `view` at the end of its buffer when a cursor or
--- selection of it is in the buffer's read-only start, so what's typed
--- next goes where it can be. Returns whether it moved.
function M.cursor(view: greed.View): boolean
	local buffer = view:buffer()
	local before = buffer:readonly_before()
	if before == nil or buffer:readonly() then
		return false
	end
	for _, range in view:selection().ranges do
		if math.min(range.anchor, range.head) < before then
			view:set_cursor(buffer:len())
			return true
		end
	end
	return false
end

greed.on("mode.changed", function()
	local view = greed.view()
	if view:valid() and style.is_typing() then
		M.cursor(view)
	end
end)

return M
