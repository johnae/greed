-- Agents as participants: while an agent works, the line it works on shows
-- in your files, with a sign and its name and what it's doing at the end
-- of the line; and the status line says how many agents work and wait.
-- An agent in a workspace of its own shows on your copy of the file.
local greed = require("@greed")
local session = require("./session")

type Session = session.Session

local M = {}

-- A style for each agent, by its number, so several can be told apart.
local STYLES = { "diff.plus", "keyword", "constant", "string" }

local function absolute(path: string): string
	return if string.sub(path, 1, 1) == "/" then path else `{greed.fs.cwd()}/{path}`
end

-- Where `s` works, in your project: a file in its workspace is the same
-- file in yours.
local function place(s: Session): (string?, number?)
	local where = s.where
	if where == nil then
		return nil, nil
	end
	local path = where.path
	local ws = s.workspace
	if ws and string.sub(path, 1, #ws.path + 1) == ws.path .. "/" then
		path = s.root .. string.sub(path, #ws.path + 1)
	end
	return path, where.line
end

local function active(s: Session): boolean
	return s.status == "working" or s.status == "waiting"
end

--- Marks where each of `sessions` works in the open files, and takes the
--- marks away from agents that stopped.
function M.draw(sessions: { Session })
	local open: { [string]: greed.Buffer } = {}
	for _, buffer in greed.buffers() do
		local path = buffer:path()
		if path then
			open[absolute(path)] = buffer
		end
	end
	local by_path: { [string]: { greed.Mark } } = {}
	for _, s in sessions do
		local path, line = place(s)
		if path and active(s) then
			local buffer = open[path]
			if buffer then
				local at =
					buffer:line_start(math.clamp((line or 1) - 1, 0, buffer:line_count() - 1))
				local doing = if s.status == "waiting"
					then "waiting for you"
					else s.tool or "working"
				local marks = by_path[path] or {}
				table.insert(marks, {
					from = at,
					to = at,
					style = STYLES[(s.id - 1) % #STYLES + 1],
					sign = "◆",
					text = `  ◆ {s.name}: {doing}`,
					eol = true,
				})
				by_path[path] = marks
			end
		end
	end
	for _, buffer in greed.buffers() do
		local path = buffer:path()
		local marks = if path then by_path[absolute(path)] else nil
		if marks or #buffer:decorations("agents") > 0 then
			buffer:decorate("agents", marks or {})
		end
	end
end

--- What the status line shows about `sessions`: how many work and how
--- many wait for you; nil when none do.
function M.status(sessions: { Session }): string?
	local working, waiting = 0, 0
	for _, s in sessions do
		if s.status == "working" then
			working += 1
		elseif s.status == "waiting" then
			waiting += 1
		end
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
