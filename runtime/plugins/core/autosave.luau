-- Saving files on their own: with `auto-save` on, a file with unsaved
-- changes is saved once its edits have stopped for `auto-save-delay`
-- milliseconds, so a burst of typing is one save. It saves as `:w` does,
-- quietly, with the save hooks told it's an auto-save.
--
-- Buffers that aren't files keep themselves the same way with `on_quiet`,
-- as mail being written does:
--
--     core.autosave.on_quiet("mail-compose", function(buffer) ... end)

local greed = require("@greed")
local file = require("./file")

local M = {}

greed.option.define({
	name = "auto-save",
	needs = "fs.write",
	default = false,
	doc = "Save files on their own a moment after their edits stop",
})

greed.option.define({
	name = "auto-save-delay",
	default = 1000,
	doc = "How long after the last edit auto-save saves, in milliseconds",
})

-- Each buffer's latest edit, counted, so only the last of a burst saves.
local edits: { [number]: number } = {}

type Keeper = {
	keep: (buffer: greed.Buffer) -> (),
	wanted: ((buffer: greed.Buffer) -> boolean)?,
}

-- What keeps buffers of each kind, by kind.
local keepers: { [string]: Keeper } = {}

--- Runs `keep(buffer)` once a buffer of `kind` has stopped changing for
--- `auto-save-delay` milliseconds, if `wanted(buffer)` (when given) said
--- yes as it changed. It goes with the plugin that set it.
function M.on_quiet(
	kind: string,
	keep: (buffer: greed.Buffer) -> (),
	wanted: ((buffer: greed.Buffer) -> boolean)?
)
	local keeper = { keep = keep, wanted = wanted }
	keepers[kind] = keeper
	greed.plugin.cleanup(function()
		if keepers[kind] == keeper then
			keepers[kind] = nil
		end
	end)
end

greed.on("buffer.changed", function(event: greed.BufferChanged)
	local buffer = event.buffer
	local keeper = keepers[buffer:kind()]
	if keeper == nil or (keeper.wanted and not keeper.wanted(buffer)) then
		return
	end
	local id = buffer:id()
	local this = (edits[id] or 0) + 1
	edits[id] = this
	greed.spawn(function()
		greed.sleep(greed.option.get("auto-save-delay") :: number)
		if edits[id] ~= this then
			return
		end
		edits[id] = nil
		if buffer:valid() then
			keeper.keep(buffer)
		end
	end)
end)

greed.on("buffer.closed", function(event: greed.BufferClosed)
	edits[event.id] = nil
end)

M.on_quiet("file", function(buffer: greed.Buffer)
	-- It may have been saved, turned read-only or auto-save turned off
	-- meanwhile.
	local ok = pcall(function()
		if
			greed.option.get("auto-save") == true
			and buffer:modified()
			and not buffer:readonly()
		then
			file.autosave(buffer)
		end
	end)
	if not ok then
		greed.echo(`auto-save couldn't save {buffer:path() or "a file"}`)
	end
end, function(buffer: greed.Buffer): boolean
	return greed.option.get("auto-save") == true and buffer:path() ~= nil
end)

return M
