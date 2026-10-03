local test = require("@greed/test")
local greed = require("@greed")

test("the default theme styles the editor's own names and syntax", function()
	for _, name in { "ui.selection", "ui.statusline", "ui.float.border", "diagnostic.error", "keyword", "comment" } do
		assert(greed.theme.get(name) ~= nil, name .. " has no entry")
	end
	local keyword = greed.theme.get("keyword") :: greed.ThemeEntry
	assert(keyword.fg == "magenta", "keywords are magenta")
end)

test("a config can change single entries", function()
	greed.theme.set({ keyword = { fg = "#ff8000" } })
	assert((greed.theme.get("keyword") :: greed.ThemeEntry).fg == "#ff8000", "changed")
	assert((greed.theme.get("comment") :: greed.ThemeEntry).italic == true, "the rest stays")
end)
