-- Opening, saving and quitting.

local kern = require("@kern")
local project = require("./project")

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

-- Fails if any of `unsaved` has changes, unless `force` says to go ahead.
local function check_unsaved(unsaved: { string }, force: boolean)
	if #unsaved > 0 and not force then
		error(
			"unsaved changes in " .. table.concat(unsaved, ", ") .. " - :w saves, :q! quits anyway",
			0
		)
	end
end

-- Every file with unsaved changes, in any project.
local function all_unsaved(): { string }
	local unsaved = {}
	for _, buffer in kern.buffers() do
		if buffer:kind() == "file" and buffer:modified() then
			table.insert(unsaved, buffer:path() or "an unnamed buffer")
		end
	end
	return unsaved
end

-- Leaves the shown project: with others open it closes and the terminal
-- lets go, leaving the rest running; the last one quits the editor.
local function quit(force: boolean)
	if #kern.project.list() == 1 then
		check_unsaved(all_unsaved(), force)
		kern.quit()
		return
	end
	check_unsaved(project.unsaved(), force)
	kern.project.close(kern.project.current().id)
	kern.detach()
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
	doc = "Close the project and leave, or exit the editor if it's the last one; "
		.. "refuses with unsaved changes (force goes anyway)",
	run = function(ctx)
		quit(ctx.force)
	end,
})

kern.command({
	name = "quit-all",
	doc = "Exit the editor and every project, unless files have unsaved changes (force exits anyway)",
	run = function(ctx)
		check_unsaved(all_unsaved(), ctx.force)
		kern.quit()
	end,
})

kern.command({
	name = "save-quit",
	doc = "Write the buffer to its file, then quit",
	run = function(ctx)
		save(ctx.buffer)
		quit(ctx.force)
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
