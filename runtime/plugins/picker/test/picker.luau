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
		greed.mode.set("helix-select")
		picker.pick("Wrap", list, function(item)
			got = item.value
		end)
		t:keys("up enter")
		assert(got == 3, "up from the first is the last")
		t:expect_mode("helix-select")
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
		string.find(greed.view():buffer():text(), "goto%-last%-line  +%(g e%)  Move"),
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
	assert(string.find(list, "S%s+type%s+1"), list)
	assert(string.find(list, "two%s+function%s+3"), list)
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

test("choose with a fallback gives nil once the fallback has what was typed", function(t)
	local picker = require("@picker")
	t:buffer("|x")
	local typed: string? = nil
	local answer = waiting(t, function()
		return picker.choose("Numbers", { { label = "one", value = 1 } }, {
			fallback = function(query)
				typed = query
			end,
		})
	end)
	t:keys("z z enter")
	local done, item = answer()
	assert(done and item == nil and typed == "zz", tostring(typed))
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

test(
	"the buffer picker names files from the project's root, the last one you were in first",
	function(t)
		local dir = t:tempdir({ [".git/HEAD"] = "", ["src/a.rs"] = "a", ["b.md"] = "b" })
		greed.run("project", { args = { dir } })
		greed.open(dir .. "/src/a.rs")
		t:keys("i x esc")
		greed.open(dir .. "/b.md")
		t:keys("space b")
		local listed = greed.view():buffer():text()
		assert(not string.find(listed, dir, 1, true), listed)
		local b, a =
			string.find(listed, " b.md", 1, true), string.find(listed, " src/a.rs [+]", 1, true)
		assert(b and a and b < a, listed)
		local _, times = string.gsub(listed, "b%.md", "")
		assert(times == 1, "each file once: " .. listed)
		t:keys("esc")
	end
)

test("typing that matches nothing says so", function(t)
	t:buffer("|x")
	local picker = require("@picker")
	picker.pick("Fruit", { { label = "apple", value = 1 } }, function() end)
	t:type("zzz")
	local screen = table.concat(t:screen(80, 20), "\n")
	assert(string.find(screen, "nothing matches", 1, true), screen)
	t:keys("esc")
end)

test("a label too long for the float is cut with an ellipsis, keeping one row", function(t)
	t:buffer("|x")
	local long = "long-item " .. string.rep("word ", 60) .. "TAIL"
	require("@picker").pick("Long", {
		{ label = long, value = 1 },
		{ label = "short", value = 2 },
	}, function() end)
	-- The first drawing gives the float its width; the rows follow it.
	local rows = t:screen(80, 20)
	rows = t:screen(80, 20)
	local row = ""
	for _, line in rows do
		if string.find(line, "long-item", 1, true) then
			row = line
		end
	end
	assert(string.find(row, "…", 1, true), row)
	local screen = table.concat(rows, "\n")
	assert(not string.find(screen, "TAIL", 1, true), "only one row")
	-- Matching still marks what's in sight.
	t:type("long")
	assert(matched() == "long", matched())
	t:keys("esc")
end)

test("the actions say what they're for in the title", function(t)
	local core = require("@core")
	core.actions.action({ kind = "test-thing", name = "test-poke", run = function() end })
	t:buffer("|x")
	local picker = require("@picker")
	picker.act({ { kind = "test-thing", label = "zot", value = 1 } })
	local screen = table.concat(t:screen(80, 20), "\n")
	assert(string.find(screen, "test-thing: zot", 1, true), screen)
	t:keys("esc")
	picker.act({
		{ kind = "test-thing", label = "one", value = 1 },
		{ kind = "test-thing", label = "two", value = 2 },
		{ kind = "test-thing", label = "three", value = 3 },
	})
	screen = table.concat(t:screen(80, 20), "\n")
	assert(string.find(screen, "Act on 3 things", 1, true), screen)
	t:keys("esc")
end)

test("each thing's own actions come before those every kind has", function(t)
	local core = require("@core")
	for _, kind in { "test-first", "test-second" } do
		core.actions.action({ kind = kind, name = `{kind}-only`, run = function() end })
	end
	core.actions.action({ kind = "*", name = "test-everywhere", run = function() end })
	t:buffer("|x")
	require("@picker").act({
		{ kind = "test-first", label = "one", value = 1 },
		{ kind = "test-second", label = "two", value = 2 },
	})
	local shown = assert(t:floats()[1])
	local first = assert((string.find(shown, "test-first-only", 1, true)))
	local second = assert((string.find(shown, "test-second-only", 1, true)))
	local everywhere = assert((string.find(shown, "test-everywhere", 1, true)))
	assert(first < second and second < everywhere, shown)
	t:keys("esc")
end)

test("space space switches to anything open, says what each is and keeps a kind with @", function(t)
	local dir = t:tempdir({ ["notes.txt"] = "the notes" })
	greed.open(dir .. "/notes.txt")
	local scratch = greed.create_buffer("scratch", "one\ntwo\nlast line")
	scratch:set_name("jotted")
	scratch:set_kept(true)
	t:buffer("|here")
	t:keys("space space")
	local list = table.concat(t:floats(), "\n")
	assert(string.find(list, "scratch  jotted", 1, true), list)
	assert(string.find(list, "notes.txt", 1, true), list)
	-- @ keeps a kind; the preview shows a buffer that isn't a file at its end.
	t:keys("@ s c")
	t:wait_for(function()
		local shown = table.concat(t:floats(), "\n")
		return not string.find(shown, "notes.txt", 1, true)
	end)
	assert((string.find(table.concat(t:floats(), "\n"), "last line", 1, true)))
	t:keys("enter")
	assert(greed.view():buffer():id() == scratch:id(), "switched to it")
	-- ctrl-f shows it in a float instead, with the panes plugin there.
	if greed.plugin.dirs().panes then
		t:keys("space space n o t e s ctrl-f")
		local float = greed.view()
		assert(
			float:float_spec() ~= nil and float:buffer():path() == dir .. "/notes.txt",
			"a float"
		)
		float:close()
	end
	scratch:set_kept(false)
end)

test("space space lists what plugins add, kept by kind or tag, and enter goes there", function(t)
	local picker = require("@picker")
	local went: { string } = {}
	local remove = picker.add_places("test-places", function()
		return {
			{
				kind = "agent",
				label = "claude waiting in greed-2 on eris",
				tags = { "waiting", "eris" },
				go = function()
					table.insert(went, "claude")
				end,
				actions = {
					{
						name = "allow",
						run = function()
							table.insert(went, "allowed")
						end,
					},
				},
			},
			{
				kind = "session",
				label = "notes on mini",
				tags = { "mini" },
				go = function()
					table.insert(went, "notes")
				end,
			},
		}
	end)
	t:buffer("|here")
	t:keys("space space")
	local list = table.concat(t:floats(), "\n")
	assert(string.find(list, "agent    claude waiting in greed-2 on eris", 1, true), list)
	assert(string.find(list, "session  notes on mini", 1, true), list)
	-- A tag keeps those it's on.
	t:keys("@ e r i s")
	t:wait_for(function()
		return not string.find(table.concat(t:floats(), "\n"), "notes on mini", 1, true)
	end)
	t:keys("enter")
	t:keys("space space @ s e s s enter")
	-- ctrl-a lists what can be done to it, and runs what's chosen there.
	t:keys("space space @ w a i t ctrl-a")
	local offered = table.concat(t:floats(), "\n")
	assert(string.find(offered, "allow", 1, true), offered)
	t:keys("enter")
	assert(table.concat(went, " ") == "claude notes allowed", table.concat(went, " "))
	remove()
	t:keys("space space")
	list = table.concat(t:floats(), "\n")
	assert(not string.find(list, "notes on mini", 1, true), list)
	t:keys("esc")
end)

test(":watches lists what's watched, and enter stops watching one", function(t)
	local core = require("@core")
	t:buffer("|x")
	t:messages()
	t:run("watches")
	assert((string.find(table.concat(t:messages(), "|"), "nothing is watched", 1, true)))
	core.objects.kind({
		name = "test-thing",
		get = function(key)
			return { kind = "test-thing", id = `test-thing:{key}`, label = key, value = key }
		end,
		fresh = function()
			return { ok = true }
		end,
	})
	assert(core.watch.toggle(assert(core.objects.get("test-thing:one"))))
	t:run("watches")
	assert((string.find(table.concat(t:floats(), "\n"), "test-thing  one", 1, true)))
	t:keys("enter")
	assert(#core.watch.list() == 0, "stopped")
end)

test("a command needing an argument, picked from the palette, goes to the command line", function(t)
	-- The command line is another plugin's; without it, there's nothing to check.
	local there = false
	for _, command in greed.commands() do
		there = there or command.name == "command-line"
	end
	if not there then
		return
	end
	local ran: string? = nil
	greed.command({
		name = "test-greet-someone",
		doc = "Greets someone",
		args = { { name = "who", type = "string" } },
		run = function(ctx)
			ran = ctx.values.who
		end,
	})
	t:buffer("|x")
	t:run("command-palette")
	t:keys("t e s t - g r e e t - s o m e o n e enter")
	assert(ran == nil, "it didn't run without its argument")
	local floats = table.concat(t:floats(), "\n")
	assert(string.find(floats, ":test-greet-someone ", 1, true), floats)
	t:keys("y o u enter")
	assert(ran == "you", tostring(ran))
end)

-- The rows under the open picker's query, as drawn.
local function rows(): { string }
	local buffer = greed.view():buffer()
	local out = {}
	for line = 1, buffer:line_count() - 1 do
		table.insert(out, buffer:line_text(line))
	end
	return out
end

-- The text of every piece of the open picker drawn in `style`.
local function styled(style: string): { string }
	local buffer = greed.view():buffer()
	local out = {}
	for _, mark in buffer:decorations("picker") do
		if mark.style == style then
			table.insert(out, buffer:slice(mark.from, mark.to))
		end
	end
	return out
end

test("an item's detail goes in a column of its own after the labels, dimmed", function(t)
	local picker = require("@picker")
	t:buffer("|abc")
	picker.pick("Things", {
		{ label = "a", detail = "one", value = 1 },
		{ label = "longer", detail = "two", value = 2 },
		{ label = "plain", value = 3 },
	}, function() end)
	local shown = rows()
	assert(shown[1] == " a       one", shown[1])
	assert(shown[2] == " longer  two", shown[2])
	assert(shown[3] == " plain", "no detail, no column: " .. shown[3])
	local dimmed = table.concat(styled("ui.menu.doc"), ",")
	assert(dimmed == "one,two", dimmed)
end)

test("what's typed finds an item by its detail too, marked where it matched", function(t)
	local picker = require("@picker")
	t:buffer("|abc")
	picker.pick("Things", {
		{ label = "alpha", detail = "first", value = 1 },
		{ label = "beta", detail = "second", value = 2 },
	}, function() end)
	t:keys("s e c")
	assert(current() == "beta", tostring(current()))
	assert(matched() == "sec", matched())
end)

test("a label too long for its column is cut, so the details still line up", function(t)
	local picker = require("@picker")
	t:buffer("|abc")
	t:draw(50, 20)
	picker.pick("Things", {
		{ label = string.rep("x", 60), detail = "far", value = 1 },
		{ label = "short", detail = "near", value = 2 },
	}, function() end)
	t:draw(50, 20)
	local shown = rows()
	local long_at = string.find(shown[1], "far", 1, true)
	local short_at = string.find(shown[2], "near", 1, true)
	assert(string.find(shown[1], "…", 1, true), "cut: " .. shown[1])
	assert(long_at and short_at, table.concat(shown, "\n"))
	-- The ellipsis takes three bytes for its one column.
	assert(long_at - 2 == short_at, `{long_at} vs {short_at}:\n{table.concat(shown, "\n")}`)
end)

test("the outline names what each thing is in plain words, its line beside it", function(t)
	require("@greed").syntax.set_query(
		"rust",
		"textobjects",
		"(function_item) @function.around (struct_item) @type.around"
	)
	t:buffer("|fn first() {}\n" .. string.rep("\n", 10) .. "struct Second;\n")
	greed.view():buffer():set_language("rust")
	t:keys("space s")
	local shown = rows()
	assert(string.match(shown[1], "^ first%s+function%s+1$"), shown[1])
	assert(string.match(shown[2], "^ Second%s+type%s+12$"), shown[2])
	-- Right-aligned, so the numbers end in the same column.
	local first_end = #shown[1]
	local second_end = #shown[2]
	assert(first_end == second_end, "the line numbers line up:\n" .. table.concat(shown, "\n"))
end)

test("the detail column stays put as what's typed narrows the list", function(t)
	local picker = require("@picker")
	t:buffer("|abc")
	picker.pick("Things", {
		{ label = "a-much-longer-label", detail = "one", value = 1 },
		{ label = "b", detail = "two", value = 2 },
	}, function() end)
	local before = string.find(rows()[2], "two", 1, true)
	t:keys("t w o")
	local after = string.find(rows()[1], "two", 1, true)
	assert(before == after, `{before} then {after}: {rows()[1]}`)
end)
