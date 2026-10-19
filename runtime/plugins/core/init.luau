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
require("@self/undo_files")
local transient = require("@self/transient")
require("@self/reload")
require("@self/autosave")
require("@self/numbers")
require("@self/stalls")
require("@self/secrets")
require("@self/ssh_agent")
local scroll = require("@self/scroll")
local goto_keys = require("@self/goto")
local textobjects = require("@self/textobjects")
local objects = require("@self/objects")
local syntax = require("@self/syntax")
local formula = require("@self/formula")
local data = require("@self/data")
local ui = require("@self/ui")
local recall = require("@self/recall")
require("@self/selections")
local comment = require("@self/comment")
local pairing = require("@self/pairs")
local snippet = require("@self/snippet")
local jumps = require("@self/jumps")
local registers = require("@self/registers")
require("@self/macro_commands")
require("@self/window")
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
local outline = require("@self/outline")
local config = require("@self/config")
local effects = require("@self/effects")
require("@self/again")
local commands = require("@self/commands")
local words = require("@self/words")
local paste = require("@self/paste")
local floats = require("@self/floats")
local query = require("@self/query")
local search_box = require("@self/search_box")
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
	["shift-tab"] = "dedent",
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
--- A thing in the editor with an id, to inspect and act on (see objects.luau).
export type Object = objects.Object
export type ObjectKind = objects.Kind
export type TransientItem = transient.Item
export type TransientMenu = transient.Menu
--- A formula read by `formula.compile`, and where its names come from.
export type Formula = formula.Formula
export type FormulaScope = formula.Scope
--- A table of data, where it comes from and what's asked of it (data.luau).
export type DataTable = data.Table
export type DataColumn = data.Column
export type DataSource = data.Source
export type DataAsk = data.Ask
--- A view of a plugin's interface and what it's made of (ui.luau).
export type UiView = ui.View
export type UiNode = ui.Node
export type UiSpan = ui.Span
export type UiLine = ui.Line
export type UiGridRow = ui.GridRow
--- A walk back through what was typed before (recall.luau).
export type RecallWalk = recall.Walk
--- A float being typed in, from `floats.typing`.
export type TypingFloat = floats.Typing
--- A part of a query, and a whole one parsed (query.luau).
export type QueryNode = query.Node
export type Query = query.Parsed
export type QuerySource = query.Source
export type QueryField = query.Field
export type QueryProblem = query.Problem
--- What a search box is opened with, and a word its `tab` offers
--- (search_box.luau).
export type SearchBoxOptions = search_box.Options
export type SearchBoxWord = search_box.Word
--- Lines that go together, like a list item and those under it (outline.luau).
export type OutlineUnit = outline.Unit
--- Something a completion menu offers, as the lsp plugin's menu and the
--- sources that fill it (the shell's, an agent's box) all take it: `label`
--- in the menu, `text` put in place of what's typed from `from` (the start
--- of the word typed, by default) to the cursor. `detail` says what it is,
--- dimmed after the label, and `badge`, a word before the detail, whose it
--- is, like a shell's "greed" for its own commands. With `snippet`, `text`
--- is a snippet (snippet.luau), whose places tab goes to once it's in.
export type CompletionItem = {
	label: string,
	detail: string?,
	badge: string?,
	text: string,
	from: number?,
	snippet: boolean?,
}

-- Other plugins can use these with `require("@core")`.
return {
	text = text,
	formula = formula,
	--- Tables of data and the sources they come from (data.luau).
	data = data,
	--- A toolkit for plugins' interfaces, drawn as text and marks (ui.luau).
	ui = ui,
	motions = motions,
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
	--- Lines that go together, like a list item and those under it (outline.luau).
	outline = outline,
	--- The view keys after z (scroll.luau).
	scroll = scroll,
	--- The goto keys that aren't motions (goto.luau).
	goto_keys = goto_keys,
	config = config,
	effects = effects,
	--- Tags on commands, like "typing" (commands.luau).
	commands = commands,
	comment = comment,
	--- Brackets and quotes typed in pairs (pairs.luau).
	pairs = pairing,
	--- Snippets: text with places tab goes to (snippet.luau).
	snippet = snippet,
	jumps = jumps,
	jump = jump,
	hints = hints,
	actions = actions,
	transient = transient,
	textobjects = textobjects,
	objects = objects,
	syntax = syntax,
	words = words,
	--- Marks drawn on the lines in sight, as views scroll (visible.luau).
	visible = require("@self/visible"),
	--- Editing without modes, for styles like vscode (modeless.luau).
	modeless = modeless,
	--- Pasted text going in at the cursors (paste.luau).
	paste = paste,
	--- Typing in a buffer with a read-only start goes after it (writable.luau).
	writable = require("@self/writable"),
	floats = floats,
	--- What needs you, and why, for floats' dots and the status (attention.luau).
	attention = require("@self/attention"),
	registers = registers,
	--- Where the thing under the cursor is defined, and what it is (lookup.luau).
	lookup = lookup,
	--- Helpers for registries other plugins add to (registry.luau).
	registry = require("@self/registry"),
	--- Runs a few changes with no frame drawn in between (atomic.luau).
	atomic = require("@self/atomic"),
	--- Times and durations as Greed writes and reads them (time.luau).
	time = require("@self/time"),
	--- Dates: moving them on, repeats, and reading them in plain words
	--- (dates.luau).
	dates = require("@self/dates"),
	--- The query language every search and filter speaks (query.luau).
	query = query,
	--- The box a query is typed in, the same everywhere (search_box.luau).
	search_box = search_box,
	--- The files you've been in, most recent first (recent.luau).
	recent = require("@self/recent"),
	--- Watching objects for changes, with a notification saying how (watch.luau).
	watch = require("@self/watch"),
	--- Which command lines are risky for an agent to run, and why (risk.luau).
	risk = require("@self/risk"),
	--- Going back through what was typed before with up and down, as a
	--- shell's prompt and an agent's box do (recall.luau).
	recall = recall,
	--- Running what a key does under a command bound to it (keys.luau).
	keys = require("@self/keys"),
}
