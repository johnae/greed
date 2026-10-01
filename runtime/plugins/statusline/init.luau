-- The status line: the mode, the file (or the latest message), and where
-- the cursor is. To change it, call `kern.statusline` with your own
-- function from your config; the last one set wins.

local kern = require("@kern")

kern.statusline(function(s)
	local middle: kern.StatusSegment
	if s.message then
		middle = { text = s.message, style = "message" }
	else
		local name = s.buffer:path() or "[scratch]"
		if s.buffer:modified() then
			name ..= " [+]"
		end
		middle = name
	end

	local selection = s.view:selection()
	local head = selection.ranges[selection.primary].head
	local line = s.buffer:line_of(head)
	local column = (utf8.len(s.buffer:slice(s.buffer:line_start(line), head)) or 0) + 1

	return {
		left = { { text = " " .. string.upper(s.mode) .. " ", style = "mode" }, " ", middle },
		right = { `{line + 1}:{column} ` },
	}
end)
