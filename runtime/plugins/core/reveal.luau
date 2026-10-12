-- When markup a plugin hides (a todo's box, a link's brackets, a heading's
-- hashes) shows as written, as a mark's `reveal` wants it, in the current
-- mode: see `style.reveal` and `style.typing_reveal`. Marks with `reveal =
-- "auto"` or "typing" follow it as the mode changes without being drawn
-- again.

local greed = require("@greed")
local style = require("./style")

local function reveal(): "line" | "cursor" | "never"
	return style.reveal()
end

local function update()
	greed.reveal(style.reveal(), style.typing_reveal())
end

update()
greed.on("mode.changed", update)
-- A mode's say waits on its style, which can come after the mode is set.
style.each_typing(update)
greed.on("option.changed", function(event)
	if event.name == "markup-reveal" then
		update()
	end
end)

return reveal
