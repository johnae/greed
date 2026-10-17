-- Snippets' places where typing replaces the selection.

local test = require("@greed/test")
local greed = require("@greed")

test("typing over a snippet's place replaces it, and tab goes on", function(t)
	local core = require("@core")
	t:buffer("|")
	greed.mode.set("vscode")
	core.snippet.expand(greed.view(), 0, 0, "${1:a} ${2:b}")
	t:keys("x tab y")
	t:expect("x y|")
end)
