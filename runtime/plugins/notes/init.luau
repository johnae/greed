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
--   space n k   link to a heading, list item or block in a note
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
local links = require("@self/links")
local mentions = require("@self/mentions")
local todos = require("@self/todos")
require("@self/tools")
require("@self/objects")
require("@self/look")
local reminders = require("@self/reminders")
require("@self/connect")
local index = require("@self/index")
local syntax = require("@self/syntax")
local dates = require("@self/dates")

greed.keymap.bind({ layer = "leader" }, {
	["n r"] = "notes-reminders-dismiss",
	["n l"] = "notes-connect",
	["n d"] = "notes-daily",
	["n c"] = "notes-capture",
	["n t"] = "notes-thought",
	["n a"] = "notes-agenda",
	["n f"] = "notes-find",
	["n /"] = "notes-search",
	["n x"] = "todo-toggle",
	["n k"] = "notes-link",
})

core.features.add("notes", notes.is_note)

--- A note as the index knows it, and a heading or list item in it (see
--- index.luau).
export type Note = index.Note
export type Node = index.Node
--- A todo as the index knows it.
export type Task = index.Task
--- A heading or block to link to (see links.luau).
export type Place = links.Place

-- What other plugins use: the notes, and with them the index, links, todos,
-- dates, reminders and how notes read a line. Setting a field, like a
-- test's `clock`, sets it on the notes themselves.
local exported: typeof(notes) & {
	index: typeof(index),
	todos: typeof(todos),
	reminders: typeof(reminders),
	syntax: typeof(syntax),
	dates: typeof(dates),
	links: typeof(links),
	mentions: typeof(mentions),
} = setmetatable(
	{
		index = index,
		todos = todos,
		reminders = reminders,
		syntax = syntax,
		dates = dates,
		links = links,
		mentions = mentions,
	},
	{
		__index = notes,
		__newindex = notes,
	}
) :: any
return exported
