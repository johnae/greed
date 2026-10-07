-- Files changed on disk, by another program or an agent, come into their
-- buffers as edits by "external": undo takes them back, and history says
-- where they came from. A buffer with unsaved changes isn't touched;
-- `:reload` loads the file into it anyway.

local greed = require("@greed")
local project = require("./project")

greed.option.define({
	name = "auto-reload",
	default = true,
	doc = "Load files changed on disk into their buffers, unless they have unsaved changes",
})

-- What each buffer's file held when Greed last read or wrote it, so its own
-- saves aren't taken for changes.
local known: { [number]: string } = {}

local function name(path: string): string
	return project.basename(path) or path
end

-- Starts watching `buffer`'s file, once.
local function watch(buffer: greed.Buffer)
	local path = buffer:path()
	if path and buffer:kind() == "file" and known[buffer:id()] == nil then
		known[buffer:id()] = greed.fs.read(path) or buffer:text()
		greed.fs.watch(path)
	end
end

greed.on("buffer.opened", function(event: greed.BufferChanged)
	watch(event.buffer)
end)

greed.on("buffer.changed", function(event: greed.BufferChanged)
	watch(event.buffer)
end)

greed.on("buffer.saved", function(event: greed.BufferChanged)
	known[event.buffer:id()] = event.buffer:text()
end)

greed.on("buffer.closed", function(event: greed.BufferClosed)
	known[event.id] = nil
end)

greed.on("file.changed", function(event: greed.FileChanged)
	local buffer = greed.buffer_for(event.path)
	local disk = greed.fs.read(event.path)
	if buffer == nil or disk == nil or disk == known[buffer:id()] then
		return
	end
	known[buffer:id()] = disk
	if buffer:modified() then
		greed.echo(`{name(event.path)} changed on disk; :reload loads it, and u takes that back`)
	elseif greed.option.get("auto-reload") then
		buffer:reload()
	end
end)

greed.command({
	name = "reload",
	doc = "Load the file again from disk, as an edit undo can take back",
	run = function(ctx)
		if ctx.buffer:path() == nil then
			greed.echo("this buffer has no file")
		elseif ctx.buffer:reload() then
			known[ctx.buffer:id()] = ctx.buffer:text()
		else
			greed.echo("the file is the same as the buffer")
		end
	end,
})

return {}
