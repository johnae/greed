local test = require("@kern/test")
local kern = require("@kern")

-- The highlighted item in the open picker.
local function current(): string?
	local buffer = kern.view():buffer()
	for _, mark in buffer:decorations("picker") do
		if mark.line then
			return string.match(buffer:slice(mark.from, mark.to), "^ ([%w%-]+)")
		end
	end
	return nil
end

-- The text of every character marked as matching the query.
local function matched(): string
	local buffer = kern.view():buffer()
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
	t:expect_mode("insert")
	assert(current() ~= nil, "the picker lists commands")

	t:keys("g o t o - e n d")
	assert(current() == "goto-end", "best match is goto-end, got " .. tostring(current()))

	t:keys("enter")
	t:expect_mode("normal")
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
	t:expect_mode("normal")
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
	kern.command({
		name = "pick-live",
		run = function()
			picker.pick("Live", {}, function() end, {
				source = function(query)
					table.insert(asked, query)
					kern.sleep(50)
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
	assert(string.find(kern.view():buffer():text(), " ab!", 1, true), kern.view():buffer():text())
	t:keys("c")
	t:wait(100)
	-- Typing while the source works for "abc": its answer is dropped and it's
	-- asked again for "abcd".
	t:keys("d")
	t:wait(60)
	assert(
		not string.find(kern.view():buffer():text(), "abc!", 1, true),
		"the stale answer isn't shown"
	)
	t:wait(100)
	assert(table.concat(asked, ",") == "ab,abc,abcd", table.concat(asked, ","))
	assert(string.find(kern.view():buffer():text(), " abcd!", 1, true), kern.view():buffer():text())
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
	local lines = string.split(kern.view():buffer():text(), "\n")
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
	kern.run("project", { args = { dir } })
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
	assert(kern.view():buffer():path() == dir .. "/src/b.txt", kern.view():buffer():path())
	assert(kern.view():buffer():text() == "beta")
end)

test("space b lists the open files and previews them as they are now", function(t)
	local dir = t:tempdir({ ["one.txt"] = "first", ["two.txt"] = "second" })
	kern.open(dir .. "/one.txt")
	t:keys("i n e w space esc")
	kern.open(dir .. "/two.txt")
	t:keys("space b o n e")
	assert(table.find(t:floats(), "new first"), "unsaved text in the preview")
	t:keys("enter")
	assert(kern.view():buffer():path() == dir .. "/one.txt")
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
		kern.mode.set("edit")
		picker.pick("Wrap", list, function(item)
			got = item.value
		end)
		t:keys("up enter")
		assert(got == 3, "up from the first is the last")
		t:expect_mode("edit")
		picker.pick("Wrap", list, function(item)
			got = item.value
		end)
		t:keys("down down down enter")
		assert(got == 1, "down from the last is the first")
	end
)

test("a source that fails shows nothing instead of breaking the picker", function(t)
	local picker = require("@picker")
	kern.command({
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
	t:expect_mode("normal")
end)

test("the command palette shows each command's keys", function(t)
	t:buffer("|abc")
	t:keys("space ? g o t o - e n d")
	assert(
		string.find(kern.view():buffer():text(), "goto-end  (g e)", 1, true),
		kern.view():buffer():text()
	)
	t:keys("esc")
end)

test("the outline lists functions and types, nested, and jumps to one", function(t)
	require("@kern").syntax.set_query(
		"rust",
		"textobjects",
		"(function_item) @function.around (impl_item body: (_) @type.inside) @type.around (struct_item) @type.around"
	)
	t:buffer("|struct S;\nfn one() {}\nfn two() {}\n")
	kern.view():buffer():set_language("rust")
	t:keys("space s")
	local list = kern.view():buffer():text()
	assert(string.find(list, "S  struct_item:1", 1, true), list)
	assert(string.find(list, "two  function_item:3", 1, true), list)
	t:keys("t w o enter")
	t:expect("struct S;\nfn one() {}\nfn |two() {}\n")
end)
