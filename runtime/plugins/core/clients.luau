-- What another client's doing does to this one. Following, it's shown the
-- tab and project the others are; when that takes away what it had
-- focused, its focus moves under it, and it goes on in the mode that fits
-- what it's in now (normal mode for a file or a terminal, typing for a
-- picker) rather than typing into the wrong thing.

local greed = require("@greed")
local style = require("./style")

greed.on("view.focused", function(event: greed.ViewFocused)
	if not event.moved or not event.view:valid() then
		return
	end
	local mode = style.home_for(event.view)
	if greed.mode.get() ~= mode then
		greed.mode.set(mode)
	end
end)

return {}
