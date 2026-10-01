-- The status line: the mode, the file (or the latest message), problems
-- the language server found, and where the cursor is. To change it, call
-- `kern.statusline` with your own function from your config; the last one
-- set wins.

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

	-- Counts of errors and warnings from the language server, if any.
	local counts = { 0, 0 }
	for _, d in kern.lsp.diagnostics(s.buffer) do
		if d.severity <= 2 then
			counts[d.severity] += 1
		end
	end
	local problems = ""
	if counts[1] > 0 then
		problems ..= `E{counts[1]} `
	end
	if counts[2] > 0 then
		problems ..= `W{counts[2]} `
	end

	local selection = s.view:selection()
	local head = selection.ranges[selection.primary].head
	local line = s.buffer:line_of(head)
	local column = (utf8.len(s.buffer:slice(s.buffer:line_start(line), head)) or 0) + 1

	return {
		left = { { text = " " .. string.upper(s.mode) .. " ", style = "mode" }, " ", middle },
		right = { problems, `{line + 1}:{column} ` },
	}
end)
