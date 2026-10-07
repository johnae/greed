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
core.buttons.set_chooser(function(buttons, press)
	local items = {}
	for _, button in buttons do
		table.insert(items, { label = button.text, value = button })
	end
	picker.pick("Buttons", items, function(item)
		press(item.value)
	end)
end)

greed.command({
	name = "act",
	doc = "List what you can do with what's under the cursor (a file, link, symbol, problem, change or the selection), and do it",
	run = function(ctx)
		picker.act(core.actions.at(ctx.view))
	end,
})

-- Commands, as the command palette lists them.
core.actions.action({
	kind = "command",
	name = "run",
	doc = "Run it",
	run = function(target)
		greed.run(target.value)
	end,
})

-- A picker takes typing, in the style's typing mode, and its keys work in
-- every mode, so esc closes it whatever left it in another.
greed.keymap.bind({ kind = "picker" }, picker.KEYS)
core.style.typing_kind("picker")

greed.keymap.bind({ layer = "leader" }, {
	f = "pick-file",
	b = "pick-buffer",
	s = "pick-outline",
	j = "pick-jump",
	F = "pick-file-here",
	["'"] = "picker-resume",
	["?"] = "command-palette",
	["."] = "act",
})
-- In edit mode space types, and ctrl-. is the language server's code actions.
greed.keymap.bind("edit", { ["alt-."] = "act" })

return picker
