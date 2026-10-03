-- The pickers Greed ships with: files in the project, open buffers,
-- commands and the outline of a file.

local greed = require("@greed")
local picker = require("./picker")
local project = require("@core").project

-- At most this much of a file is read for its preview.
local PREVIEW_BYTES = 64 * 1024

-- A file's start, highlighted in its language.
local function file_preview(item: picker.Item): picker.Preview?
	local text = greed.fs.read(item.value, PREVIEW_BYTES)
	if text == nil then
		return nil
	end
	if string.find(text, "\0", 1, true) then
		return { text = "(binary file)" }
	end
	return { text = text, language = greed.language_of(item.value) }
end

-- An open buffer's text as it is now, saved or not.
local function buffer_preview(item: picker.Item): picker.Preview?
	for _, buffer in greed.buffers() do
		if buffer:path() == item.value then
			return { text = buffer:text(), language = buffer:language() }
		end
	end
	return nil
end

-- Picks a file under `root`, skipping ignored files, and opens it.
local function pick_file(title: string, root: string)
	local items = {}
	for _, path in greed.files(root) do
		table.insert(items, { label = path, value = project.path(root, path) })
	end
	picker.pick(title, items, function(item)
		greed.open(item.value)
	end, { preview = file_preview })
end

greed.command({
	name = "pick-file",
	doc = "Open a file in the project, skipping ignored files",
	run = function()
		pick_file("Files", project.root())
	end,
})

greed.command({
	name = "pick-file-here",
	doc = "Open a file under the folder Greed was started in, skipping ignored files",
	run = function()
		pick_file("Files here", greed.fs.cwd())
	end,
})

greed.command({
	name = "picker-resume",
	doc = "Open the last picker again",
	run = function()
		if not picker.resume() then
			greed.echo("no picker yet")
		end
	end,
})

greed.command({
	name = "pick-buffer",
	doc = "Switch to an open file",
	run = function()
		local items = {}
		for _, buffer in greed.buffers() do
			local path = buffer:path()
			if path then
				table.insert(items, { label = path, value = path })
			end
		end
		picker.pick("Buffers", items, function(item)
			greed.open(item.value)
		end, { preview = buffer_preview })
	end,
})

greed.command({
	name = "command-palette",
	doc = "Run any command by name",
	run = function()
		-- Keys that run each command in the mode the palette opened from.
		local mode = greed.mode.get()
		-- Every binding at once: one lookup per command takes long enough with
		-- hundreds of them that keys typed right away miss the picker.
		local keys_of: { [string]: { string } } = {}
		for _, binding in greed.keymap.find() do
			if binding.layer == mode or binding.layer == "global" then
				local list = keys_of[binding.command] or {}
				table.insert(list, binding.keys)
				keys_of[binding.command] = list
			end
		end
		local items = {}
		for _, command in greed.commands() do
			local keys = keys_of[command.name] or {}
			local label = command.name
			if #keys > 0 then
				label ..= `  ({table.concat(keys, ", ")})`
			end
			table.insert(items, { label = `{label}  {command.doc}`, value = command.name })
		end
		picker.pick("Commands", items, function(item)
			greed.run(item.value)
		end)
	end,
})

greed.command({
	name = "pick-outline",
	doc = "Jump to a function or type in the file, from its syntax tree",
	run = function(ctx)
		local buffer, view = ctx.buffer, ctx.view
		local syntax = require("@core").syntax
		local found: { { node: greed.Node, name: greed.Node } } = {}
		for _, object in { "function", "type" } do
			for _, o in syntax.objects(buffer, object) do
				local name = o.around:child("name")
				if name then
					table.insert(found, { node = o.around, name = name })
				end
			end
		end
		table.sort(found, function(a: { name: greed.Node }, b: { name: greed.Node })
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

greed.command({
	name = "pick-jump",
	doc = "Pick a place from the jumplist and go there",
	run = function()
		local jumps = require("@core").jumps
		local root = project.root() .. "/"
		local items = {}
		for _, place in jumps.list() do
			local buffer: greed.Buffer? = nil
			for _, open in greed.buffers() do
				if open:id() == place.buffer then
					buffer = open
				end
			end
			local path = place.path
			local name = if path == nil
				then "[scratch]"
				elseif string.sub(path, 1, #root) == root then string.sub(path, #root + 1)
				else path
			local where, line = "?", ""
			if buffer then
				local row = buffer:line_of(math.min(place.pos, buffer:len()))
				where = tostring(row + 1)
				line = string.gsub(
					buffer:slice(buffer:line_start(row), buffer:line_end(row)),
					"^%s+",
					""
				)
			end
			table.insert(items, { label = `{name}:{where}  {line}`, value = place })
		end
		if #items == 0 then
			greed.echo("the jumplist is empty")
			return
		end
		picker.pick("Jumplist", items, function(item)
			jumps.go(item.value)
		end)
	end,
})

return {}
