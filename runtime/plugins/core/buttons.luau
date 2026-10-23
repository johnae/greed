-- Buttons from the keyboard: enter in normal mode runs the action of the
-- mark under the cursor, as clicking it does. Plugins make buttons with a
-- mark's `action`, like a proposal's accept and reject or a todo's box,
-- or offer them where no mark is (`offer`), like a Markdown table's cells.

local greed = require("@greed")
local registry = require("./registry")

local M = {}

--- A button: its text, the command it runs and where its mark starts.
export type Button = { text: string, action: string, from: number }

export type Chooser = (buttons: { Button }, press: (button: Button) -> ()) -> ()

local function first(buttons: { Button }, press: (button: Button) -> ())
	press(buttons[1])
end

local chooser: Chooser = first

--- Chooses among several buttons under the cursor and calls `press` with
--- the one chosen: the first, unless a plugin set a chooser.
function M.choose(buttons: { Button }, press: (button: Button) -> ())
	chooser(buttons, press)
end

--- Makes `choose` ask with `choose`, like the picker plugin's list to pick
--- from. It goes when the plugin that set it does.
function M.set_chooser(choose: Chooser)
	chooser = choose
	greed.plugin.cleanup(function()
		if chooser == choose then
			chooser = first
		end
	end)
end

export type Offer = (buffer: greed.Buffer, pos: number) -> Button?

local offers: { Offer } = {}

--- Makes `offer` say what button is at a place without a mark's, like
--- the cell of a table the cursor is in. It's asked only where no mark
--- is a button, and goes when the plugin that made it does.
function M.offer(offer: Offer)
	greed.plugin.cleanup(registry.put(offers, offer))
end

--- The buttons over `pos` in `buffer`, in the order their marks start, or
--- else the one offered there.
function M.at(buffer: greed.Buffer, pos: number): { Button }
	local buttons: { Button } = {}
	for _, mark in buffer:marks_at(pos) do
		local action = mark.action
		if action then
			local text = mark.text or buffer:slice(mark.from, mark.to)
			table.insert(buttons, { text = text, action = action, from = mark.from })
		end
	end
	table.sort(buttons, function(a: Button, b: Button)
		return a.from < b.from
	end)
	if #buttons == 0 then
		for _, offer in offers do
			local button = offer(buffer, pos)
			if button then
				return { button }
			end
		end
	end
	return buttons
end

greed.command({
	name = "press-button",
	doc = "Run the button under the cursor, as clicking it does",
	run = function(ctx)
		local view = ctx.view
		local buttons = M.at(ctx.buffer, view:cursor())
		-- The cursor goes to the button first, as a click puts it.
		local function press(button: Button)
			view:set_selection({
				ranges = { { anchor = button.from, head = button.from } },
				primary = 1,
			})
			greed.run(button.action)
		end
		if #buttons == 1 then
			press(buttons[1])
		elseif #buttons > 1 then
			M.choose(buttons, press)
		end
	end,
})

return M
