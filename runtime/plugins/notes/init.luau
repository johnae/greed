-- Notes: a folder of plain Markdown files, linked with [[note]], with todos
-- and an agenda. It's only files, so git or Syncthing can carry them to
-- other machines and a phone.
--
--   space n d   today's note            space n f   find a note
--   space n c   capture a todo          space n /   search the notes
--   space n a   the agenda: open todos, soonest due first
--   space n x   tick a todo, or untick it
--   g d         follow the [[link]] under the cursor (making the note)
--   z a         fold the section under the cursor, or unfold it (core's folds)
--
-- In notes (Markdown files in the notes folder, or every Markdown file with
-- `notes-everywhere`), links show without their brackets, markup shows as
-- symbols (look.luau), and each note lists the notes linking to it at its
-- end.
--
--     local greed = require("@greed")
--     greed.option.set("notes-folder", "~/Documents/notes")

local core = require("@core")
local greed = require("@greed")
local notes = require("@self/notes")
require("@self/links")
require("@self/todos")
require("@self/folds")
require("@self/tools")
require("@self/look")

greed.keymap.bind("normal", {
	["space n d"] = "notes-daily",
	["space n c"] = "notes-capture",
	["space n a"] = "notes-agenda",
	["space n f"] = "notes-find",
	["space n /"] = "notes-search",
	["space n x"] = "todo-toggle",
	["g d"] = "notes-follow",
})

core.features.add("notes", notes.is_note, "notes")

return notes
