local test = require("@greed/test")
local greed = require("@greed")
local models = require("@models")
local markdown = require("@markdown")

local function config_file(): string
	return `{greed.fs.dirs().config}/init.luau`
end

local function seen(): boolean
	return greed.fs.stat(`{greed.fs.dirs().data}/setup-seen`) ~= nil
end

local function page(): greed.Buffer?
	for _, buffer in greed.buffers() do
		if buffer:kind() == "setup" then
			return buffer
		end
	end
	return nil
end

-- Opens the page, its choices made.
local function open(t: test.TestContext)
	t:buffer("|")
	t:run("setup")
	t:wait_for(function()
		local p = page()
		return p ~= nil and string.find(p:text(), "- (x) helix", 1, true) ~= nil
	end)
end

-- The page's line holding `text` (0-based), or nil.
local function line_with(text: string): number?
	local p = page() :: greed.Buffer
	for line = 0, p:line_count() - 1 do
		if string.find(p:line_text(line), text, 1, true) then
			return line
		end
	end
	return nil
end

-- Presses the choice whose line holds `text`, or the button labelled
-- `label`, with enter, as from the keyboard, and lets what it runs finish.
local function press(t: test.TestContext, text: string)
	local p = page() :: greed.Buffer
	local button = line_with(`button="{text}"`)
	local line = button or assert(line_with(text), `no line with {text}`)
	local at = if button then 0 else (string.find(p:line_text(line), "(", 1, true) :: number) - 1
	greed.view():set_cursor(p:line_start(line) + at)
	t:keys("enter")
	t:wait(30)
end

local function answers(): { [string]: string }
	return markdown.questions.answers(page() :: greed.Buffer)
end

test(":setup asks its questions, with what's in use picked", function(t)
	open(t)
	local text = (page() :: greed.Buffer):text()
	assert(string.find(text, "Welcome to Greed", 1, true), text)
	assert(string.find(text, "- (x) default", 1, true), "the theme in use: " .. text)
	local a = answers()
	assert(
		a.style == "helix" and a.theme == "default" and a.provider == "anthropic",
		greed.json.encode(a)
	)
	assert(a.claude == "no", a.claude)
end)

test("picking an editing style or a theme switches to it at once", function(t)
	open(t)
	press(t, "vim: ")
	t:wait_for(function()
		return greed.option.get("editing-style") == "vim"
	end)
	press(t, "nord-light")
	t:wait_for(function()
		return require("@theme").current() == "nord-light"
	end)
	local kept = greed.fs.read(`{greed.fs.dirs().cache}/theme`) or ""
	assert(string.find(kept, "nord-light", 1, true), "remembered: " .. kept)
	greed.option.set("editing-style", "helix")
	greed.run("theme", { args = { "default" }, wait = true })
end)

test("tab goes from choice to choice and button to button, round the page", function(t)
	open(t)
	local p = page() :: greed.Buffer
	local view = greed.view()
	local first = view:cursor()
	assert(
		string.find(p:line_text(p:line_of(first)), "helix", 1, true),
		"starts on the first choice"
	)
	t:keys("tab")
	assert(string.find(p:line_text(p:line_of(view:cursor())), "vim", 1, true), "the next choice")
	t:keys("shift-tab shift-tab")
	local last = p:line_text(p:line_of(view:cursor()))
	assert(string.find(last, 'button="Not now"', 1, true), "round to the last button: " .. last)
end)

test("the model's button shows only for a model, and helps set it up", function(t)
	models.providers.openai =
		{ kind = "openai", url = "https://api.openai.com/v1", secret = "greed-test-nokey" }
	open(t)
	local hidden = markdown.questions.state(page() :: greed.Buffer)
	assert(not hidden[line_with('button="Set up the model…"') :: number], "shows for anthropic")
	press(t, "none: ")
	hidden = markdown.questions.state(page() :: greed.Buffer)
	assert(hidden[line_with('button="Set up the model…"') :: number], "hidden for none")
	press(t, "openai: ")
	press(t, "Set up the model…")
	t:keys("k e y enter")
	t:wait(100)
	assert(models.key_state("openai") ~= nil, "the key is kept")
	press(t, "Save")
	local fast = models.roles.fast :: models.Role
	assert(fast.provider == "openai" and fast.model == "gpt-5-mini", fast.provider)
end)

test("Save writes a config from the answers and opens it", function(t)
	open(t)
	press(t, "vscode: ")
	press(t, "no: or they're boxes")
	press(t, "Save")
	local written = greed.fs.read(config_file()) or ""
	assert(string.find(written, 'option.set("editing-style", "vscode")', 1, true), written)
	assert(string.find(written, 'option.set("tree-icons", "none")', 1, true), written)
	assert(greed.view():buffer():path() == config_file(), "the config is open")
	assert(seen() and page() == nil, "answered and closed")
	greed.option.set("editing-style", "helix")
end)

test("Save leaves a config that's there alone and shows what to add, to close with esc", function(t)
	greed.fs.write(config_file(), "-- mine\n")
	open(t)
	press(t, "Save")
	assert(greed.fs.read(config_file()) == "-- mine\n", "untouched")
	local shown = greed.view():buffer()
	assert(string.find(shown:text(), "editing-style", 1, true), "focused: " .. shown:text())
	t:keys("esc")
	assert(greed.view():buffer() ~= shown, "esc closed it")
end)

test("Not now, esc or closing the page any way counts as answered, without saving", function(t)
	open(t)
	press(t, "Not now")
	assert(page() == nil and seen(), "closed and answered")
	assert(greed.fs.stat(config_file()) == nil, "nothing saved")
	open(t)
	t:keys("esc")
	assert(page() == nil, "esc closes it")
	open(t)
	greed.view():close()
	assert(page() == nil, "closing it any way")
	local errors = greed.errors()
	assert(#errors == 0, if errors[1] then errors[1].message else "")
end)

test(":setup goes to the page that's open rather than opening another", function(t)
	open(t)
	t:buffer("|other")
	t:run("setup")
	local count = 0
	for _, buffer in greed.buffers() do
		if buffer:kind() == "setup" then
			count += 1
		end
	end
	assert(count == 1 and greed.view():buffer():kind() == "setup", `{count} pages`)
end)

test("a terminal is asked whether icons show, with samples; a window has them on", function(t)
	open(t)
	assert(line_with("they show here") and line_with("or they're boxes"), "asked")
	t:keys("esc")
	local window = t:client("window", "gui")
	window:run("setup")
	t:wait(200)
	local text = (page() :: greed.Buffer):text()
	assert(string.find(text, "(x) yes: the window has them built in", 1, true), text)
	window:run("setup-save")
	local written = greed.fs.read(config_file()) or ""
	assert(string.find(written, 'option.set("tree-icons", "nerd")', 1, true), written)
end)

test("the config's commented-out settings run once uncommented, and name real options", function()
	local config = require("@setup").config({ icons = "no" })
	local lines = {}
	for line in string.gmatch(config, "[^\n]*") do
		local code = string.match(line, "^%-%- (greed%..*)$")
			or string.match(line, "^%-%- (require%(.*)$")
		table.insert(lines, code or line)
	end
	local uncommented = table.concat(lines, "\n")
	assert(loadstring(uncommented), "the uncommented config compiles")
	local names = 0
	for name in string.gmatch(uncommented, 'option%.set%("([%-%w]+)"') do
		greed.option.get(name)
		names += 1
	end
	assert(names > 10, `{names} options`)
end)
