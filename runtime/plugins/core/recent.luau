-- The files you've been in, most recent first: what `g a` (and ctrl-^)
-- goes back to, and what a closed file's views show instead.

local greed = require("@greed")

local M = {}

-- File buffer ids, most recent last.
local recent: { number } = {}

local function forget(id: number)
	local at = table.find(recent, id)
	if at then
		table.remove(recent, at)
	end
end

--- Notes that you're in `buffer`, if it's a file's.
function M.seen(buffer: greed.Buffer)
	if buffer:kind() ~= "file" then
		return
	end
	local id = buffer:id()
	if recent[#recent] ~= id then
		forget(id)
		table.insert(recent, id)
	end
end

--- The open file buffers you've been in, most recent first.
function M.buffers(): { greed.Buffer }
	local open: { [number]: greed.Buffer } = {}
	for _, buffer in greed.buffers() do
		open[buffer:id()] = buffer
	end
	local out = {}
	for i = #recent, 1, -1 do
		local buffer = open[recent[i]]
		if buffer then
			table.insert(out, buffer)
		end
	end
	return out
end

-- Whatever showed a file (a picker, `greed.open`, a plugin), the next
-- command finds you in it.
greed.on("command.run", function()
	M.seen(greed.view():buffer())
end)
greed.on("selection.changed", function(event: greed.SelectionChanged)
	if event.view == greed.view() then
		M.seen(event.view:buffer())
	end
end)
greed.on("view.focused", function(event: greed.ViewFocused)
	M.seen(event.view:buffer())
end)
greed.on("buffer.closed", function(event: greed.BufferClosed)
	forget(event.id)
end)

return M
