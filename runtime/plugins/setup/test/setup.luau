local test = require("@greed/test")
local greed = require("@greed")
local markdown = require("@markdown")

-- The line of the option starting with `text` on the page.
local function line_of(page: greed.Buffer, text: string): number
	for line = 0, page:line_count() - 1 do
		local words = page:slice(page:line_start(line), page:line_end(line))
		if string.find(words, text, 1, true) then
			return line
		end
	end
	error(`no line with {text}`)
end

local function config_file(): string
	return `{greed.fs.dirs().config}/init.luau`
end

test(":setup asks its questions, with what's in use picked", function(t)
	t:buffer("|")
	t:run("setup")
	local page = greed.view():buffer()
	local text = page:text()
	assert(string.find(text, "# Welcome to Greed", 1, true), text)
	assert(string.find(text, "- (x) Select text", 1, true), text)
	assert(string.find(text, "Theme: ", 1, true), text)
end)

test("picking an editing style switches to it at once", function(t)
	t:buffer("|")
	t:run("setup")
	local page = greed.view():buffer()
	markdown.choices.pick(page, line_of(page, "- ( ) Say what"))
	assert(greed.option.get("editing-style") == "vim", tostring(greed.option.get("editing-style")))
end)

test("Save writes a config from the answers and opens it", function(t)
	t:buffer("|")
	t:run("setup")
	local page = greed.view():buffer()
	markdown.choices.pick(page, line_of(page, "- ( ) No modes"))
	markdown.choices.pick(page, line_of(page, "No, or it's a box"))
	t:run("setup-save")
	local written = greed.fs.read(config_file()) or ""
	assert(string.find(written, 'option.set("editing-style", "vscode")', 1, true), written)
	assert(string.find(written, 'option.set("tree-icons", "none")', 1, true), written)
	assert(greed.view():buffer():path() == config_file(), "the config is open")
	assert(greed.fs.stat(`{greed.fs.dirs().data}/setup-seen`), "marked as answered")
end)

test("Save leaves a config that's there alone and shows what to add", function(t)
	t:buffer("|")
	greed.fs.write(config_file(), "-- mine\n")
	t:run("setup")
	t:run("setup-save")
	assert(greed.fs.read(config_file()) == "-- mine\n", "untouched")
	local shown = greed.view():buffer():text()
	assert(string.find(shown, "editing-style", 1, true), shown)
end)

test("Not now closes the page and marks it answered", function(t)
	t:buffer("|")
	t:run("setup")
	t:run("setup-close")
	assert(not string.find(greed.view():buffer():text(), "Welcome", 1, true), "closed")
	assert(greed.fs.stat(`{greed.fs.dirs().data}/setup-seen`), "marked as answered")
	assert(greed.fs.stat(config_file()) == nil, "no config written")
end)

test("esc and q close the page, and its picks don't hold up :q", function(t)
	for _, key in { "esc", "q" } do
		t:buffer("|")
		t:run("setup")
		local page = greed.view():buffer()
		markdown.choices.pick(page, line_of(page, "No, or it's a box"))
		assert(page:modified(), "picked")
		local core = require("@core")
		assert(not core.file.unsaved(page), "nothing to save on the page")
		t:keys(key)
		assert(
			not string.find(greed.view():buffer():text(), "Welcome", 1, true),
			key .. " closed it"
		)
	end
end)
