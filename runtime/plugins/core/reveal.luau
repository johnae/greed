-- When markup a plugin hides (a todo's box, a link's brackets, a heading's
-- hashes) shows as written, as a mark's `reveal` wants it, in the current
-- mode: see `style.reveal`. Plugins draw their marks again on
-- "mode.changed" to follow it.

local style = require("./style")

return function(): "line" | "cursor" | "never"
	return style.reveal()
end
