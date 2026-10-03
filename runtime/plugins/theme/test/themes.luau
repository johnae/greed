local test = require("@greed/test")
local greed = require("@greed")
local theme = require("@theme")

local function fg(name: string): string?
	local entry = greed.theme.get(name)
	return entry and entry.fg
end

test("every theme Greed comes with styles the editor's own names", function()
	local names = theme.list()
	for _, wanted in
		{ "nord", "nord-light", "dracula", "catppuccin-mocha", "gruvbox", "tokyonight" }
	do
		assert(table.find(names, wanted), wanted .. " is missing")
	end
	for _, name in names do
		theme.use(name)
		for _, style in { "ui.selection", "ui.statusline", "ui.float.border", "keyword", "comment" } do
			assert(greed.theme.get(style), `{name} has no {style}`)
		end
	end
	theme.use("nord")
	assert(fg("keyword") == "#81a1c1", "Nord's keywords are its frost blue")
	assert((greed.theme.get("ui.text") :: greed.ThemeEntry).bg == "#2e3440")
	theme.use("default")
end)

test(":theme switches and remembers the theme for next time", function(t)
	t:run("theme", { "dracula" })
	assert(theme.current() == "dracula")
	assert(fg("keyword") == "#ff79c6")
	local cache = greed.fs.dirs().cache :: string
	assert(greed.fs.read(cache .. "/theme") == "dracula\n", "remembered")
	assert(not pcall(t.run, t, "theme", { "no-such-theme" }), "an unknown theme fails")
	theme.use("default")
end)

test("the picker tries each theme as you move, and esc goes back", function(t)
	theme.use("nord")
	t:buffer("|x")
	t:run("theme")
	assert(theme.current() == "nord", "opening it changes nothing")
	t:keys("ctrl-n")
	assert(theme.current() ~= "nord", "moving tries the next one")
	t:keys("esc")
	assert(theme.current() == "nord", "esc goes back")
	t:run("theme")
	t:keys("d r a c u l a enter")
	assert(theme.current() == "dracula", "enter keeps it")
	theme.use("default")
end)

test("entries set from a config stay on top whichever theme is in use", function()
	greed.theme.set({ comment = { fg = "#123456" } })
	theme.use("gruvbox")
	assert(fg("comment") == "#123456")
	theme.use("nord")
	assert(fg("comment") == "#123456")
	assert(fg("keyword") == "#81a1c1", "the rest is the theme's")
	theme.use("default")
end)

test("your own themes start from a palette or another theme", function()
	theme.define(
		"bolder",
		{ inherits = "nord", styles = { keyword = { fg = "#ffffff", bold = true } } }
	)
	theme.use("bolder")
	assert(fg("keyword") == "#ffffff" and fg("string") == "#a3be8c", "nord underneath")
	theme.define("loop", { inherits = "loop" })
	assert(not pcall(theme.use, "loop"), "a theme can't inherit from itself")
	theme.use("default")
end)

test("a theme's styles and your own entries change only the fields they give", function()
	theme.define("plain-comments", { inherits = "nord", styles = { comment = { italic = false } } })
	theme.use("plain-comments")
	local comment = greed.theme.get("comment") :: greed.ThemeEntry
	assert(comment.fg == "#616e88" and comment.italic == false, "nord's color stays")
	greed.theme.set({ keyword = { bold = true } })
	local keyword = greed.theme.get("keyword") :: greed.ThemeEntry
	assert(keyword.fg == "#81a1c1" and keyword.bold == true, "the theme's color stays")
	theme.use("default")
end)
