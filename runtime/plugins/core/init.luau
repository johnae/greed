-- Greed's default editing model: Helix-style modal editing, written against
-- the same API any plugin uses. Read this to see how commands and keymaps
-- fit together; copy any part of it into your own config to change it.

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
require("@self/reload")
require("@self/stalls")
require("@self/secrets")
local scroll = require("@self/scroll")
local goto_keys = require("@self/goto")
local objects = require("@self/objects")
local syntax = require("@self/syntax")
require("@self/select_mode")
require("@self/selections")
local comment = require("@self/comment")
local jumps = require("@self/jumps")
local registers = require("@self/registers")
local menu = require("@self/menu")
local prompt = require("@self/prompt")
local project = require("@self/project")
local style = require("@self/style")
local mouse = require("@self/mouse")
local buttons = require("@self/buttons")
local indent = require("@self/indent")
local folds = require("@self/folds")
local config = require("@self/config")
local effects = require("@self/effects")
local again = require("@self/again")
local words = require("@self/words")
local floats = require("@self/floats")

greed.keymap.bind("normal", {
	enter = "press-button",
	h = "move-left",
	j = "move-down",
	k = "move-up",
	l = "move-right",
	left = "move-left",
	down = "move-down",
	up = "move-up",
	right = "move-right",
	w = "next-word",
	b = "prev-word",
	e = "word-end",
	home = "line-start",
	["end"] = "line-end",
	["g h"] = "line-start",
	["g l"] = "line-end",
	["g g"] = "goto-start",
	["g e"] = "goto-last-line",
	["g w"] = "jump-to-word",
	G = "goto-line",
	["g s"] = "first-non-blank",
	W = "next-big-word",
	B = "prev-big-word",
	E = "big-word-end",
	f = "find-next-char",
	t = "till-next-char",
	F = "find-prev-char",
	T = "till-prev-char",
	["m m"] = "match-bracket",
	v = "select-mode",
	["ctrl-c"] = "toggle-comment",
	['"'] = "select-register",
	Q = "record-macro",
	q = "play-macro",
	["ctrl-o"] = "jump-back",
	["ctrl-i"] = "jump-forward",
	tab = "jump-forward",
	["alt-d"] = "delete-without-copy",
	["alt-c"] = "change-without-copy",
	r = "replace-char",
	R = "replace-with-copy",
	["~"] = "switch-case",
	["`"] = "lowercase",
	["alt-`"] = "uppercase",
	[">"] = "indent",
	["<"] = "dedent",
	J = "join-lines",
	I = "insert-line-start",
	A = "append-line-end",
	["ctrl-f"] = "page-down",
	["ctrl-b"] = "page-up",
	["ctrl-d"] = "half-page-down",
	["ctrl-u"] = "half-page-up",
	pagedown = "page-down",
	pageup = "page-up",
	x = "select-line",
	[";"] = "collapse",
	["."] = "repeat-change",
	["alt-;"] = "flip",
	i = "insert-mode",
	a = "append-mode",
	o = "open-below",
	O = "open-above",
	d = "delete",
	c = "change",
	u = "undo",
	U = "redo",
	y = "copy",
	p = "paste-after",
	P = "paste-before",
	["/"] = "search",
	["?"] = "search-back",
	n = "search-next",
	N = "search-prev",
	["*"] = "search-selection",
	["alt-*"] = "search-selection-anywhere",
	["%"] = "select-all",
	s = "select-regex",
	S = "split-regex",
	["alt-s"] = "split-lines",
	K = "keep-matching",
	["alt-K"] = "remove-matching",
	C = "copy-selection-down",
	["alt-C"] = "copy-selection-up",
	[","] = "keep-primary",
	["alt-,"] = "remove-primary",
	["("] = "rotate-primary-back",
	[")"] = "rotate-primary",
	X = "extend-to-line-bounds",
	["alt-x"] = "shrink-to-line-bounds",
	["alt-_"] = "merge-consecutive-selections",
	["_"] = "trim-selections",
	["&"] = "align-selections",
	["alt-("] = "rotate-contents-back",
	["alt-)"] = "rotate-contents",
	["alt-."] = "repeat-find",
	["ctrl-a"] = "increment",
	["ctrl-x"] = "decrement",
	["alt-u"] = "earlier",
	["alt-U"] = "later",
	["ctrl-h"] = "selection-undo",
	["ctrl-k"] = "selection-redo",
	["space c"] = "toggle-comment",
	-- Copies already go to the clipboard; these are Helix's keys for it.
	["space y"] = "copy",
	["space Y"] = "copy",
	["space p"] = "paste-after",
	["space R"] = "replace-with-copy",
	["] space"] = "add-newline-below",
	["[ space"] = "add-newline-above",
})

greed.keymap.bind("insert", {
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

-- An empty layer applies in every mode.
greed.keymap.bind({}, {
	["ctrl-s"] = "save",
	["ctrl-q"] = "quit",
})

greed.keymap.bind("normal", objects.keys)
greed.keymap.bind("normal", syntax.keys)
greed.keymap.bind("normal", folds.keys)
greed.keymap.bind("normal", scroll.keys)
greed.keymap.bind("normal", goto_keys.keys)
greed.keymap.counts("normal")
greed.keymap.fallback("insert", "insert-char")
greed.mode.cursor("insert", "bar")

--- A thing to act on, from a finder or a picker item (see actions.luau).
export type Target = actions.Target

-- Other plugins can use these with `require("@core")`.
return {
	text = text,
	motions = motions,
	menu = menu,
	prompt = prompt,
	file = file,
	search = search,
	project = project,
	style = style,
	mouse = mouse,
	buttons = buttons,
	indent = indent,
	folds = folds,
	config = config,
	effects = effects,
	again = again,
	comment = comment,
	jumps = jumps,
	jump = jump,
	hints = hints,
	actions = actions,
	objects = objects,
	syntax = syntax,
	words = words,
	floats = floats,
	registers = registers,
}
