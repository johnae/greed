-- What counts as unsaved: a file's buffer with changes, unless it's marked
-- as scratch, a buffer whose changes nobody needs to save, like a shell's,
-- a terminal's or the output a command put in a buffer.

local greed = require("@greed")

local M = {}

-- Scratch buffers, by id.
local scratch: { [number]: boolean } = {}

--- Marks `buffer` as scratch: while it has no file, its changes don't
--- count as unsaved, so `:q` doesn't refuse over them and the status line
--- shows no [+]. Saved as a file, it's like any other.
function M.scratch(buffer: greed.Buffer)
	scratch[buffer:id()] = true
end

--- Whether `buffer` is scratch: marked so, and without a file.
function M.is_scratch(buffer: greed.Buffer): boolean
	return scratch[buffer:id()] == true and buffer:path() == nil
end

--- Whether `buffer` has changes to save: a file's, not scratch, changed
--- since it was opened or saved.
function M.unsaved(buffer: greed.Buffer): boolean
	return buffer:kind() == "file" and not M.is_scratch(buffer) and buffer:modified()
end

greed.on("buffer.closed", function(event: greed.BufferClosed)
	scratch[event.id] = nil
end)

return M
