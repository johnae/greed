-- The working set: the files you've been working in lately, scored by
-- what you did in each and how recently. Editing counts most, an agent's
-- edits less, and having a file in front of you a little; the score halves
-- every HALF_LIFE, so it follows what you do now. Agents get it as a tool,
-- and the repo map ranks toward it.

local greed = require("@greed")
local core = require("@core")
local registry = require("./registry")

local M = {}

-- After this long, what you did in a file counts half as much.
local HALF_LIFE = 15 * 60 * 1000

-- How often the file in front of you is noticed.
local LOOK_EVERY = 10 * 1000

-- What each kind of activity is worth.
local WEIGHT: { [string]: number } = { edit = 1, agent = 0.5, look = 0.2 }

-- The plugins agents edit through: proposals you accept, and agents
-- running inside Greed.
local AGENTS = { agent = true, acp = true }

-- Edits closer together than this count once, so typing a word isn't many.
local EDIT_GAP = 2000

-- The lines last worked on in each file, at most this many.
local LINES = 5

export type Entry = {
	path: string,
	score: number,
	edits: number,
	agent_edits: number,
	--- When it was last worked on, on the editor's clock (greed.now).
	at: number,
	--- The lines (0-based) worked on last, newest first.
	lines: { number },
}

local files: { [string]: Entry } = {}

-- `entry`'s score as of `now`.
local function decayed(entry: Entry, now: number): number
	return entry.score * 0.5 ^ ((now - entry.at) / HALF_LIFE)
end

--- `path` relative to the project, as the working set and the repo map key
--- files.
function M.relative(path: string): string
	return core.project.relative(path, core.project.root())
end

-- Notes `kind` of activity in `buffer` at `line`.
local function note(buffer: greed.Buffer, kind: "edit" | "agent" | "look", line: number?)
	local path = buffer:path()
	if path == nil then
		return
	end
	path = M.relative(path)
	local now = greed.now()
	local entry = files[path]
	if entry == nil then
		entry = { path = path, score = 0, edits = 0, agent_edits = 0, at = now, lines = {} }
		files[path] = entry
	end
	if kind == "edit" then
		if now - entry.at < EDIT_GAP and entry.edits > 0 then
			return
		end
		entry.edits += 1
	elseif kind == "agent" then
		entry.agent_edits += 1
	end
	entry.score = decayed(entry, now) + WEIGHT[kind]
	entry.at = now
	if line and entry.lines[1] ~= line then
		table.insert(entry.lines, 1, line)
		entry.lines[LINES + 1] = nil
	end
end

greed.on("buffer.changed", function(event: greed.BufferChanged)
	local buffer = event.buffer
	-- A buffer can be closed by the time an event about it is handled.
	local ok, history = pcall(function()
		return buffer:history({ limit = 1 })
	end)
	local last = if ok then history[1] else nil
	if not last or last.cause == "undo" or last.cause == "redo" then
		return
	end
	local line = if last.changes[1]
		then buffer:line_of(math.min(last.changes[1].from, buffer:len()))
		else nil
	if last.author == "user" then
		note(buffer, "edit", line)
	elseif last.author == "agent" or AGENTS[last.plugin or ""] then
		note(buffer, "agent", line)
	end
end)

-- Where you were at the last look, so a file left open while you're away
-- doesn't keep counting.
local last_look = ""

--- Notes the file in front of you, if you moved since the last look, as
--- happens every LOOK_EVERY.
function M.look()
	local view = greed.view()
	local selection = view:selection()
	local buffer = view:buffer()
	local at = `{buffer:id()}:{selection.ranges[selection.primary].head}`
	if at ~= last_look then
		last_look = at
		note(buffer, "look")
	end
end

greed.spawn(function()
	while true do
		greed.sleep(LOOK_EVERY)
		M.look()
	end
end)

--- The working set, highest score first, with the scores as of now.
function M.list(): { Entry }
	local now = greed.now()
	local list = {}
	for _, entry in files do
		local copy = table.clone(entry)
		copy.score = decayed(entry, now)
		table.insert(list, copy)
	end
	table.sort(list, function(a: Entry, b: Entry)
		return a.score > b.score
	end)
	return list
end

--- Each file's score as of now, by path.
function M.scores(): { [string]: number }
	local scores = {}
	for _, entry in M.list() do
		scores[entry.path] = entry.score
	end
	return scores
end

-- How long ago `at` was, in words.
local function ago(at: number): string
	local seconds = math.floor((greed.now() - at) / 1000)
	if seconds < 60 then
		return `{seconds}s ago`
	elseif seconds < 3600 then
		return `{seconds // 60}m ago`
	end
	return `{seconds // 3600}h ago`
end

registry.tool({
	name = "working_set",
	group = "map",
	description = "The files the user has been working in lately, most active first: how "
		.. "much they edited each (and how much agents did), when, and the 1-based lines they "
		.. "worked on last. Start here to see what the user is doing",
	input = {
		type = "object",
		properties = { limit = { type = "number", description = "20 by default" } },
	},
	run = function(args)
		local limit = args.limit or 20
		local list = {}
		for _, entry in M.list() do
			if #list >= limit then
				break
			end
			local lines = {}
			for _, line in entry.lines do
				table.insert(lines, line + 1)
			end
			table.insert(list, {
				path = entry.path,
				score = math.floor(entry.score * 100 + 0.5) / 100,
				edits = entry.edits,
				agent_edits = entry.agent_edits,
				last = ago(entry.at),
				lines = greed.json.array(lines),
			})
		end
		return greed.json.array(list)
	end,
})

greed.command({
	name = "working-set",
	doc = "Show the files you've been working in lately, the way agents see them",
	run = function()
		local lines = {}
		for _, entry in M.list() do
			table.insert(
				lines,
				string.format(
					"%6.2f  %-50s %d edits, %s",
					entry.score,
					entry.path,
					entry.edits,
					ago(entry.at)
				)
			)
		end
		local text = if #lines == 0 then "Nothing worked on yet." else table.concat(lines, "\n")
		greed.float(
			greed.create_buffer("working-set", text),
			{ title = "Working set", width = "80%" }
		)
	end,
})

return M
