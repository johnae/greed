-- Greed's editing engine: the commands, motions, text objects, registers,
-- floats, prompts and the editing styles registry, written against the same
-- API any plugin uses. The editing styles themselves, like Helix and Vim, are
-- plugins that give these commands keys.

local greed = require("@greed")

local text = require("@self/text")
local motions = require("@self/motions")
require("@self/edit")
local file = require("@self/file")
local search = require("@self/search")
require("@self/select")
local jump = require("@self/jump")
local hints = require("@self/hints")
local actions = require("@self/actions")
require("@self/undo")
local transient = require("@self/transient")
require("@self/reload")
require("@self/autosave")
require("@self/numbers")
require("@self/stalls")
require("@self/secrets")
local scroll = require("@self/scroll")
local goto_keys = require("@self/goto")
local textobjects = require("@self/textobjects")
local syntax = require("@self/syntax")
require("@self/selections")
local comment = require("@self/comment")
local jumps = require("@self/jumps")
local registers = require("@self/registers")
require("@self/macro_commands")
require("@self/window")
local menu = require("@self/menu")
local features = require("@self/features")
local menus = require("@self/menus")
local reveal = require("@self/reveal")
local prompt = require("@self/prompt")
local project = require("@self/project")
local style = require("@self/style")
require("@self/clients")
local mouse = require("@self/mouse")
local buttons = require("@self/buttons")
local images = require("@self/images")
local indent = require("@self/indent")
local folds = require("@self/folds")
local config = require("@self/config")
local effects = require("@self/effects")
require("@self/again")
local commands = require("@self/commands")
local words = require("@self/words")
local paste = require("@self/paste")
local floats = require("@self/floats")
local modeless = require("@self/modeless")
local lookup = require("@self/lookup")

-- An empty layer applies in every mode.
greed.keymap.bind({}, {
	["ctrl-s"] = "save",
	["ctrl-q"] = "quit",
})

-- Typing, the same in every style's typing mode; a style binds its own
-- keys over these. esc goes back to the style's own mode.
greed.keymap.bind({ role = "typing" }, {
	esc = "normal-mode",
	pagedown = "page-down",
	pageup = "page-up",
	enter = "insert-newline",
	backspace = "delete-back",
	delete = "delete-forward",
	tab = "insert-tab",
	home = "line-start",
	["end"] = "line-end",
	["ctrl-w"] = "delete-word-back",
	["alt-backspace"] = "delete-word-back",
	["alt-d"] = "delete-word-forward",
	["ctrl-u"] = "delete-to-line-start",
	["ctrl-k"] = "delete-to-line-end",
	["ctrl-r"] = "insert-register",
	left = "move-left",
	right = "move-right",
	up = "move-up",
	down = "move-down",
})

--- A thing to act on, from a finder or a picker item (see actions.luau).
export type Target = actions.Target
export type TransientItem = transient.Item
export type TransientMenu = transient.Menu
--- A float being typed in, from `floats.typing`.
export type TypingFloat = floats.Typing

-- Other plugins can use these with `require("@core")`.
return {
	text = text,
	motions = motions,
	menu = menu,
	features = features,
	menus = menus,
	reveal = reveal,
	prompt = prompt,
	file = file,
	search = search,
	project = project,
	style = style,
	mouse = mouse,
	buttons = buttons,
	--- Pasting an image into what takes one, like an agent's box (images.luau).
	images = images,
	indent = indent,
	folds = folds,
	--- The view keys after z (scroll.luau).
	scroll = scroll,
	--- The goto keys that aren't motions (goto.luau).
	goto_keys = goto_keys,
	config = config,
	effects = effects,
	--- Tags on commands, like "typing" (commands.luau).
	commands = commands,
	comment = comment,
	jumps = jumps,
	jump = jump,
	hints = hints,
	actions = actions,
	transient = transient,
	textobjects = textobjects,
	syntax = syntax,
	words = words,
	--- Editing without modes, for styles like vscode (modeless.luau).
	modeless = modeless,
	--- Pasted text going in at the cursors (paste.luau).
	paste = paste,
	floats = floats,
	registers = registers,
	--- Where the thing under the cursor is defined, and what it is (lookup.luau).
	lookup = lookup,
	--- Helpers for registries other plugins add to (registry.luau).
	registry = require("@self/registry"),
	--- The files you've been in, most recent first (recent.luau).
	recent = require("@self/recent"),
}
