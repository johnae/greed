-- Saving files on their own: with `auto-save` on, a file with unsaved
-- changes is saved once its edits have stopped for `auto-save-delay`
-- milliseconds, so a burst of typing is one save.

local greed = require("@greed")

greed.option.define({
	name = "auto-save",
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

greed.on("buffer.changed", function(event: greed.BufferChanged)
	local buffer = event.buffer
	if greed.option.get("auto-save") ~= true or buffer:kind() ~= "file" or buffer:path() == nil then
		return
	end
	local id = buffer:id()
	local this = (edits[id] or 0) + 1
	edits[id] = this
	greed.spawn(function()
		greed.sleep(greed.option.get("auto-save-delay") :: number)
		if edits[id] ~= this or greed.option.get("auto-save") ~= true then
			return
		end
		edits[id] = nil
		-- It may have been closed, saved or turned read-only meanwhile.
		local ok = pcall(function()
			if buffer:modified() and not buffer:readonly() then
				buffer:save()
			end
		end)
		if not ok then
			greed.echo(`auto-save couldn't save {buffer:path() or "a file"}`)
		end
	end)
end)

greed.on("buffer.closed", function(event: greed.BufferClosed)
	edits[event.id] = nil
end)

return {}
