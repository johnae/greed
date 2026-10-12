-- Agents as participants: while an agent works, the line it works on shows
-- in your files, with a sign and its name and what it's doing at the end
-- of the line; and the status line says how many agents work and wait.
-- An agent in a workspace of its own shows on your copy of the file.
local greed = require("@greed")
local core = require("@core")
local session = require("./session")
local terminal = require("@terminal")

type Session = session.Session

local M = {}

-- A style for each agent, by its number, so several can be told apart.
local STYLES = { "diff.plus", "keyword", "constant", "string" }

-- Where `s` works, in your project: a file in its workspace is the same
-- file in yours.
local function place(s: Session): (string?, number?)
	local where = s.where
	if where == nil then
		return nil, nil
	end
	local path = core.project.resolve(where.path, s.cwd)
	local ws = s.workspace
	if ws and core.project.inside(path, ws.path) then
		path = core.project.resolve(core.project.relative(path, ws.path), s.root)
	end
	return path, where.line
end

local function active(s: Session): boolean
	return s.status == "working" or s.status == "waiting"
end

--- Marks where each of `sessions` works in the open files, and takes the
--- marks away from agents that stopped.
function M.draw(sessions: { Session })
	local by_buffer: { [number]: { greed.Mark } } = {}
	for _, s in sessions do
		local path, line = place(s)
		local buffer = if path and active(s) then greed.buffer_for(path) else nil
		if buffer then
			local at = buffer:line_start(math.clamp((line or 1) - 1, 0, buffer:line_count() - 1))
			local doing = if s.status == "waiting" then "waiting for you" else s.tool or "working"
			local marks = by_buffer[buffer:id()] or {}
			table.insert(marks, {
				from = at,
				to = at,
				style = STYLES[(s.id - 1) % #STYLES + 1],
				sign = "◆",
				text = `  ◆ {s.name}: {doing}`,
				eol = true,
			})
			by_buffer[buffer:id()] = marks
		end
	end
	for _, buffer in greed.buffers() do
		local marks = by_buffer[buffer:id()]
		if marks or #buffer:decorations("agents") > 0 then
			buffer:decorate("agents", marks or {})
		end
	end
end

--- What the status line shows about `sessions` and the agents running in
--- terminals (`in_terminals`, as their hooks say): how many work and how
--- many wait for you; nil when none do.
function M.status(sessions: { Session }, in_terminals: { terminal.Term }): string?
	local working, waiting = 0, 0
	local function count(state: string)
		if state == "working" then
			working += 1
		elseif state == "waiting" then
			waiting += 1
		end
	end
	for _, s in sessions do
		count(s.status)
	end
	for _, term in in_terminals do
		count((term.agent :: terminal.Agent).state)
	end
	local parts = {}
	if working > 0 then
		table.insert(parts, `{working} working`)
	end
	if waiting > 0 then
		table.insert(parts, `{waiting} waiting for you`)
	end
	return if #parts > 0 then "◆ " .. table.concat(parts, " · ") else nil
end

return M
