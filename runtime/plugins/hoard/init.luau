-- Hoard: your notes, todos and today, for anyone, not only programmers.
-- `greed notes` starts it (or comes back to it) in a session of its own,
-- named hoard, which opens your notes folder on its home: search, adding a
-- todo or a thought to today's note, today's note, the agenda with boxes
-- to tick, the inbox and recent notes (home.luau). Editing there is
-- modeless, with VS Code's keys (`hoard-editing-style` changes that), notes
-- save on their own and have no line numbers, and language servers leave
-- them alone.
--
-- `:hoard` (`space n h`) goes to Hoard from any session, starting it if
-- needed, and `:hoard-window` (`space n H`) opens it in a window of its own.

local greed = require("@greed")
local core = require("@core")
local notes = require("@notes")
local home = require("@self/home")
local review = require("@self/review")
require("@self/complete")

local M = {}

M.home = home
M.review = review

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

--- Goes to Hoard's session, starting it if needed: in this window, or
--- (`window`) in a window of its own, a terminal going to it as without.
--- In Hoard, shows its home.
function M.go(window: boolean?)
	if M.here() then
		home.show()
	else
		greed.session.switch({ name = M.SESSION, window = window })
	end
end

greed.command({
	name = "hoard",
	doc = "Go to Hoard (your notes, todos and today), starting it if needed; in Hoard, its home",
	run = function()
		M.go()
	end,
})

greed.command({
	name = "hoard-window",
	doc = "Open Hoard in a window of its own, staying here; in a terminal, go to it",
	run = function()
		M.go(true)
	end,
})

greed.keymap.bind({ layer = "leader" }, { ["n h"] = "hoard", ["n H"] = "hoard-window" })

-- Whether a completion menu was just closed with esc, which it passes on:
-- that esc doesn't go home too.
local menu_closed = false

greed.on("command.run", function(event: greed.CommandRun)
	if event.name == "completion-close" then
		menu_closed = true
	end
end)

greed.command({
	name = "hoard-escape",
	doc = "In Hoard: let go of the selection, or zoom out of a list item or section, or else go "
		.. "back to the home",
	run = function(ctx)
		local ranges = ctx.view:selection().ranges
		local selected = #ranges > 1 or ranges[1].anchor ~= ranges[1].head
		local closing = menu_closed
		menu_closed = false
		if M.here() and not selected and not closing and core.outline.zoomed(ctx.view) then
			greed.run("zoom-out")
		elseif not M.here() or selected or closing or core.snippet.active(ctx.view) then
			greed.run("collapse")
		else
			home.show()
		end
	end,
})

-- esc in a note, as in the vscode style it lets go of the selection, and
-- then goes home. The completion menu keeps its own (complete.luau).
greed.keymap.bind({ style = "vscode", role = "typing", kind = "file" }, { esc = "hoard-escape" })

-- Away from the home, the status line starts with the way back to it.
require("@statusline").add("left", "hoard", function(ctx)
	if not M.here() or home.is(ctx.buffer) then
		return nil
	end
	local key = if greed.option.get("editing-style") == "vscode" then "  esc" else ""
	return { text = `‹ Hoard{key}`, style = "ui.statusline.mode", action = "hoard" }
end, "mode")

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
