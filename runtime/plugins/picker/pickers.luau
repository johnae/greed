-- The pickers Kern ships with: files in the project, open buffers,
-- commands and the outline of a file.

local kern = require("@kern")
local picker = require("./picker")
local project = require("@core").project

-- At most this much of a file is read for its preview.
local PREVIEW_BYTES = 64 * 1024

-- A file's start, highlighted in its language.
local function file_preview(item: picker.Item): picker.Preview?
	local text = kern.fs.read(item.value, PREVIEW_BYTES)
	if text == nil then
		return nil
	end
	if string.find(text, "\0", 1, true) then
		return { text = "(binary file)" }
	end
	return { text = text, language = kern.language_of(item.value) }
end

-- An open buffer's text as it is now, saved or not.
local function buffer_preview(item: picker.Item): picker.Preview?
	for _, buffer in kern.buffers() do
		if buffer:path() == item.value then
			return { text = buffer:text(), language = buffer:language() }
		end
	end
	return nil
end

kern.command({
	name = "pick-file",
	doc = "Open a file in the project, skipping ignored files",
	run = function()
		local root = project.root()
		local items = {}
		for _, path in kern.files(root) do
			table.insert(items, { label = path, value = project.path(root, path) })
		end
		picker.pick("Files", items, function(item)
			kern.open(item.value)
		end, { preview = file_preview })
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
		end, { preview = buffer_preview })
	end,
})

kern.command({
	name = "command-palette",
	doc = "Run any command by name",
	run = function()
		-- Keys that run each command in the mode the palette opened from.
		local mode = kern.mode.get()
		local items = {}
		for _, command in kern.commands() do
			local keys = {}
			for _, binding in kern.keymap.find(command.name) do
				if binding.layer == mode or binding.layer == "global" then
					table.insert(keys, binding.keys)
				end
			end
			local label = command.name
			if #keys > 0 then
				label ..= `  ({table.concat(keys, ", ")})`
			end
			table.insert(items, { label = `{label}  {command.doc}`, value = command.name })
		end
		picker.pick("Commands", items, function(item)
			kern.run(item.value)
		end)
	end,
})

kern.command({
	name = "pick-outline",
	doc = "Jump to a function or type in the file, from its syntax tree",
	run = function(ctx)
		local buffer, view = ctx.buffer, ctx.view
		local syntax = require("@core").syntax
		local found: { { node: kern.Node, name: kern.Node } } = {}
		for _, object in { "function", "type" } do
			for _, o in syntax.objects(buffer, object) do
				local name = o.around:child("name")
				if name then
					table.insert(found, { node = o.around, name = name })
				end
			end
		end
		table.sort(found, function(a: { name: kern.Node }, b: { name: kern.Node })
			return a.name.from < b.name.from
		end)
		local items = {}
		for _, f in found do
			-- Nested items are indented under what holds them.
			local depth = 0
			for _, other in found do
				if other.node.from < f.node.from and f.node.to <= other.node.to then
					depth += 1
				end
			end
			local line = buffer:line_of(f.name.from)
			table.insert(items, {
				label = `{string.rep("  ", depth)}{f.name:text()}  {f.node.kind}:{line + 1}`,
				value = f.name.from,
			})
		end
		local text, language = buffer:text(), buffer:language()
		picker.pick("Outline", items, function(item)
			view:set_selection({
				ranges = { { anchor = item.value, head = item.value } },
				primary = 1,
			})
		end, {
			preview = function(item)
				return { text = text, language = language, line = buffer:line_of(item.value) }
			end,
		})
	end,
})

return {}
