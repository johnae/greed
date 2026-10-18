-- Hoard: your notes, todos and today, for anyone, not only programmers.
-- `greed notes` starts it (or comes back to it) in a session of its own,
-- named hoard, which opens your notes folder on its home: search, adding a
-- todo or a thought to today's note, today's note, the agenda with boxes
-- to tick, the inbox and recent notes (home.luau). Editing there is
-- modeless, with VS Code's keys, and notes save on their own, unless
-- your config says otherwise.
--
-- `:hoard` shows the home in any session; `space n h` too.

local greed = require("@greed")
local core = require("@core")
local notes = require("@notes")
local home = require("@self/home")
require("@self/slash")

local M = {}

M.home = home

--- The session `greed notes` starts.
M.SESSION = "hoard"

--- Whether this is Hoard's own session.
function M.here(): boolean
	return greed.session.current() == M.SESSION
end

-- What Hoard's session does unless your config says otherwise: it types as
-- soon as a key is pressed, as people who don't use an editor's modes
-- expect, and notes save on their own.
local DEFAULTS: { [string]: greed.OptionValue } = {
	["editing-style"] = "vscode",
	["auto-save"] = true,
}

local function defaults()
	for _, option in greed.option.list() do
		local value = DEFAULTS[option.name]
		if value ~= nil and option.set_by == nil then
			greed.option.set(option.name, value)
		end
	end
end

--- Opens the notes folder as the project shown, making it if there isn't
--- one, and shows the home there. Other projects this session started
--- with that hold nothing go, so Hoard is only your notes.
function M.open()
	local folder = notes.folder()
	if greed.fs.stat(folder) == nil then
		greed.fs.mkdir(folder)
	end
	local id: number? = nil
	for _, project in greed.project.list() do
		if project.root == folder then
			id = project.id
		end
	end
	if id then
		greed.project.switch(id)
	else
		id = greed.project.open(folder)
	end
	for _, project in greed.project.list() do
		if project.id ~= id and #core.project.unsaved_buffers() == 0 then
			local empty = true
			for _, buffer in greed.buffers() do
				local path = buffer:path()
				if path and core.project.inside(path, project.root) then
					empty = false
					break
				end
			end
			if empty then
				greed.project.close(project.id)
			end
		end
	end
	home.show()
end

greed.command({
	name = "hoard",
	doc = "Show Hoard's home: search your notes, add a todo, today's note and the agenda",
	run = function()
		home.show()
	end,
})

greed.keymap.bind({ layer = "leader" }, { ["n h"] = "hoard" })

greed.cli({
	name = "capture",
	doc = "Add a todo to today's note from any shell, saying when in plain words, like: greed capture call the bank tomorrow 18:00; with --note, a line that isn't a todo",
	usage = "[--note] TEXT",
	run = function(args: { string }): string?
		local plain = args[1] == "--note"
		local text = table.concat(args, " ", if plain then 2 else 1)
		if not string.match(text, "%S") then
			error("say what to add, like: greed capture call the bank tomorrow 18:00", 0)
		end
		notes.make_daily()
		local today = notes.daily()
		if plain then
			notes.append(today, `- {text}`)
			return "added to today's note"
		end
		return `{notes.todos.capture(text, today)}: added to today's note`
	end,
})

greed.on("editor.started", function()
	if M.here() then
		defaults()
		M.open()
	end
end)

return M
