-- Help: look up a command, or press a key, to see what it does, which keys
-- run it and where it's defined. In the help window, enter jumps to the
-- definition and esc (or q) closes it.
--
--   space h c   describe a command
--   space h k   describe a key

local greed = require("@greed")
local picker = require("@picker")

type Open = {
	view: greed.View,
	path: string?,
	line: number?,
}

local open: Open? = nil

local function close()
	if open then
		open.view:close()
		open = nil
	end
end

local function show(command: greed.CommandInfo)
	close()
	local lines = { command.name, "" }
	table.insert(lines, if command.doc == "" then "(no description)" else command.doc)
	table.insert(lines, "")
	local bindings = greed.keymap.find(command.name)
	if #bindings == 0 then
		table.insert(lines, "Keys: none")
	end
	for _, binding in bindings do
		table.insert(lines, `Keys: {binding.keys} ({binding.layer})`)
	end
	table.insert(lines, `Defined in {command.source or "?"} by the {command.owner} plugin`)
	if command.path then
		table.insert(lines, "")
		table.insert(lines, "enter: go to the definition   esc: close")
	end

	local buffer = greed.create_buffer("help", table.concat(lines, "\n"))
	open = {
		view = greed.float(buffer, { title = "Help", width = "70%", height = #lines + 2 }),
		path = command.path,
		line = command.line,
	}
end

greed.command({
	name = "describe-command",
	doc = "Show what a command does, its keys, and where it's defined",
	run = function()
		local items = {}
		for _, command in greed.commands() do
			table.insert(items, { label = command.name .. "  " .. command.doc, value = command })
		end
		picker.pick("Describe", items, function(item)
			show(item.value)
		end)
	end,
})

greed.command({
	name = "describe-key",
	doc = "Press keys to see what command they run",
	run = function()
		greed.echo("press a key to describe")
		local keys = ""
		while true do
			local key = greed.next_key()
			keys = if keys == "" then key else `{keys} {key}`
			local name, pending = greed.keymap.resolve(keys)
			if name then
				for _, command in greed.commands() do
					if command.name == name then
						show(command)
						return
					end
				end
				greed.echo(`{keys} runs {name}, which doesn't exist`)
				return
			elseif not pending then
				greed.echo(`{keys} isn't bound to anything`)
				return
			end
		end
	end,
})

greed.command({
	name = "help-close",
	doc = "Close the help window",
	run = close,
})

greed.command({
	name = "help-goto",
	doc = "Open the file a command is defined in, at its definition",
	run = function()
		local o = open
		if o == nil or o.path == nil then
			return
		end
		close()
		greed.open(o.path)
		local view = greed.view()
		local pos = view:buffer():line_start((o.line or 1) - 1)
		view:set_selection({ ranges = { { anchor = pos, head = pos } }, primary = 1 })
	end,
})

greed.keymap.bind({ mode = "normal", kind = "help" }, {
	esc = "help-close",
	q = "help-close",
	enter = "help-goto",
})

greed.keymap.bind("normal", {
	["space h c"] = "describe-command",
	["space h k"] = "describe-key",
})
