local test = require("@kern/test")
local kern = require("@kern")

test("the default theme styles the editor's own names and syntax", function()
	for _, name in { "ui.selection", "ui.statusline", "ui.float.border", "diagnostic.error", "keyword", "comment" } do
		assert(kern.theme.get(name) ~= nil, name .. " has no entry")
	end
	local keyword = kern.theme.get("keyword") :: kern.ThemeEntry
	assert(keyword.fg == "magenta", "keywords are magenta")
end)

test("a config can change single entries", function()
	kern.theme.set({ keyword = { fg = "#ff8000" } })
	assert((kern.theme.get("keyword") :: kern.ThemeEntry).fg == "#ff8000", "changed")
	assert((kern.theme.get("comment") :: kern.ThemeEntry).italic == true, "the rest stays")
end)
