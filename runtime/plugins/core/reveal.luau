-- When markup a plugin hides (a todo's box, a link's brackets, a heading's
-- hashes) shows as written, as a mark's `reveal` wants it, in the current
-- mode: see `style.reveal`. Marks with `reveal = "auto"` follow it as the
-- mode changes without being drawn again.

local greed = require("@greed")
local style = require("./style")

local function reveal(): "line" | "cursor" | "never"
	return style.reveal()
end

greed.reveal(reveal())
greed.on("mode.changed", function()
	greed.reveal(reveal())
end)

return reveal
