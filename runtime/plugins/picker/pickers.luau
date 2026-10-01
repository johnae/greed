-- The pickers Kern ships with: files, open buffers and commands.

local kern = require("@kern")
local picker = require("./picker")

kern.command({
	name = "pick-file",
	doc = "Open a file from the current directory, skipping ignored files",
	run = function()
		local items = {}
		for _, path in kern.files() do
			table.insert(items, { label = path, value = path })
		end
		picker.pick("Files", items, function(item)
			kern.open(item.value)
		end)
	end,
})

kern.command({
	name = "pick-buffer",
	doc = "Switch to an open file",
	run = function()
		local items = {}
		for _, buffer in kern.buffers() do
			local path = buffer:path()
			if path then
				table.insert(items, { label = path, value = path })
			end
		end
		picker.pick("Buffers", items, function(item)
			kern.open(item.value)
		end)
	end,
})

kern.command({
	name = "command-palette",
	doc = "Run any command by name",
	run = function()
		local items = {}
		for _, command in kern.commands() do
			table.insert(items, { label = command.name .. "  " .. command.doc, value = command.name })
		end
		picker.pick("Commands", items, function(item)
			kern.run(item.value)
		end)
	end,
})

return {}
