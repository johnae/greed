local test = require("@greed/test")
local greed = require("@greed")
local docs = require("@docs")

test("the manual's pages are the contents' own, with their headings", function()
	local pages = docs.pages()
	assert(#pages > 5 and pages[1].title == "Greed", tostring(pages[1] and pages[1].title))
	for _, page in pages do
		assert(
			not string.find(page.path, "/reference/", 1, true),
			"the website's reference pages aren't here"
		)
	end
	local found = false
	for _, h in docs.headings() do
		if h.page == "The shell" and h.text == "Watching a command" then
			found = h.level == 2
		end
		assert(not string.match(h.text, "^%s*$"), "every heading has words")
	end
	assert(found, "the shell's page has its headings")
end)

test(":docs WORDS opens the page at its heading, read-only, as a document", function(t)
	t:buffer("|")
	t:run("docs", { "watching", "a", "command" })
	local buffer = greed.view():buffer()
	assert(string.find(buffer:path() or "", "shell.md$"), tostring(buffer:path()))
	assert(buffer:readonly(), "read-only")
	assert(greed.mode.get() == "read", greed.mode.get())
	local line = buffer:line_of(greed.view():cursor())
	local text = buffer:slice(buffer:line_start(line), buffer:line_end(line))
	assert(text == "## Watching a command", text)
	-- A page's title wins over headings with the same words.
	local boards = assert(docs.find("boards"))
	assert(boards.text == "Boards" and boards.level == 1, boards.text)
	assert(docs.find("nothing like this anywhere") == nil)
end)

test("space h d picks a heading from every page", function(t)
	t:buffer("|")
	t:keys("esc space h d")
	t:keys("b o a r d s space l i v e")
	local listed = table.concat(t:floats(), "\n")
	assert(string.find(listed, "Boards › Live charts", 1, true), listed)
	t:keys("enter")
	assert((string.find(greed.view():buffer():path() or "", "boards.md$")))
end)

test("space h / searches the pages as you type", function(t)
	t:buffer("|")
	t:keys("esc space h /")
	t:keys("s c e n e - d r a w i n g")
	t:wait(300)
	t:wait_for(function()
		return string.find(table.concat(t:floats(), "\n"), "shell: ", 1, true) ~= nil
	end)
	t:keys("enter")
	local buffer = greed.view():buffer()
	assert(string.find(buffer:path() or "", "/docs/[%w%-]+%.md$"), tostring(buffer:path()))
	local line = buffer:line_of(greed.view():cursor())
	local text = buffer:slice(buffer:line_start(line), buffer:line_end(line))
	assert(string.find(text, "scene-drawing", 1, true), text)
end)

test("enter on a link in a page goes to the page it names", function(t)
	t:buffer("|")
	t:run("docs", { "greed" })
	local buffer = greed.view():buffer()
	local text = buffer:text()
	local at = assert((string.find(text, "[Using Greed](using.md)", 1, true)))
	greed.view():set_cursor(at)
	t:keys("enter")
	local page = greed.view():buffer()
	assert(string.find(page:path() or "", "using.md$"), tostring(page:path()))
	assert(page:readonly(), "a page followed to is read-only too")
end)

test("a plugin's own docs folder joins the manual, README first", function(t)
	local dir = t:tempdir({
		["plugin.toml"] = 'name = "leaping"\n',
		["init.luau"] = "",
		["docs/README.md"] = "# Leaping\n\nJumps to labels.\n\n## Labels on every word\n\nPress s.\n",
		["docs/colors.md"] = "Some words first.\n\n# Leaping colors\n\n## The label's color\n",
	})
	greed.plugin.load(dir)
	local ok, err = pcall(function()
		local titles: { string } = {}
		for _, page in docs.pages() do
			if string.find(page.path, dir, 1, true) then
				table.insert(titles, page.title)
			end
		end
		local listed = table.concat(titles, ", ")
		assert(listed == "Leaping, Leaping colors", listed)
		assert(docs.pages()[1].title == "Greed", "the manual comes first")

		t:buffer("|")
		t:run("docs", { "labels", "every", "word" })
		local buffer = greed.view():buffer()
		assert(buffer:path() == `{dir}/docs/README.md`, tostring(buffer:path()))
		assert(buffer:readonly(), "read-only like the manual")

		t:keys("esc space h /")
		t:keys("l a b e l ' s space c o l o r")
		t:wait(300)
		t:wait_for(function()
			return string.find(table.concat(t:floats(), "\n"), "leaping/colors: ", 1, true) ~= nil
		end)
		t:keys("enter")
		assert(greed.view():buffer():path() == `{dir}/docs/colors.md`, "found in its pages")
	end)
	greed.plugin.unload("leaping")
	assert(ok, tostring(err))
	for _, page in docs.pages() do
		assert(not string.find(page.path, dir, 1, true), "gone with the plugin")
	end
end)
