-- The agents overview: a line per session saying what it's doing, what it
-- waits on and where it works, redrawn as sessions change.

local greed = require("@greed")
local session = require("./session")

type Session = session.Session

local M = {}

-- The overview buffers open, by buffer id, with the session on each line.
local overviews: { [number]: { buffer: greed.Buffer, rows: { [number]: Session } } } = {}

local STATUS: { [string]: string } = {
	starting = "starting",
	idle = "ready",
	working = "working",
	waiting = "waiting for you",
	exited = "exited",
}

local function lines_of(sessions: { Session }): ({ string }, { greed.Mark }, { [number]: Session })
	local lines = {
		"Agents    enter opens · n new · d diff · r review · b bring in · s stop · x close",
		"",
	}
	local marks: { greed.Mark } = {
		{ from = 0, to = 6, style = "markup.heading" },
		{ from = 6, to = #lines[1], style = "comment" },
	}
	local rows: { [number]: Session } = {}
	local at = #lines[1] + 2
	if #sessions == 0 then
		table.insert(lines, "No agents yet: n starts one.")
	end
	for _, s in sessions do
		local status = STATUS[s.status]
		local waiting = #session.pending(s)
		local parts = { `{s.name}  {status}` }
		if s.tool then
			table.insert(parts, `▸ {s.tool}`)
		end
		if waiting > 0 then
			table.insert(parts, `{waiting} question{if waiting == 1 then "" else "s"}`)
		end
		table.insert(
			parts,
			if s.workspace then `workspace {s.workspace.name}` else "in the project"
		)
		local line = table.concat(parts, "   ")
		local style = if s.status == "waiting"
			then "diagnostic.warning"
			elseif s.status == "working" then "diff.plus"
			elseif s.status == "exited" then "comment"
			else nil
		if style then
			table.insert(
				marks,
				{ from = at + #s.name + 2, to = at + #s.name + 2 + #status, style = style }
			)
		end
		table.insert(marks, { from = at, to = at + #s.name, style = "keyword" })
		rows[#lines] = s
		table.insert(lines, line)
		at += #line + 1
	end
	return lines, marks, rows
end

--- Redraws every overview open with `sessions`.
function M.render(sessions: { Session })
	for id, overview in overviews do
		local ok = pcall(function()
			local lines, marks, rows = lines_of(sessions)
			local buffer = overview.buffer
			buffer:set_readonly(false)
			buffer:edit(function(e)
				e:replace(0, buffer:len(), table.concat(lines, "\n"))
			end)
			buffer:set_readonly(true)
			buffer:decorate("agents", marks)
			overview.rows = rows
		end)
		if not ok then
			overviews[id] = nil
		end
	end
end

--- Shows an overview of `sessions` in `view`.
function M.open(view: greed.View, sessions: { Session })
	local buffer = greed.create_buffer("agents", "", { readonly = true })
	buffer:set_line_numbers(false)
	overviews[buffer:id()] = { buffer = buffer, rows = {} }
	M.render(sessions)
	view:show(buffer)
	local pos = buffer:line_start(math.min(2, buffer:line_count() - 1))
	view:set_cursor(pos)
end

--- The session on the overview line under the cursor.
function M.at_cursor(ctx: greed.Context): Session?
	local overview = overviews[ctx.buffer:id()]
	if overview == nil then
		return nil
	end
	return overview.rows[ctx.buffer:line_of(ctx.view:cursor())]
end

greed.on("buffer.closed", function(event: greed.BufferClosed)
	overviews[event.id] = nil
end)

return M
