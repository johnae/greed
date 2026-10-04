-- When markup a plugin hides (a todo's box, a link's brackets, a heading's
-- hashes) shows as written, as a mark's `reveal` wants it: while typing (an
-- insert mode) on its line; in a style without modes, once the cursor is
-- inside it rather than at its start, where a click puts it; otherwise
-- never, so moving around and clicking keep the looks. Plugins draw their
-- marks again on "mode.changed" to follow it.

local greed = require("@greed")

return function(): "line" | "cursor" | "never"
	local mode = greed.mode.get()
	if string.find(mode, "insert", 1, true) then
		return "line"
	elseif mode == "edit" then
		return "cursor"
	end
	return "never"
end
