-- Hoard: your notes, todos and today, for anyone, not only programmers.
-- `greed notes` starts it (or comes back to it) in a session of its own,
-- named hoard, which opens your notes folder on its home: search, adding a
-- todo or a thought to today's note, today's note, the agenda with boxes
-- to tick, the inbox and recent notes (home.luau). Editing there is
-- modeless, with VS Code's keys (`hoard-editing-style` changes that), notes
-- save on their own and have no line numbers, and language servers leave
-- them alone.
--
-- `:hoard` shows the home in any session; `space n h` too.

local greed = require("@greed")
local core = require("@core")
local notes = require("@notes")
local home = require("@self/home")
require("@self/complete")

local M = {}

M.home = home

--- The session `greed notes` starts.
M.SESSION = "hoard"

--- Whether this is Hoard's own session.
function M.here(): boolean
	return greed.session.current() == M.SESSION
end

greed.option.define({
	name = "hoard-editing-style",
	doc = 'The editing style in Hoard: "vscode" types as soon as a key is pressed, without modes; '
		.. '"same" keeps the one the rest of Greed uses',
	default = "vscode",
})

greed.option.define({
	name = "hoard-language-servers",
	doc = "Run Markdown's language servers (spelling, grammar) on notes in Hoard",
	default = false,
})

--- What Hoard's session does as it starts: it types as soon as a key is
--- pressed, as people who don't use an editor's modes expect, notes save on
--- their own unless your config says otherwise, and notes aren't checked by
--- language servers, whose remarks about spelling in one language are
--- noise in notes written in another.
function M.defaults()
	local style = greed.option.get("hoard-editing-style")
	if style ~= "same" then
		greed.option.set("editing-style", style)
	end
	for _, option in greed.option.list() do
		if option.name == "auto-save" and option.set_by == nil then
			greed.option.set("auto-save", true)
		end
	end
	if
		greed.option.get("hoard-language-servers") ~= true
		and table.find(greed.plugin.list(), "languages")
	then
		require("@languages").set("markdown", { servers = {} })
	end
end

-- Notes in Hoard are pages to read and write, without line numbers.
greed.on("buffer.opened", function(event: greed.BufferChanged)
	if M.here() and notes.is_note(event.buffer) then
		event.buffer:set_line_numbers(false)
	end
end)

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
		M.defaults()
		M.open()
	end
end)

return M
