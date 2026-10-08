local test = require("@greed/test")
local greed = require("@greed")

-- The highlighted item in the open picker.
local function current(): string?
	local buffer = greed.view():buffer()
	for _, mark in buffer:decorations("picker") do
		if mark.line then
			return string.match(buffer:slice(mark.from, mark.to), "^ ([%w%-]+)")
		end
	end
	return nil
end

-- The text of every character marked as matching the query.
local function matched(): string
	local buffer = greed.view():buffer()
	local out = {}
	for _, mark in buffer:decorations("picker") do
		if mark.style == "ui.menu.match" then
			table.insert(out, buffer:slice(mark.from, mark.to))
		end
	end
	return table.concat(out)
end

test("the command palette runs the command you pick", function(t)
	t:buffer("|abc")
	t:keys("space ?")
	t:expect_mode("helix-insert")
	assert(current() ~= nil, "the picker lists commands")

	t:keys("g o t o - e n d")
	assert(current() == "goto-end", "best match is goto-end, got " .. tostring(current()))

	t:keys("enter")
	t:expect_mode("helix")
	t:expect("abc|")
end)

test("the characters the query matched are marked", function(t)
	t:buffer("|abc")
	t:keys("space ? g o t o - e n d")
	assert(string.find(matched(), "goto-end", 1, true), matched())
end)

test("up and down move through the matches", function(t)
	t:buffer("|abc")
	t:keys("space ?")
	local first = current()
	t:keys("down")
	local second = current()
	assert(second ~= first, "down moves to another item")
	t:keys("up")
	assert(current() == first, "up moves back")
end)

test("esc closes the picker without choosing", function(t)
	t:buffer("a|bc")
	t:keys("space ?")
	t:keys("esc")
	t:expect_mode("helix")
	t:expect("a|bc")
end)

test("a preview shows the current item beside the list", function(t)
	local picker = require("@picker")
	t:buffer("|abc")
	local items = { { label = "one", value = "first" }, { label = "two", value = "second" } }
	picker.pick("Things", items, function() end, {
		preview = function(item)
			return { text = item.value .. " body" }
		end,
	})
	-- Bottom first: the preview, then the list on top of it.
	local floats = t:floats()
	assert(#floats == 2 and floats[1] == "first body", tostring(floats[1]))
	t:keys("down")
	assert(t:floats()[1] == "second body", t:floats()[1])
	t:keys("t w o")
	assert(t:floats()[1] == "second body", "the match stays previewed")
	t:keys("esc")
	assert(#t:floats() == 0, "both close")
end)

test("a source follows the query once typing pauses, keeping only the latest answer", function(t)
	local picker = require("@picker")
	local asked = {}
	greed.command({
		name = "pick-live",
		run = function()
			picker.pick("Live", {}, function() end, {
				source = function(query)
					table.insert(asked, query)
					greed.sleep(50)
					return { { label = query .. "!", value = query } }
				end,
			})
		end,
	})
	t:buffer("|x")
	t:run("pick-live")
	t:keys("a b")
	t:wait(100)
	assert(table.concat(asked, ",") == "ab", "asked once typing paused")
	t:wait(50)
	assert(string.find(greed.view():buffer():text(), " ab!", 1, true), greed.view():buffer():text())
	t:keys("c")
	t:wait(100)
	-- Typing while the source works for "abc": its answer is dropped and it's
	-- asked again for "abcd".
	t:keys("d")
	t:wait(60)
	assert(
		not string.find(greed.view():buffer():text(), "abc!", 1, true),
		"the stale answer isn't shown"
	)
	t:wait(100)
	assert(table.concat(asked, ",") == "ab,abc,abcd", table.concat(asked, ","))
	assert(
		string.find(greed.view():buffer():text(), " abcd!", 1, true),
		greed.view():buffer():text()
	)
end)

test("a picker's own keys don't take over the same keys in later pickers", function(t)
	local picker = require("@picker")
	local items = { { label = "one", value = 1 }, { label = "two", value = 2 } }
	local got = nil
	t:buffer("|abc")
	picker.pick("First", items, function() end, {
		keys = {
			["ctrl-n"] = function(list)
				got = #list
			end,
		},
	})
	t:keys("ctrl-n")
	assert(got == 2, "the picker's key gets the matches")
	picker.pick("Second", items, function(item)
		got = item.value
	end)
	t:keys("ctrl-n enter")
	assert(got == 2, "ctrl-n moves down again in a picker without its own")
end)

-- The items in the open picker, without the query line.
local function items(): { string }
	local lines = string.split(greed.view():buffer():text(), "\n")
	local out = {}
	for i = 2, #lines do
		if lines[i] ~= "" then
			table.insert(out, string.sub(lines[i], 2))
		end
	end
	return out
end

test("space f lists the project's files, leaving ignored ones out, and opens one", function(t)
	local dir = t:tempdir({
		[".git/HEAD"] = "",
		[".gitignore"] = "skip.txt\n",
		["a.txt"] = "alpha",
		["src/b.txt"] = "beta",
		["bin.dat"] = "\0\1\2",
		["skip.txt"] = "",
	})
	greed.run("project", { args = { dir } })
	t:buffer("|x")
	t:keys("space f")
	local listed = items()
	table.sort(listed)
	assert(table.concat(listed, " ") == "a.txt bin.dat src/b.txt", table.concat(listed, " "))
	t:keys("b i n")
	assert(table.find(t:floats(), "(binary file)"), "binary files aren't shown")
	t:keys("esc")
	t:keys("space f s r c")
	assert(table.find(t:floats(), "beta"), "the preview shows the file")
	t:keys("enter")
	assert(greed.view():buffer():path() == dir .. "/src/b.txt", greed.view():buffer():path())
	assert(greed.view():buffer():text() == "beta")
end)

test("space b lists the open files and previews them as they are now", function(t)
	local dir = t:tempdir({ ["one.txt"] = "first", ["two.txt"] = "second" })
	greed.open(dir .. "/one.txt")
	t:keys("i n e w space esc")
	greed.open(dir .. "/two.txt")
	t:keys("space b o n e")
	assert(table.find(t:floats(), "new first"), "unsaved text in the preview")
	t:keys("enter")
	assert(greed.view():buffer():path() == dir .. "/one.txt")
end)

test(
	"moving past either end wraps round, and the picker returns to the mode it came from",
	function(t)
		local picker = require("@picker")
		local got = nil
		local list = {
			{ label = "aa", value = 1 },
			{ label = "bb", value = 2 },
			{ label = "cc", value = 3 },
		}
		t:buffer("|x")
		greed.mode.set("vscode")
		picker.pick("Wrap", list, function(item)
			got = item.value
		end)
		t:keys("up enter")
		assert(got == 3, "up from the first is the last")
		t:expect_mode("vscode")
		picker.pick("Wrap", list, function(item)
			got = item.value
		end)
		t:keys("down down down enter")
		assert(got == 1, "down from the last is the first")
	end
)

test("a source that fails shows nothing instead of breaking the picker", function(t)
	local picker = require("@picker")
	greed.command({
		name = "pick-broken",
		run = function()
			picker.pick("Broken", {}, function() end, {
				delay = 1,
				source = function(): { any }
					error("no")
				end,
			})
		end,
	})
	t:buffer("|x")
	t:run("pick-broken")
	t:keys("a")
	t:wait(20)
	assert(#items() == 0, "nothing listed")
	t:keys("esc")
	t:expect_mode("helix")
end)

test("the command palette shows each command's keys", function(t)
	t:buffer("|abc")
	t:keys("space ? g o t o - l a s t")
	assert(
		string.find(greed.view():buffer():text(), "goto-last-line  (g e)", 1, true),
		greed.view():buffer():text()
	)
	t:keys("esc")
end)

test("the outline lists functions and types, nested, and jumps to one", function(t)
	require("@greed").syntax.set_query(
		"rust",
		"textobjects",
		"(function_item) @function.around (impl_item body: (_) @type.inside) @type.around (struct_item) @type.around"
	)
	t:buffer("|struct S;\nfn one() {}\nfn two() {}\n")
	greed.view():buffer():set_language("rust")
	t:keys("space s")
	local list = greed.view():buffer():text()
	assert(string.find(list, "S  struct_item:1", 1, true), list)
	assert(string.find(list, "two  function_item:3", 1, true), list)
	t:keys("t w o enter")
	t:expect("struct S;\nfn one() {}\nfn |two() {}\n")
end)

test("enter over several buttons picks which to press", function(t)
	local ran: { string } = {}
	for _, name in { "accept", "reject" } do
		greed.command({
			name = `test-{name}`,
			run = function()
				table.insert(ran, name)
			end,
		})
	end
	t:buffer("|change")
	greed.view():buffer():decorate("buttons", {
		{
			from = 0,
			to = 0,
			style = "ui.button",
			text = "accept",
			eol = true,
			action = "test-accept",
		},
		{
			from = 0,
			to = 0,
			style = "ui.button",
			text = "reject",
			eol = true,
			action = "test-reject",
		},
	})
	t:keys("enter")
	local listed = items()
	assert(
		#listed == 2 and listed[1] == "accept" and listed[2] == "reject",
		table.concat(listed, ",")
	)
	t:keys("r e j enter")
	assert(ran[1] == "reject" and #ran == 1, table.concat(ran, ","))
end)

test("a picker that takes paths lists the folders in a typed one, and tab goes on", function(t)
	local dir =
		t:tempdir({ ["alpha/x"] = "", ["beta/y"] = "", ["file.txt"] = "", [".hidden/z"] = "" })
	local picker = require("@picker")
	local chosen: string? = nil
	t:buffer("|x")
	picker.pick("Places", { { label = "not a path", value = 1 } }, function() end, {
		paths = {
			dirs = true,
			choose = function(path)
				chosen = path
			end,
		},
	})
	for _, key in string.split(dir .. "/", "") do
		t:keys(if key == " " then "space" else key)
	end
	local listed = items()
	assert(
		#listed == 2 and listed[1] == dir .. "/alpha/" and listed[2] == dir .. "/beta/",
		table.concat(listed, ",")
	)
	t:keys("b tab")
	assert(
		string.split(greed.view():buffer():text(), "\n")[1] == dir .. "/beta/",
		"tab put it in the query"
	)
	t:keys("backspace backspace backspace backspace backspace a enter")
	assert(chosen == dir .. "/alpha", tostring(chosen))
end)

-- Runs `f` as a command, so it can wait, and returns what it gave back
-- once it has.
local function waiting(t: test.TestContext, f: () -> any): () -> (boolean, any)
	local done, result = false, nil
	greed.command({
		name = "test-waiting",
		run = function()
			result = f()
			done = true
		end,
	})
	t:run("test-waiting")
	return function()
		return done, result
	end
end

test("choose waits for the item, and gives nil when the picker ends without one", function(t)
	local picker = require("@picker")
	t:buffer("|x")
	local items = { { label = "one", value = 1 }, { label = "two", value = 2 } }
	local answer = waiting(t, function()
		return picker.choose("Numbers", items)
	end)
	assert(not (answer()), "still waiting")
	t:keys("t w enter")
	local done, item = answer()
	assert(done and item and item.value == 2, "the chosen item")

	answer = waiting(t, function()
		return picker.choose("Numbers", items)
	end)
	t:keys("esc")
	done, item = answer()
	assert(done and item == nil, "esc gives nil")

	answer = waiting(t, function()
		return picker.choose("Numbers", items)
	end)
	picker.pick("Another", items, function() end)
	done, item = answer()
	assert(done and item == nil, "another picker taking its place gives nil")
	t:keys("esc")
end)

test("space ' opens the last picker again", function(t)
	t:buffer("|abc")
	t:keys("space ? esc")
	t:expect_mode("helix")
	t:keys("space '")
	t:expect_mode("helix-insert")
	assert(current() ~= nil, "the palette is back")
	t:keys("esc")
end)

test("space . lists the actions for what's under the cursor, and runs the one chosen", function(t)
	local dir = t:tempdir({ ["notes.txt"] = "the notes" })
	t:buffer(`see {dir}/no|tes.txt`)
	t:keys("space .")
	local shown = t:floats()[1]
	assert(shown and string.find(shown, "copy-path", 1, true), shown)
	t:keys("o p e n enter")
	assert(greed.view():buffer():text() == "the notes", "opened it")
end)

test("alt-. in a picker lists the actions for the current item", function(t)
	t:buffer("|x")
	t:keys("space ?")
	t:keys("g o t o - e n d")
	t:keys("alt-.")
	local shown = t:floats()[1]
	assert(shown and string.find(shown, "run  Run it", 1, true), shown)
	if greed.plugin.dirs().describe then
		assert(string.find(shown, "describe", 1, true), "the describe plugin adds one: " .. shown)
	end
	t:keys("r u n enter")
	t:expect("x|")
end)

test("a picker whose view closes some other way is cancelled, its preview too", function(t)
	local picker = require("@picker")
	t:buffer("|abc")
	greed.mode.set("helix-select")
	local cancelled, chosen = 0, 0
	local items = { { label = "one", value = "first" } }
	local function open()
		picker.pick("Things", items, function()
			chosen += 1
		end, {
			preview = function(item)
				return { text = item.value }
			end,
			on_cancel = function()
				cancelled += 1
			end,
		})
	end
	open()
	t:expect_mode("helix-insert")
	greed.view():close()
	t:wait(0)
	t:expect_mode("helix-select")
	assert(cancelled == 1 and #t:floats() == 0, `cancelled {cancelled}, {#t:floats()} floats`)
	t:run("picker-choose")
	assert(chosen == 0 and cancelled == 1, "nothing left open")
	-- Choosing isn't cancelling; another picker opening is.
	open()
	t:keys("enter")
	assert(chosen == 1 and cancelled == 1)
	open()
	open()
	assert(cancelled == 2)
	t:keys("esc")
	assert(cancelled == 3)
	t:expect_mode("helix-select")
end)

test("esc closes a picker in a style no plugin names", function(t)
	local core = require("@core")
	t:buffer("a|bc")
	core.style.define({ name = "mine", doc = "Mine", mode = "mine" })
	core.style.set("mine")
	t:run("command-palette")
	greed.mode.set("mine")
	assert(greed.keymap.resolve("esc") == "picker-close")
end)

test("a client's picker is its own: others don't see it and their keys don't reach it", function(t)
	t:buffer("|abc")
	local second = t:client()
	local picked: { [number]: string } = {}
	greed.command({
		name = "test-pick",
		run = function(ctx)
			local client = ctx.client
			require("@picker").pick("Fruit", {
				{ label = "apple", value = "apple" },
				{ label = "banana", value = "banana" },
			}, function(item)
				picked[client] = item.value
			end)
		end,
	})
	second:run("test-pick")
	local function has(rows: { string }, text: string): boolean
		return string.find(table.concat(rows, "\n"), text, 1, true) ~= nil
	end
	assert(has(second:screen(40, 12), "Fruit"), "the second sees its picker")
	assert(not has(t:screen(40, 12), "Fruit"), "the first doesn't")
	-- The first types in its own buffer, not in the second's picker.
	t:keys("i z esc")
	t:expect("z|abc")
	second:expect_mode("helix-insert")
	-- The first opens one of its own, and both stay open.
	t:run("test-pick")
	second:keys("b a n enter")
	assert(picked[second:id()] == "banana", `the second picked {picked[second:id()]}`)
	assert(picked[1] == nil, "the first hasn't")
	assert(has(t:screen(40, 12), "Fruit"), "the first's is still open")
	t:keys("enter")
	assert(picked[1] == "apple", `the first picked {picked[1]}`)
end)
