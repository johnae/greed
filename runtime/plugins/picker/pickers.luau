-- The pickers Kern ships with: files in the project, open buffers, projects
-- and commands.

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

-- "~/src/kern" for a folder in the home directory, since that's how
-- people say it.
local function short(path: string): string
	local home = kern.fs.dirs().config
	home = home and string.match(home, "^(.*)/%.config/kern$")
	if home and string.sub(path, 1, #home + 1) == home .. "/" then
		return "~" .. string.sub(path, #home + 1)
	end
	return path
end

kern.command({
	name = "pick-project",
	doc = "Switch to another project: one open here, or another running session",
	run = function()
		local items = {}
		for _, p in kern.project.list() do
			local label = short(p.root) .. if p.current then "  (shown)" else ""
			table.insert(items, { label = label, value = { project = p.id } })
		end
		for _, s in kern.session.list() do
			if not s.current then
				local label = `{if s.root then short(s.root) else s.name}  (session {s.name})`
				table.insert(items, { label = label, value = { session = s.name } })
			end
		end
		picker.pick("Projects", items, function(item)
			if item.value.project then
				kern.project.switch(item.value.project)
			else
				kern.session.switch({ name = item.value.session })
			end
		end)
	end,
})

kern.command({
	name = "command-palette",
	doc = "Run any command by name",
	run = function()
		local items = {}
		for _, command in kern.commands() do
			table.insert(
				items,
				{ label = command.name .. "  " .. command.doc, value = command.name }
			)
		end
		picker.pick("Commands", items, function(item)
			kern.run(item.value)
		end)
	end,
})

return {}
