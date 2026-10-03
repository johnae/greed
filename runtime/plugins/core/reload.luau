-- Files changed on disk, by another program or an agent, come into their
-- buffers as edits by "external": undo takes them back, and history says
-- where they came from. A buffer with unsaved changes isn't touched;
-- `:reload` loads the file into it anyway.

local kern = require("@kern")

kern.option.define({
	name = "auto-reload",
	default = true,
	doc = "Load files changed on disk into their buffers, unless they have unsaved changes",
})

-- What each buffer's file held when Kern last read or wrote it, so its own
-- saves aren't taken for changes.
local known: { [number]: string } = {}

local function file_buffer(path: string): kern.Buffer?
	for _, buffer in kern.buffers() do
		if buffer:path() == path then
			return buffer
		end
	end
	return nil
end

local function name(path: string): string
	return string.match(path, "[^/]+$") or path
end

-- Starts watching `buffer`'s file, once.
local function watch(buffer: kern.Buffer)
	local path = buffer:path()
	if path and buffer:kind() == "file" and known[buffer:id()] == nil then
		known[buffer:id()] = kern.fs.read(path) or buffer:text()
		kern.fs.watch(path)
	end
end

kern.on("buffer.opened", function(event: kern.BufferChanged)
	watch(event.buffer)
end)

kern.on("buffer.changed", function(event: kern.BufferChanged)
	watch(event.buffer)
end)

kern.on("buffer.saved", function(event: kern.BufferChanged)
	known[event.buffer:id()] = event.buffer:text()
end)

kern.on("buffer.closed", function(event: kern.BufferClosed)
	known[event.id] = nil
end)

kern.on("file.changed", function(event: kern.FileChanged)
	local buffer = file_buffer(event.path)
	local disk = kern.fs.read(event.path)
	if buffer == nil or disk == nil or disk == known[buffer:id()] then
		return
	end
	known[buffer:id()] = disk
	if buffer:modified() then
		kern.echo(`{name(event.path)} changed on disk; :reload loads it, and u takes that back`)
	elseif kern.option.get("auto-reload") then
		buffer:reload()
	end
end)

kern.command({
	name = "reload",
	doc = "Load the file again from disk, as an edit undo can take back",
	run = function(ctx)
		if ctx.buffer:path() == nil then
			kern.echo("this buffer has no file")
		elseif ctx.buffer:reload() then
			known[ctx.buffer:id()] = ctx.buffer:text()
		else
			kern.echo("the file is the same as the buffer")
		end
	end,
})

return {}
