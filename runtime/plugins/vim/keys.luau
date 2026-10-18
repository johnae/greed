-- The Vim style's keys, its modes' cursors, and the style itself.

local greed = require("@greed")
local core = require("@core")
local motions = require("./motions").motions

-- Insert mode has the typing keys every style's typing mode has, and keys
-- other plugins bind for the command role (going to definitions and
-- problems, the next change) work in normal mode here too.
greed.keymap.fallback("vim-insert", "insert-char")
greed.mode.set_cursor("vim-insert", "bar")

-- Core's keys that Vim has too: search, paging, jumps, the view and folds,
-- and the next and previous syntax objects after ] and [.
local shared: { [string]: string } = {
	["/"] = "search",
	["?"] = "search-back",
	n = "search-next",
	N = "search-prev",
	["ctrl-f"] = "page-down",
	["ctrl-b"] = "page-up",
	["ctrl-d"] = "half-page-down",
	["ctrl-u"] = "half-page-up",
	pagedown = "page-down",
	pageup = "page-up",
	["ctrl-o"] = "jump-back",
	["ctrl-i"] = "jump-forward",
	tab = "fold-toggle",
	["z z"] = "center-view",
	["z t"] = "align-view-top",
	["z b"] = "align-view-bottom",
	["z a"] = "fold-toggle",
	["z o"] = "fold-open",
	["z R"] = "fold-open-all",
	["] space"] = "add-newline-below",
	["[ space"] = "add-newline-above",
}
for key, command in core.syntax.keys do
	if string.match(key, "^[%[%]] ") then
		shared[key] = command
	end
end

local keys: { [string]: string } = {
	d = "vim-operator-d",
	c = "vim-operator-c",
	y = "vim-operator-y",
	x = "vim-delete-char",
	X = "vim-delete-char-before",
	D = "vim-delete-to-end",
	C = "vim-change-to-end",
	s = "vim-substitute",
	S = "vim-change-line",
	p = "vim-paste-after",
	P = "vim-paste-before",
	i = "vim-insert",
	a = "vim-append",
	I = "vim-insert-line-start",
	A = "vim-append-line-end",
	o = "vim-open-below",
	O = "vim-open-above",
	v = "vim-visual",
	V = "vim-visual-line",
	["ctrl-v"] = "vim-visual-block",
	r = "vim-replace-char",
	["~"] = "vim-switch-case",
	J = "vim-join",
	[">"] = "vim-operator->",
	["<"] = "vim-operator-<",
	["g c"] = "vim-operator-gc",
	["g ~"] = "vim-operator-g~",
	["g u"] = "vim-operator-gu",
	["g U"] = "vim-operator-gU",
	["g ?"] = "vim-operator-g?",
	["g q"] = "vim-operator-gq",
	["g w"] = "vim-operator-gw",
	["="] = "vim-operator-=",
	["!"] = "vim-operator-!",
	["*"] = "vim-search-word",
	["#"] = "vim-search-word-back",
	q = "vim-macro",
	m = "vim-mark",
	["@"] = "vim-play-macro",
	['"'] = "select-register",
	u = "vim-undo",
	["ctrl-r"] = "vim-redo",
	["."] = "repeat-change",
	enter = "press-button",
	["z c"] = "fold-close",
	["ctrl-e"] = "scroll-down",
	["ctrl-y"] = "scroll-up",
	["ctrl-a"] = "vim-increment",
	["ctrl-x"] = "vim-decrement",
	["g J"] = "vim-join-raw",
	["g i"] = "vim-insert-last",
	["g v"] = "vim-reselect",
	["g n"] = "vim-select-match",
	["Z Z"] = "save-quit",
	["Z Q"] = "vim-quit-unsaved",
	R = "vim-replace-mode",
	U = "vim-undo-line",
	["ctrl-n"] = "vim-multi-next",
	K = "hover",
	["g r n"] = "rename",
	["g r a"] = "quick-fix",
	["g r r"] = "goto-references",
	["g r i"] = "goto-implementation",
	["g r t"] = "goto-type-definition",
	["g O"] = "pick-outline",
	["g s"] = "vim-jump-to-word",
	["alt-o"] = "vim-expand-selection",
	["alt-i"] = "vim-shrink-selection",
	["alt-shift-right"] = "swap-node-next",
	["alt-shift-left"] = "swap-node-prev",
	[":"] = "vim-command-line",
	["g ;"] = "vim-change-older",
	["g -"] = "earlier",
	["g +"] = "later",
	["g ,"] = "vim-change-newer",
	["z f"] = "vim-operator-zf",
	["z M"] = "fold-close-all",
	["z j"] = "fold-next",
	["z k"] = "fold-prev",
	["z d"] = "fold-open",
	["z E"] = "fold-open-all",
}
for key, command in shared do
	keys[key] = command
end
local visual_keys: { [string]: string } = {
	d = "vim-operator-d",
	x = "vim-operator-d",
	c = "vim-operator-c",
	y = "vim-operator-y",
	esc = "vim-normal",
	v = "vim-normal",
	V = "vim-normal",
	[">"] = "vim-operator->",
	["<"] = "vim-operator-<",
	["g c"] = "vim-operator-gc",
	["g ~"] = "vim-operator-g~",
	["~"] = "vim-operator-g~",
	u = "vim-operator-gu",
	U = "vim-operator-gU",
	["g ?"] = "vim-operator-g?",
	["g q"] = "vim-operator-gq",
	["="] = "vim-operator-=",
	["!"] = "vim-operator-!",
	["z f"] = "vim-operator-zf",
	[":"] = "vim-command-line",
	S = "vim-visual-surround",
	["alt-o"] = "vim-expand-selection",
	["alt-i"] = "vim-shrink-selection",
	["alt-shift-right"] = "swap-node-next",
	["alt-shift-left"] = "swap-node-prev",
	i = "vim-visual-inside",
	a = "vim-visual-around",
	o = "vim-visual-swap",
	r = "vim-visual-replace",
	J = "vim-visual-join",
	p = "vim-visual-paste",
	P = "vim-visual-paste",
	["ctrl-v"] = "vim-visual-block",
}
for key in motions do
	keys[key] = "vim-motion-" .. string.gsub(key, " ", "")
	visual_keys[key] = keys[key]
end
greed.keymap.bind("vim", keys)
greed.keymap.bind("vim-visual", visual_keys)
greed.keymap.bind("vim-insert", {
	esc = "vim-normal",
	["ctrl-o"] = "vim-insert-one",
	["ctrl-t"] = "indent",
	["ctrl-d"] = "dedent",
	["ctrl-n"] = "completion-words",
	["ctrl-p"] = "completion-words-back",
})
greed.keymap.bind("vim-multi", {
	["ctrl-n"] = "vim-multi-next",
	["ctrl-x"] = "vim-multi-skip",
	["ctrl-p"] = "vim-multi-back",
	c = "vim-multi-change",
	s = "vim-multi-change",
	d = "vim-multi-delete",
	x = "vim-multi-delete",
	y = "vim-multi-copy",
	i = "vim-multi-insert",
	I = "vim-multi-insert",
	a = "vim-multi-append",
	A = "vim-multi-append",
	esc = "vim-normal",
})
greed.keymap.inherit("vim-replace", "vim-insert")
greed.keymap.bind("vim-replace", { backspace = "vim-replace-back" })
greed.keymap.fallback("vim-replace", "vim-replace-typed")
greed.mode.set_cursor("vim-replace", "underline")
greed.keymap.counts("vim")
greed.keymap.counts("vim-visual")
greed.keymap.inherit("vim-visual-line", "vim-visual")
greed.keymap.counts("vim-visual-line")
greed.keymap.inherit("vim-visual-block", "vim-visual")
greed.keymap.bind("vim-visual-block", {
	I = "vim-block-insert",
	A = "vim-block-append",
	["ctrl-v"] = "vim-normal",
})
greed.keymap.counts("vim-visual-block")

core.style.define({
	name = "vim",
	doc = "Say what to do, then where: d w, c i w (Vim)",
	mode = "vim",
	roles = { command = "vim", typing = "vim-insert", selecting = "vim-visual" },
	leader = "space",
	labels = {
		vim = "normal",
		["vim-insert"] = "insert",
		["vim-visual"] = "visual",
		["vim-visual-line"] = "visual line",
		["vim-visual-block"] = "visual block",
		["vim-replace"] = "replace",
		["vim-multi"] = "multi",
	},
})
return {}
