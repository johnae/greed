-- The status line: the mode, the file (or the latest message), problems
-- the language server found, and where the cursor is. To change it, call
-- `kern.statusline` with your own function from your config; the last one
-- set wins.

local kern = require("@kern")
local core = require("@core")
local style = core.style

kern.statusline(function(s)
	local middle: kern.StatusSegment
	if s.message then
		middle = { text = s.message, style = "ui.statusline.message" }
	else
		local name = s.buffer:path() or "[scratch]"
		-- Files in the project show from its root.
		local root = kern.project.current().root .. "/"
		if string.sub(name, 1, #root) == root then
			name = string.sub(name, #root + 1)
		end
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

	local mode =
		{ text = " " .. string.upper(style.label(s.mode)) .. " ", style = "ui.statusline.mode" }
	local left: { any } = { mode, " ", middle }
	local macro = core.registers.recording()
	if macro then
		table.insert(left, 2, { text = ` recording @{macro} `, style = "ui.statusline.message" })
	end
	return {
		left = left,
		right = { problems, `{line + 1}:{column} ` },
	}
end)
