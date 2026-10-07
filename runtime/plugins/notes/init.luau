-- Notes: a folder of plain Markdown files, linked with [[note]], with todos
-- and an agenda. It's only files, so git or Syncthing can carry them to
-- other machines and a phone.
--
--   space n d   today's note            space n f   find a note
--   space n c   capture a todo          space n /   search the notes
--   space n a   the agenda: open todos, soonest due first
--   space n x   tick a todo, or untick it
--   space n t   jot a thought down in the inbox
--   space n r   dismiss the reminders notice
--   space n l   have Greed's agent link the inbox to your other notes
--   space k     on a due date or a reminder, say when it is in words
--   g d         follow the [[link]] under the cursor (making the note)
--   tab, z a    fold the section, list item or code block under the cursor,
--               or unfold it (Markdown's folds)
--
-- In notes (Markdown files in the notes folder, or every Markdown file with
-- `notes-everywhere`), links show without their brackets, markup shows as
-- symbols (look.luau), and each note lists the notes linking to it at its
-- end. Todos and lines can carry reminders (reminders.luau).
--
--     local greed = require("@greed")
--     greed.option.set("notes-folder", "~/Documents/notes")

local core = require("@core")
local greed = require("@greed")
local notes = require("@self/notes")
require("@self/links")
require("@self/todos")
require("@self/tools")
require("@self/look")
require("@self/reminders")
require("@self/connect")

greed.keymap.bind("helix", {
	["g d"] = "notes-follow",
})

greed.keymap.bind({ layer = "leader" }, {
	["n r"] = "notes-reminders-dismiss",
	["n l"] = "notes-connect",
	k = "notes-hover",
	["n d"] = "notes-daily",
	["n c"] = "notes-capture",
	["n t"] = "notes-thought",
	["n a"] = "notes-agenda",
	["n f"] = "notes-find",
	["n /"] = "notes-search",
	["n x"] = "todo-toggle",
})

core.features.add("notes", notes.is_note)

return notes
