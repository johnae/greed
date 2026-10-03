-- Pickers: type to narrow a list down, then choose an item.
--
-- A picker is one floating buffer. Its first line is what you type; the
-- lines below are the items that match, best first, with the current one
-- highlighted. Move with up/down (or ctrl-n/ctrl-p), choose with enter,
-- close with esc.
--
-- Other plugins open one with `require("@self/picker").pick(...)`; see
-- pickers.luau for examples.

local greed = require("@greed")
local core = require("@core")
local picker = require("@self/picker")

export type Item = picker.Item
export type Preview = picker.Preview
export type Options = picker.Options

require("@self/pickers")

-- Several buttons under the cursor: pick which one enter presses.
core.buttons.choose = function(buttons, press)
	local items = {}
	for _, button in buttons do
		table.insert(items, { label = button.text, value = button })
	end
	picker.pick("Buttons", items, function(item)
		press(item.value)
	end)
end

greed.keymap.bind({ mode = "insert", kind = "picker" }, picker.KEYS)
-- A picker takes typing; if something leaves it in another mode, esc still
-- closes it.
core.style.kind_modes.picker = "insert"
for _, mode in { "normal", "vim", "edit" } do
	greed.keymap.bind({ mode = mode, kind = "picker" }, { esc = "picker-close" })
end

greed.keymap.bind("normal", {
	["space f"] = "pick-file",
	["space b"] = "pick-buffer",
	["space s"] = "pick-outline",
	["space j"] = "pick-jump",
	["space F"] = "pick-file-here",
	["space '"] = "picker-resume",
	["space ?"] = "command-palette",
})

return picker
