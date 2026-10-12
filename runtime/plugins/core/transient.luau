-- Menus of keys, like Emacs's Transient: a panel at the bottom lists what
-- each key does, in groups, with switches (`-a`, `-f`, ...) that stay
-- flipped while you pick the action. The key typed next flips a switch or
-- runs an action and closes the menu; any other key closes it.
--
--     core.transient.show({
--         title = "Push",
--         groups = {
--             { title = "Switches", items = { { key = "f", doc = "force", switch = "force" } } },
--             { title = "Push", items = { { key = "p", doc = "to origin", run = function(on)
--                 push(on.force)
--             end } } },
--         },
--     })
--
-- `show` waits for the keys, so call it from a command.

local greed = require("@greed")
local ui = require("./ui")

local M = {}

--- A key in a menu: a switch flips the named switch; otherwise `run` is
--- called with the switches that are on.
export type Item = {
	key: string,
	doc: string,
	switch: string?,
	run: ((switches: { [string]: boolean }) -> ())?,
}

export type Group = { title: string, items: { Item } }

export type Menu = {
	title: string,
	groups: { Group },
	--- Switches on when the menu opens.
	switches: { [string]: boolean }?,
}

-- The menu: each group's title over its keys, the switches that are on
-- saying so.
local function draw(menu: Menu, switches: { [string]: boolean }): ui.Node
	local parts: { ui.Node } = {}
	for i, group in menu.groups do
		if i > 1 then
			table.insert(parts, ui.gap())
		end
		table.insert(parts, ui.line({ ui.span(group.title, "markup.heading") }))
		for _, item in group.items do
			local key = if item.switch then `-{item.key}` else item.key
			local spans = {
				ui.span(" "),
				ui.span(key, "keyword"),
				ui.span(`{string.rep(" ", math.max(1, 6 - #key))}{item.doc}`),
			}
			if item.switch and switches[item.switch] then
				table.insert(spans, ui.span("  (on)", "diff.plus"))
			end
			table.insert(parts, ui.line(spans))
		end
	end
	return ui.column(parts)
end

--- Shows `menu` and waits: a switch's key flips it and the menu stays, an
--- action's key closes the menu and runs it, anything else closes it.
--- Switch keys are typed as themselves (`f`) or after a dash (`- f`).
function M.show(menu: Menu)
	local switches = table.clone(menu.switches or {})
	local buffer = greed.create_buffer("transient", "", { readonly = true })
	buffer:set_line_numbers(false)
	local drawn = ui.mount(buffer, function()
		return draw(menu, switches)
	end, nil, { ns = "transient", keys = false })
	local view: greed.View? = nil
	local function render()
		drawn:redraw()
		local height = buffer:line_count() + 2
		if view then
			view:configure({ height = height })
		else
			view = greed.float(buffer, {
				title = menu.title,
				width = "100%",
				height = height,
				anchor = "bottom",
				focus = false,
			})
		end
	end
	local function close()
		if view then
			view:close()
		end
	end
	while true do
		render()
		local key = greed.next_key()
		if key == "-" then
			key = greed.next_key()
		end
		local chosen: Item? = nil
		for _, group in menu.groups do
			for _, item in group.items do
				if item.key == key then
					chosen = item
				end
			end
		end
		if chosen == nil then
			close()
			return
		end
		local switch = chosen.switch
		if switch then
			switches[switch] = not switches[switch]
		else
			close()
			if chosen.run then
				chosen.run(switches)
			end
			return
		end
	end
end

return M
