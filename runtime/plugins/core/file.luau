-- Opening, saving and quitting.

local kern = require("@kern")

local M = {}

-- How buffers that aren't files save, by kind.
local savers: { [string]: (buffer: kern.Buffer) -> () } = {}

--- Makes :w on buffers of `kind` call `save` rather than write a file,
--- e.g. for a list of search results that writes its edits back.
function M.on_save(kind: string, save: (buffer: kern.Buffer) -> ())
	savers[kind] = save
end

local function save(buffer: kern.Buffer, path: string?)
	local saver = savers[buffer:kind()]
	if saver and path == nil then
		saver(buffer)
		return
	end
	buffer:save(path)
	kern.echo("wrote " .. (buffer:path() or "?"))
end

-- Fails if any file has unsaved changes, unless `force` says to go ahead.
local function check_unsaved(force: boolean)
	if force then
		return
	end
	local unsaved = {}
	for _, buffer in kern.buffers() do
		if buffer:kind() == "file" and buffer:modified() then
			table.insert(unsaved, buffer:path() or "an unnamed buffer")
		end
	end
	if #unsaved > 0 then
		error(
			"unsaved changes in " .. table.concat(unsaved, ", ") .. " - :w saves, :q! quits anyway",
			0
		)
	end
end

kern.command({
	name = "save",
	doc = "Write the buffer to its file, or to a new one",
	args = {
		{
			name = "path",
			doc = "Where to write it; it becomes the buffer's file",
			complete = "file",
		},
	},
	run = function(ctx)
		save(ctx.buffer, ctx.args[1])
	end,
})

kern.command({
	name = "detach",
	doc = "Leave the editor running in the background; kern attach comes back",
	run = function()
		kern.detach()
	end,
})

kern.command({
	name = "quit",
	doc = "Exit the editor, unless files have unsaved changes (force exits anyway)",
	run = function(ctx)
		check_unsaved(ctx.force)
		kern.quit()
	end,
})

kern.command({
	name = "save-quit",
	doc = "Write the buffer to its file, then exit",
	run = function(ctx)
		save(ctx.buffer)
		check_unsaved(ctx.force)
		kern.quit()
	end,
})

kern.command({
	name = "open",
	doc = "Open a file in the main view",
	args = {
		{
			name = "path",
			doc = "The file to open; a new one is created when saved",
			complete = "file",
		},
	},
	run = function(ctx)
		local path = ctx.args[1]
		if path == nil then
			error("open needs a path, e.g. :open src/main.rs", 0)
		end
		kern.open(path)
	end,
})

return M
