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

-- The menu's lines and the styles over them: group titles, keys, and the
-- switches that are on.
local function draw(menu: Menu, switches: { [string]: boolean }): (string, { greed.Mark })
	local lines: { string } = {}
	local marks: { greed.Mark } = {}
	local at = 0
	local function add(line: string, styles: { { from: number, to: number, style: string } }?)
		table.insert(lines, line)
		for _, style in styles or {} do
			table.insert(marks, { from = at + style.from, to = at + style.to, style = style.style })
		end
		at += #line + 1
	end
	for i, group in menu.groups do
		if i > 1 then
			add("")
		end
		add(group.title, { { from = 0, to = #group.title, style = "markup.heading" } })
		for _, item in group.items do
			local key = if item.switch then `-{item.key}` else item.key
			local line = ` {key}{string.rep(" ", math.max(1, 6 - #key))}{item.doc}`
			local styles = { { from = 1, to = 1 + #key, style = "keyword" } }
			if item.switch and switches[item.switch] then
				local on = "  (on)"
				table.insert(styles, { from = #line, to = #line + #on, style = "diff.plus" })
				line ..= on
			end
			add(line, styles)
		end
	end
	return table.concat(lines, "\n"), marks
end

--- Shows `menu` and waits: a switch's key flips it and the menu stays, an
--- action's key closes the menu and runs it, anything else closes it.
--- Switch keys are typed as themselves (`f`) or after a dash (`- f`).
function M.show(menu: Menu)
	local switches = table.clone(menu.switches or {})
	local buffer = greed.create_buffer("transient", "", { readonly = true })
	buffer:set_line_numbers(false)
	local view: greed.View? = nil
	local function render()
		local text, marks = draw(menu, switches)
		buffer:set_readonly(false)
		buffer:edit(function(e)
			e:replace(0, buffer:len(), text)
		end)
		buffer:set_readonly(true)
		buffer:decorate("transient", marks)
		local _, lines = string.gsub(text, "\n", "")
		local height = lines + 3
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
