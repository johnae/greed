-- Words from open files and paths, offered as you type alongside what the
-- language server has.

local test = require("@greed/test")
local greed = require("@greed")

local function menu(t: test.TestContext): string
	return table.concat(t:floats(), "\n")
end

test("words from open files are offered as you type", function(t)
	t:buffer("apple apricot banana\n|")
	t:keys("i a p")
	t:run("completion-ask")
	local shown = menu(t)
	assert(string.find(shown, "apple", 1, true), shown)
	assert(string.find(shown, "apricot", 1, true), shown)
	assert(not string.find(shown, "banana", 1, true), shown)
	t:keys("enter")
	t:expect("apple apricot banana\napple|")
end)

test("a word is only offered once two letters are typed, unless asked for", function(t)
	t:buffer("apple\n|")
	t:keys("i a")
	t:wait(greed.option.get("completion-delay") :: number + 100)
	assert(#t:floats() == 0, "one letter isn't enough")
	t:keys("p")
	t:wait(greed.option.get("completion-delay") :: number + 100)
	assert(#t:floats() == 1, "two are")
end)

test("what an adding source offers comes after the server's, however well it matches", function()
	local lsp = require("@lsp")
	-- The server's two, then the added one.
	local items: { any } = {
		{ label = "xapx", text = "xapx" },
		{ label = "apple", text = "apple" },
		{ label = "ap", text = "ap" },
	}
	local order = lsp.completion.matching(items, "ap", 2)
	assert(table.concat(order, ",") == "2,1,3", table.concat(order, ","))
	order = lsp.completion.matching(items, "ap")
	assert(order[3] ~= 3, "without first, how well they match decides")
end)

test("an adding source's items join the menu, after the rest", function(t)
	local lsp = require("@lsp")
	lsp.completion.source(function(view)
		if view:buffer():path() ~= nil then
			return nil
		end
		return { { label = "apex_added", text = "apex_added" } }
	end, { adds = true })
	t:buffer("apple\n|")
	t:keys("i a p")
	t:run("completion-ask")
	local shown = menu(t)
	assert(string.find(shown, "apex_added", 1, true), shown)
	assert(string.find(shown, "apple", 1, true), shown)
end)

test("a full path completes from its folder", function(t)
	local dir = t:tempdir({ ["src/main.rs"] = "" })
	t:buffer(`{dir}/s|`)
	t:keys("a")
	t:run("completion-ask")
	t:keys("enter")
	t:expect(`{dir}/src/|`)
end)

test("paths complete from the file's folder", function(t)
	local dir = t:tempdir({ ["src/main.rs"] = "", ["src/lib.rs"] = "", ["notes.md"] = "" })
	greed.open(dir .. "/notes.md")
	t:keys("i . / s")
	t:run("completion-ask")
	local shown = menu(t)
	assert(string.find(shown, "src/", 1, true), shown)
	t:keys("enter")
	t:run("completion-ask")
	shown = menu(t)
	assert(string.find(shown, "main.rs", 1, true) and string.find(shown, "lib.rs", 1, true), shown)
	t:keys("enter")
	local text = greed.view():buffer():text()
	assert(text == "./src/lib.rs" or text == "./src/main.rs", text)
end)

test("typing / after a path's folder opens its entries by itself", function(t)
	local dir = t:tempdir({ ["src/main.rs"] = "", ["notes.md"] = "" })
	greed.open(dir .. "/notes.md")
	t:keys("i . / s r c /")
	t:wait(greed.option.get("completion-delay") :: number + 100)
	local shown = menu(t)
	assert(string.find(shown, "main.rs", 1, true), shown)
end)

test("a // comment isn't a path", function(t)
	t:buffer("|")
	t:keys("i / /")
	t:run("completion-ask")
	assert(#t:floats() == 0, menu(t))
end)
