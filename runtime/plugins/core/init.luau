-- Kern's default editing model: Helix-style modal editing, written against
-- the same API any plugin uses. Read this to see how commands and keymaps
-- fit together; copy any part of it into your own config to change it.

local kern = require("@kern")

local text = require("@self/text")
local motions = require("@self/motions")
require("@self/edit")
require("@self/file")
require("@self/search")
local menu = require("@self/menu")
local prompt = require("@self/prompt")

kern.keymap.bind("normal", {
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
	["g e"] = "goto-end",
	x = "select-line",
	[";"] = "collapse",
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
})

kern.keymap.bind("insert", {
	esc = "normal-mode",
	enter = "insert-newline",
	backspace = "delete-back",
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

kern.keymap.fallback("insert", "insert-char")
kern.mode.cursor("insert", "bar")

-- Other plugins can use these with `require("@core")`.
return {
	text = text,
	motions = motions,
	menu = menu,
	prompt = prompt,
}
