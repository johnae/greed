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

-- Who waits for each buffer's next reports, by buffer id, and how many
-- more reports each waits for: one from each of the buffer's servers.
type Waiter = { signal: greed.Signal, left: number }
local waiting: { [number]: { Waiter } } = {}

greed.on("lsp.diagnostics", function(event: greed.DiagnosticsChanged)
	local id = event.buffer:id()
	local list = waiting[id]
	if list == nil then
		return
	end
	for i = #list, 1, -1 do
		local waiter = list[i]
		waiter.left -= 1
		if waiter.left <= 0 then
			table.remove(list, i)
			waiter.signal:send(true)
		end
	end
	if #list == 0 then
		waiting[id] = nil
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
	local waiters: { Waiter } = {}
	local seen: { [number]: boolean } = {}
	for _, buffer in buffers do
		local id = buffer:id()
		local servers = if buffer:path() then #greed.lsp.servers_of(buffer) else 0
		if not seen[id] and servers > 0 then
			seen[id] = true
			local waiter = { signal = greed.signal(), left = servers }
			waiting[id] = waiting[id] or {}
			table.insert(waiting[id], waiter)
			table.insert(checked, buffer)
			table.insert(waiters, waiter)
		end
	end
	if #checked == 0 then
		return nil
	end
	greed.spawn(function()
		greed.sleep(ms or WAIT)
		for i, waiter in waiters do
			waiter.signal:send(false)
			-- A server that never reports mustn't collect waiters.
			local id = checked[i]:id()
			local list = waiting[id]
			local at = list and table.find(list, waiter)
			if list and at then
				table.remove(list, at)
			end
		end
	end)
	local reports = {}
	for i, buffer in checked do
		waiters[i].signal:wait()
		table.insert(reports, report(buffer))
	end
	return table.concat(reports, "\n")
end

return M
