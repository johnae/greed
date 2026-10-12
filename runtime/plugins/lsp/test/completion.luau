local test = require("@greed/test")
local greed = require("@greed")

-- What a command line or prompt does: a float typed into, closed by enter
-- before the typing pause runs out.
test("a float typed into and closed before the pause doesn't break completion", function(t)
	t:buffer("|x")
	local dir = t:tempdir({ ["a.txt"] = "" })
	local list = greed.create_buffer("scratch", "")
	list:save(dir .. "/a.txt")
	local float = greed.float(list, { width = 20, height = 1 })
	t:keys("i a b")
	float:close()
	t:wait(greed.option.get("completion-delay") :: number + 100)
	for _, message in t:messages() do
		assert(not string.find(message, "closed", 1, true), message)
	end
end)

test("a completion menu whose view closes some other way goes back to typing", function(t)
	t:buffer("apple apricot\n|")
	t:keys("i a")
	t:run("completion-words")
	t:expect_mode("completion-helix-insert")
	local menu = t:floats()
	assert(#menu == 1, `{#menu} floats`)
	for _, view in greed.floats() do
		if view:buffer():kind() == "completion" then
			view:close()
		end
	end
	t:wait(0)
	t:expect_mode("helix-insert")
	t:keys("p")
	t:expect("apple apricot\nap|")
end)

test("a style no plugin names gets completion in its typing mode", function(t)
	local core = require("@core")
	t:buffer("apple\n|")
	greed.keymap.inherit("mine-insert", "helix-insert")
	core.style.define({ name = "mine", doc = "Mine", mode = "mine", typing = { "mine-insert" } })
	greed.mode.set("mine-insert")
	t:keys("a")
	t:run("completion-words")
	t:expect_mode("completion-mine-insert")
	assert(core.style.is_typing(), "the menu's mode types too")
	assert(core.style.label("completion-mine-insert") == "mine-insert")
	-- Typing goes on in the menu's mode, and enter takes the match.
	t:keys("p enter")
	t:expect("apple\napple|")
	t:expect_mode("mine-insert")
end)

test("a source offers completions in a buffer with no file, ahead of the server", function(t)
	local lsp = require("@lsp")
	t:buffer("|")
	local asked = 0
	lsp.completion.source(function(view)
		if view:buffer():kind() ~= "file" then
			return nil
		end
		asked += 1
		return { { label = "greeting", text = "greeting", detail = "from a source" } }
	end)
	t:keys("i g r")
	t:run("completion-ask")
	assert(asked == 1, tostring(asked))
	local menu = table.concat(t:floats(), "\n")
	assert(string.find(menu, "from a source", 1, true), menu)
	t:keys("enter")
	t:expect("greeting|")
end)

-- A source offering `labels` in buffers with no file, with `options`.
local function offer(labels: { string }, options: any?)
	local lsp = require("@lsp")
	lsp.completion.source(function(view)
		if view:buffer():path() ~= nil then
			return nil
		end
		local items = {}
		for _, label in labels do
			table.insert(items, { label = label, text = label })
		end
		return items
	end, options)
end

test("a menu opens by itself only once typing pauses for completion-delay", function(t)
	offer({ "greeting", "green" })
	t:buffer("|")
	t:keys("i g")
	-- The delay starts with the last key, after this; time typing takes on
	-- a busy machine counts toward it.
	local before = greed.now()
	t:keys("r")
	assert(#t:floats() == 0, "not while typing")
	local left = before + (greed.option.get("completion-delay") :: number) - 50 - greed.now()
	if left > 0 then
		t:wait(left)
		assert(#t:floats() == 0, "not before the delay")
	end
	t:wait(100)
	assert(#t:floats() == 1, "after it")
	t:keys("esc")
	-- Asking shows it at once.
	t:keys("i")
	t:run("completion-ask")
	assert(#t:floats() == 1, "asked for")
	t:keys("esc")
	-- With a longer delay, it waits that long.
	greed.option.set("completion-delay", 1000)
	t:keys("A e")
	t:wait(500)
	assert(#t:floats() == 0, "not yet")
	t:wait(600)
	assert(#t:floats() == 1, "after the longer delay")
	greed.option.set("completion-delay", 150)
end)

test("enter in a menu takes the first item, or with selected only one moved to", function(t)
	offer({ "greeting", "green" }, { enter = "selected" })
	t:buffer("|")
	t:keys("i g r")
	t:run("completion-ask")
	t:keys("enter")
	t:expect("gr\n|")
	t:keys("g r")
	t:run("completion-ask")
	t:keys("tab enter")
	t:expect("gr\ngreeting|")
	-- completion-enter decides over what the source says.
	greed.option.set("completion-enter", "first")
	t:keys("enter g r")
	t:run("completion-ask")
	t:keys("enter")
	t:expect("gr\ngreeting\ngreeting|")
	greed.option.set("completion-enter", "auto")
end)

test("completion-enter selected applies to every menu", function(t)
	offer({ "greeting", "green" })
	greed.option.set("completion-enter", "selected")
	t:buffer("|")
	t:keys("i g r")
	t:run("completion-ask")
	t:keys("enter")
	t:expect("gr\n|")
	t:keys("g r")
	t:run("completion-ask")
	t:keys("down enter")
	t:expect("gr\ngreeting|")
	greed.option.set("completion-enter", "auto")
end)

test("matches starting with what's typed come first, then those holding it", function()
	local lsp = require("@lsp")
	local labels = { "hcisecfilter", "zhistory", "history" }
	local order = lsp.completion.rank("hist", labels)
	local ranked = {}
	for _, index in order do
		table.insert(ranked, labels[index])
	end
	assert(table.concat(ranked, " ") == "history zhistory hcisecfilter", table.concat(ranked, " "))
end)

test("a completion you pick from a menu that opened by itself is your own edit", function(t)
	offer({ "greeting", "green" })
	t:buffer("|")
	t:keys("i g r")
	t:wait(greed.option.get("completion-delay") :: number + 100)
	assert(#t:floats() == 1, "the menu opened by itself")
	t:keys("down enter")
	t:expect("green|")
	local last = greed.view():buffer():history({ limit = 1 })[1]
	assert(last.author == "user", `{last.author} {last.plugin}`)
end)
