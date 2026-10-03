-- Kern's default editing model: Helix-style modal editing, written against
-- the same API any plugin uses. Read this to see how commands and keymaps
-- fit together; copy any part of it into your own config to change it.

local kern = require("@kern")

local text = require("@self/text")
local motions = require("@self/motions")
require("@self/edit")
local file = require("@self/file")
local search = require("@self/search")
require("@self/select")
require("@self/jump")
require("@self/reload")
require("@self/stalls")
require("@self/secrets")
require("@self/scroll")
local objects = require("@self/objects")
local syntax = require("@self/syntax")
require("@self/select_mode")
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

kern.keymap.bind("normal", {
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
	["z z"] = "center-view",
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
})

kern.keymap.bind("insert", {
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
kern.keymap.bind({}, {
	["ctrl-s"] = "save",
	["ctrl-q"] = "quit",
})

kern.keymap.bind("normal", objects.keys)
kern.keymap.bind("normal", syntax.keys)
kern.keymap.bind("normal", folds.keys)
kern.keymap.counts("normal")
kern.keymap.fallback("insert", "insert-char")
kern.mode.cursor("insert", "bar")

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
	objects = objects,
	syntax = syntax,
	words = words,
	floats = floats,
	registers = registers,
}
