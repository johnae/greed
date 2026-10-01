-- Diagnostics as marks: a sign beside each line with a problem, and the
-- worst problem's message after the end of the line.

local kern = require("@kern")

local NAMES = { "error", "warning", "info", "hint" }
local SIGNS = { "E", "W", "I", "H" }

local M = {}

-- The marks for `diagnostics` in `buffer`; `messages` says whether to show
-- their text after each line.
function M.diagnostic_marks(buffer: kern.Buffer, diagnostics: { kern.Diagnostic }, messages: boolean): { kern.Mark }
	local worst: { [number]: kern.Diagnostic } = {}
	for _, d in diagnostics do
		local line = buffer:line_of(d.from)
		local current = worst[line]
		if current == nil or d.severity < current.severity then
			worst[line] = d
		end
	end
	local lines = {}
	for line in worst do
		table.insert(lines, line)
	end
	table.sort(lines)
	local marks: { kern.Mark } = {}
	for _, line in lines do
		local d = worst[line]
		local name = NAMES[d.severity] or "hint"
		local at = buffer:line_start(line)
		table.insert(marks, { from = at, to = at, style = "diagnostic.sign." .. name, sign = SIGNS[d.severity] or "H" })
		if messages then
			local message = string.split(d.message, "\n")[1]
			table.insert(marks, { from = at, to = at, style = "diagnostic.message." .. name, text = message, eol = true })
		end
	end
	return marks
end

return M
