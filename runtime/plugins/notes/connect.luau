-- `:notes-connect`: Greed's agent goes through the inbox (or the note
-- you're in), links it to your other notes and adds context, as changes
-- you review.

local greed = require("@greed")
local core = require("@core")
local acp = require("@acp")

local M = {}

-- What Greed's agent is asked to do with your notes. Changes to notes that
-- are there go through proposals (notes_write proposes them too), so each
-- one waits for you; adding a line or a todo asks, as edits do.
local CONNECT = [=[
Go through %s and connect it with the rest of my notes. For each thought, idea or todo:
find related notes (notes_search, notes_list, notes_read), link them with [[name]], and add a
line of context where it helps: what it relates to, why it matters, what could come next.
Where several items belong together, say so, and suggest a note gathering them.

Change notes that already exist only with the propose tool, using the path notes_read gives,
so I can review each change; make new notes with notes_write. Don't delete anything. End with
a short summary of what you connected and what you'd suggest next.]=]

--- Starts Greed's agent on the note at `path`, or on the inbox, with the
--- notes tools on, and shows its transcript. False and why when it can't.
function M.start(path: string?): (boolean, string?)
	local agent = acp.installed("greed")
	if agent == nil then
		return false, "Greed's agent isn't registered"
	end
	local what = if path
		then `the note I have open, {path}`
		else "my inbox note (the project's when it keeps notes)"
	local s, err = acp.start(agent, core.project.root())
	if s == nil then
		return false, `can't start Greed's agent: {err}`
	end
	acp.switch_on(s, "notes")
	acp.show(s)
	acp.prompt(s, string.format(CONNECT, what))
	return true, nil
end

greed.command({
	name = "notes-connect",
	doc = "Have Greed's agent go through the inbox (or the note you're in), link it to your other notes and add context, as changes you review",
	run = function(ctx)
		local path = ctx.buffer:path()
		local ok, err = M.start(if path and string.match(path, "%.md$") then path else nil)
		if not ok then
			greed.echo(err :: string)
		end
	end,
})

return M
