-- What the language server says about files right after an agent changed
-- them, so the agent hears about errors it made without a turn spent
-- running the compiler.

local greed = require("@greed")
local core = require("@core")

local M = {}

-- How long to wait for the servers' reports after an edit, in milliseconds.
local WAIT = 2000

-- The most problems an agent hears about per file.
local MOST = 20

local SEVERITY = { "error", "warning" }

-- Who waits for each buffer's next report, by buffer id.
local waiting: { [number]: { greed.Signal } } = {}

greed.on("lsp.diagnostics", function(event: greed.DiagnosticsChanged)
	local id = event.buffer:id()
	local signals: { greed.Signal } = waiting[id] or {}
	waiting[id] = nil
	for _, signal in signals do
		signal:send(true)
	end
end)

-- The errors and warnings reported in `buffer` now, as lines for an agent.
local function report(buffer: greed.Buffer): string
	local path = buffer:path() :: string
	local shown = core.project.relative(path, core.project.root(path))
	local lines: { string } = {}
	for _, d in greed.lsp.diagnostics(buffer) do
		local severity = SEVERITY[d.severity]
		if severity then
			table.insert(lines, `{shown}:{buffer:line_of(d.from) + 1}: {severity}: {d.message}`)
		end
	end
	if #lines == 0 then
		return `the language server reports no errors or warnings in {shown}`
	end
	local more = #lines - MOST
	if more > 0 then
		lines = table.move(lines, 1, MOST, 1, {})
		table.insert(lines, `and {more} more`)
	end
	return `the language server reports in {shown}:\n{table.concat(lines, "\n")}`
end

--- The errors and warnings the language servers report in `buffers` once
--- they've looked at the latest edits, as text for an agent: waits for each
--- server's next report (at most `ms` in all, default 2 seconds), then
--- reads what they report then. Nil when no language server handles any
--- of them.
function M.after_edits(buffers: { greed.Buffer }, ms: number?): string?
	local checked: { greed.Buffer } = {}
	local signals: { greed.Signal } = {}
	local seen: { [number]: boolean } = {}
	for _, buffer in buffers do
		local id = buffer:id()
		if not seen[id] and buffer:path() and greed.lsp.capabilities(buffer) ~= nil then
			seen[id] = true
			local signal = greed.signal()
			waiting[id] = waiting[id] or {}
			table.insert(waiting[id], signal)
			table.insert(checked, buffer)
			table.insert(signals, signal)
		end
	end
	if #checked == 0 then
		return nil
	end
	greed.spawn(function()
		greed.sleep(ms or WAIT)
		for i, signal in signals do
			signal:send(false)
			-- A server that never reports mustn't collect waiters.
			local id = checked[i]:id()
			local list = waiting[id]
			local at = list and table.find(list, signal)
			if list and at then
				table.remove(list, at)
			end
		end
	end)
	local reports = {}
	for i, buffer in checked do
		signals[i]:wait()
		table.insert(reports, report(buffer))
	end
	return table.concat(reports, "\n")
end

return M
