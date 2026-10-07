local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")
local models = require("@models")

-- Puts the cursor on the control of the page's line holding `text`.
local function on(text: string)
	local page = greed.view():buffer()
	for line = 0, page:line_count() - 1 do
		local words = page:line_text(line)
		local at = string.find(words, text, 1, true)
		if at then
			greed.view():set_cursor(page:line_start(line) + at - 1)
			return
		end
	end
	error(`no line with {text}`)
end

-- Presses the control holding `text` with enter, as from the keyboard.
local function press(t: test.TestContext, text: string)
	on(text)
	t:keys("enter")
end

local function config_file(): string
	return `{greed.fs.dirs().config}/init.luau`
end

local function seen(): boolean
	return greed.fs.stat(`{greed.fs.dirs().data}/setup-seen`) ~= nil
end

local function page_open(): boolean
	for _, buffer in greed.buffers() do
		if buffer:kind() == "setup" then
			return true
		end
	end
	return false
end

-- The page's line holding `text`.
local function line_with(text: string): string
	local page = greed.view():buffer()
	for line = 0, page:line_count() - 1 do
		local words = page:line_text(line)
		if string.find(words, text, 1, true) then
			return words
		end
	end
	error(`no line with {text}`)
end

test(":setup asks its questions, with what's in use picked", function(t)
	t:buffer("|")
	t:run("setup")
	local text = greed.view():buffer():text()
	assert(string.find(text, "Welcome to Greed", 1, true), text)
	assert(string.find(text, "◉ Select text", 1, true), text)
	assert(string.find(text, "Theme: ", 1, true), text)
	assert(string.find(text, "Which language model should Greed use?", 1, true), text)
	assert(string.find(text, "◉ Anthropic", 1, true), "the model in use: " .. text)
end)

test("picking an editing style switches to it at once", function(t)
	t:buffer("|")
	t:run("setup")
	press(t, "Say what")
	assert(greed.option.get("editing-style") == "vim", tostring(greed.option.get("editing-style")))
	assert(string.find(line_with("Say what"), "◉", 1, true), "picked on the page")
	greed.option.set("editing-style", "helix")
end)

test("the page is read-only and takes its own keys in every style", function(t)
	for _, style in { "helix", "vim", "vscode" } do
		greed.option.set("editing-style", style)
		t:buffer("|")
		t:run("setup")
		local page = greed.view():buffer()
		local before = page:text()
		-- Keys that would edit text are refused, whatever they say.
		for _, keys in { "x d", "a b c", "i z esc", "p" } do
			pcall(t.keys, t, keys)
		end
		assert(page:text() == before, `{style} changed the page`)
		assert(greed.view():buffer() == page, `{style} left the page`)
		-- tab goes from control to control; space and enter press.
		on("No, or they're boxes")
		t:keys("shift-tab space")
		assert(
			string.find(line_with("Yes, they show"), "◉", 1, true),
			`{style}: shift-tab, space`
		)
		t:keys("tab enter")
		assert(
			string.find(line_with("No, or they're boxes"), "◉", 1, true),
			`{style}: tab, enter`
		)
		t:keys("esc")
		assert(not page_open(), `esc closed it in {style}`)
	end
	greed.option.set("editing-style", "helix")
end)

test("Save writes a config from the answers and opens it", function(t)
	t:buffer("|")
	t:run("setup")
	press(t, "No modes")
	press(t, "No, or they're boxes")
	press(t, "[ Save ]")
	local written = greed.fs.read(config_file()) or ""
	assert(string.find(written, 'option.set("editing-style", "vscode")', 1, true), written)
	assert(string.find(written, 'option.set("tree-icons", "none")', 1, true), written)
	assert(greed.view():buffer():path() == config_file(), "the config is open")
	assert(seen(), "marked as answered")
	assert(not page_open(), "closed")
	greed.option.set("editing-style", "helix")
end)

test("Save leaves a config that's there alone and shows what to add, to close with esc", function(t)
	t:buffer("|")
	greed.fs.write(config_file(), "-- mine\n")
	t:run("setup")
	press(t, "[ Save ]")
	assert(greed.fs.read(config_file()) == "-- mine\n", "untouched")
	local shown = greed.view():buffer()
	assert(string.find(shown:text(), "editing-style", 1, true), "focused: " .. shown:text())
	t:keys("esc")
	assert(greed.view():buffer() ~= shown, "esc closed it")
end)

test("Not now closes the page and marks it answered", function(t)
	t:buffer("|")
	t:run("setup")
	press(t, "[ Not now ]")
	assert(not page_open(), "closed")
	assert(seen(), "marked as answered")
	assert(greed.fs.stat(config_file()) == nil, "no config written")
end)

test("closing the page any way counts as Not now, and its picks don't hold up :q", function(t)
	for _, close in { "esc", "q", ":q" } do
		greed.fs.remove(`{greed.fs.dirs().data}/setup-seen`)
		t:buffer("|")
		t:run("setup")
		local page = greed.view():buffer()
		press(t, "Yes, they show")
		assert(not core.file.unsaved(page), "nothing to save on the page")
		if close == ":q" then
			t:run("quit")
		else
			t:keys(close)
		end
		assert(not page_open(), close .. " closed it")
		assert(seen(), close .. " counts as answered")
	end
end)

test(":setup goes to the page that's open rather than opening another", function(t)
	t:buffer("|")
	t:run("setup")
	local page = greed.view():buffer()
	t:buffer("|other")
	t:run("setup")
	assert(greed.view():buffer() == page, "the same page, focused")
	local count = 0
	for _, buffer in greed.buffers() do
		if buffer:kind() == "setup" then
			count += 1
		end
	end
	assert(count == 1, `{count} pages`)
end)

test("choices follow the options as they change", function(t)
	t:buffer("|")
	t:run("setup")
	greed.option.set("editing-style", "vim")
	t:wait(10)
	assert(string.find(line_with("Say what"), "◉", 1, true), "the style set elsewhere")
	greed.option.set("tree-icons", "nerd")
	t:wait(10)
	assert(string.find(line_with("Yes, they show"), "◉", 1, true), "icons set elsewhere")
	greed.option.set("editing-style", "helix")
end)

test("clicks press the button drawn where they land", function(t)
	t:buffer("|")
	t:run("setup")
	local function click(text: string)
		for row, line in t:screen(100, 50) do
			local at = string.find(line, text, 1, true)
			if at then
				local col = utf8.len(string.sub(line, 1, at - 1)) :: number
				t:mouse("press", col + 1, row - 1)
				t:mouse("release", col + 1, row - 1)
				return
			end
		end
		error(`{text} isn't on the screen`)
	end
	click("Yes, they show")
	assert(string.find(line_with("Yes, they show"), "◉", 1, true), "a click picks a choice")
	click("Not now")
	assert(not page_open(), "Not now closed it")
	assert(seen() and greed.fs.stat(config_file()) == nil, "as Not now, without saving")
	local errors = greed.errors()
	assert(#errors == 0, if errors[1] then errors[1].message else "")
end)

test("the model step says what's missing and helps set it up", function(t)
	models.providers.openai =
		{ kind = "openai", url = "https://api.openai.com/v1", secret = "greed-test-nokey" }
	t:buffer("|")
	t:run("setup")
	press(t, "OpenAI")
	assert(
		string.find(line_with("No API key for openai"), "GREED_SECRET_GREED_TEST_NOKEY", 1, true)
			~= nil
	)
	press(t, "[ Set API key… ]")
	t:keys("k e y enter")
	t:wait(100)
	assert(string.find(line_with("openai: key found"), "key found", 1, true) ~= nil)
	models.providers.ollama = { kind = "openai", url = "http://127.0.0.1:9/v1" }
	press(t, "Ollama")
	assert(string.find(line_with("isn't answering"), "`ollama serve`", 1, true) ~= nil)
	assert(string.find(line_with("isn't answering"), "`ollama pull", 1, true) ~= nil)
	press(t, "OpenAI")
	press(t, "[ Save ]")
	local fast = models.roles.fast :: models.Role
	assert(fast.provider == "openai" and fast.model == "gpt-5-mini", fast.provider)
end)

test("a terminal is asked whether icons show, with samples and what boxes mean", function(t)
	t:buffer("|")
	t:run("setup")
	local text = greed.view():buffer():text()
	assert(string.find(text, "Do you see icons here", 1, true), text)
	assert(string.find(text, "No, or they're boxes", 1, true), text)
	assert(string.find(text, "needs Nerd Font icons", 1, true), text)
end)

test("a window isn't asked about icons: it has them, and they're on", function(t)
	t:buffer("|")
	local window = t:client("window", "gui")
	window:run("setup")
	-- The page is the window's own.
	local text = table.concat(window:screen(120, 50), "\n")
	assert(string.find(text, "the window has them built in", 1, true), text)
	assert(not string.find(text, "Do you see icons", 1, true), text)
	window:run("setup-save")
	local written = greed.fs.read(assert(greed.fs.dirs().config) .. "/init.luau") or ""
	assert(string.find(written, 'option.set("tree-icons", "nerd")', 1, true), written)
end)
