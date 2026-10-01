-- Help: look up a command to see what it does, which keys run it and where
-- it's defined. In the help window, enter jumps to the definition and esc
-- (or q) closes it.

local kern = require("@kern")
local picker = require("@picker")

type Open = {
	view: kern.View,
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

local function show(command: kern.CommandInfo)
	close()
	local lines = { command.name, "" }
	table.insert(lines, if command.doc == "" then "(no description)" else command.doc)
	table.insert(lines, "")
	local bindings = kern.keymap.find(command.name)
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

	local buffer = kern.create_buffer("help", table.concat(lines, "\n"))
	open = {
		view = kern.float(buffer, { title = "Help", width = "70%", height = #lines + 2 }),
		path = command.path,
		line = command.line,
	}
end

kern.command({
	name = "describe-command",
	doc = "Show what a command does, its keys, and where it's defined",
	run = function()
		local items = {}
		for _, command in kern.commands() do
			table.insert(items, { label = command.name .. "  " .. command.doc, value = command })
		end
		picker.pick("Describe", items, function(item)
			show(item.value)
		end)
	end,
})

kern.command({
	name = "help-close",
	doc = "Close the help window",
	run = close,
})

kern.command({
	name = "help-goto",
	doc = "Open the file a command is defined in, at its definition",
	run = function()
		local o = open
		if o == nil or o.path == nil then
			return
		end
		close()
		kern.open(o.path)
		local view = kern.view()
		local pos = view:buffer():line_start((o.line or 1) - 1)
		view:set_selection({ ranges = { { anchor = pos, head = pos } }, primary = 1 })
	end,
})

kern.keymap.bind({ mode = "normal", kind = "help" }, {
	esc = "help-close",
	q = "help-close",
	enter = "help-goto",
})

kern.keymap.bind("normal", { ["space h"] = "describe-command" })
