-- Pickers: type to narrow a list down, then choose an item.
--
-- A picker is one floating buffer. Its first line is what you type; the
-- lines below are the items that match, best first, with the current one
-- highlighted. Move with up/down (or ctrl-n/ctrl-p), choose with enter,
-- close with esc.
--
-- Other plugins open one with `require("@self/picker").pick(...)`; see
-- pickers.luau for examples.

local kern = require("@kern")
local picker = require("@self/picker")

export type Item = picker.Item
export type Preview = picker.Preview
export type Options = picker.Options

require("@self/pickers")

kern.keymap.bind({ mode = "insert", kind = "picker" }, {
	down = "picker-next",
	up = "picker-prev",
	["ctrl-n"] = "picker-next",
	["ctrl-p"] = "picker-prev",
	enter = "picker-choose",
	esc = "picker-close",
})

kern.keymap.bind("normal", {
	["space f"] = "pick-file",
	["space b"] = "pick-buffer",
	["space ?"] = "command-palette",
})

return picker
