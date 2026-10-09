local test = require("@greed/test")
local greed = require("@greed")

-- Types `text` on the command line and runs it.
local function ex(t: test.TestContext, text: string)
	local keys = { ":" }
	for _, code in utf8.codes(text) do
		local char = utf8.char(code)
		table.insert(keys, if char == " " then "space" else char)
	end
	table.insert(keys, "enter")
	t:keys(table.concat(keys, " "))
end

local function fails(f: () -> ()): string
	local ok: boolean, err: unknown = pcall(f)
	assert(not ok, "expected an error")
	return tostring(err)
end

test("a line number goes to that line, and ranges pick lines for a command", function(t)
	t:buffer("|a\n  b\nc\nd")
	ex(t, "2")
	t:expect("a\n  |b\nc\nd")
	ex(t, "$")
	t:expect("a\n  b\nc\n|d")
	ex(t, "1,2d")
	t:expect("|c\nd")
	t:buffer("a\n|b\nc\nd")
	ex(t, ".,+1d")
	t:expect("a\n|d")
	t:buffer("|a\nb\nfoo\nc")
	ex(t, "/foo/d")
	t:expect("a\nb\n|c")
end)

test(":s replaces on the cursor's line, :%s everywhere, with groups and flags", function(t)
	t:buffer("|a a\na a")
	ex(t, "s/a/b/")
	t:expect("|b a\na a")
	ex(t, "%s/a/c/g")
	t:expect("b c\n|c c")
	t:buffer("|key = value")
	ex(t, [[s/(\w+) = (\w+)/\2: \1 (&)/]])
	t:expect("|value: key (key = value)")
	t:buffer("|one/two")
	ex(t, [[s#/#\n#]])
	t:expect("one\n|two")
	t:buffer("|x")
	local err = fails(function()
		ex(t, "s/y/z/")
	end)
	assert(string.find(err, "pattern not found", 1, true), err)
end)

-- Types `text` after ":" without running it.
local function typing(t: test.TestContext, text: string)
	local keys = { ":" }
	for _, code in utf8.codes(text) do
		local char = utf8.char(code)
		table.insert(keys, if char == " " then "space" else char)
	end
	t:keys(table.concat(keys, " "))
end

-- The preview's marks on `buffer` as "from-to style text", in order.
local function preview(buffer: greed.Buffer): { string }
	local out = {}
	for _, mark in buffer:decorations("substitute-preview") do
		table.insert(out, `{mark.from}-{mark.to} {mark.style} {mark.text or ""}`)
	end
	table.sort(out)
	return out
end

test(":s shows what it will change as you type it, and nothing changes until it runs", function(t)
	t:buffer("|a x\nx a")
	local main = greed.view():buffer()
	-- The pattern alone: its matches on the lines it would change.
	typing(t, "%s/a")
	local found = preview(main)
	assert(
		#found == 2 and string.find(found[1], "0-1 ui.search.match", 1, true),
		table.concat(found, " | ")
	)
	-- With a replacement: the old text struck through and the new beside it.
	t:keys("/ b b")
	found = preview(main)
	assert(
		table.concat(found, " | ")
			== "0-1 diff.minus  | 1-1 diff.plus bb | 6-7 diff.minus  | 7-7 diff.plus bb",
		table.concat(found, " | ")
	)
	assert(main:text() == "a x\nx a", "nothing changed yet")
	-- Closed without running, it's all gone.
	t:keys("esc")
	assert(#preview(main) == 0 and main:text() == "a x\nx a", "gone")
	-- Run, it changes and the preview goes.
	ex(t, "%s/a/bb/")
	assert(main:text() == "bb x\nx bb" and #preview(main) == 0, main:text())
	-- Brought back from history, it shows again.
	t:buffer("|a")
	local other = greed.view():buffer()
	t:keys(": up")
	assert(#preview(other) == 2, table.concat(preview(other), " | "))
	t:keys("esc")
end)

test("the :s preview follows the range, skips a bad pattern, and can be turned off", function(t)
	t:buffer("|a\na")
	local main = greed.view():buffer()
	typing(t, "s/a/b")
	assert(#preview(main) == 2, "the cursor's line only: " .. table.concat(preview(main), " | "))
	t:keys("esc")
	typing(t, "%s/(")
	assert(#preview(main) == 0, "a pattern half typed shows nothing")
	t:keys("esc")
	greed.option.set("substitute-preview", false)
	typing(t, "%s/a/b")
	assert(#preview(main) == 0, "turned off")
	t:keys("esc")
	greed.option.set("substitute-preview", true)
end)

test(":g runs a command on matching lines, :v on the others", function(t)
	t:buffer("|keep 1\ndrop\nkeep 2\ndrop")
	ex(t, "g/drop/d")
	t:expect("keep 1\n|keep 2")
	t:buffer("|keep 1\ndrop\nkeep 2")
	ex(t, "v/keep/d")
	t:expect("keep 1\n|keep 2")
	t:buffer("|a1\nb\na2")
	ex(t, "g/a/s/\\d/!/")
	t:expect("a!\nb\n|a!")
	-- Without a command, :g selects the lines.
	t:buffer("|a1\nb\na2")
	ex(t, "g/a/")
	assert(#greed.view():selection().ranges == 2, "a selection per line")
end)

test(":m and :t move and copy lines, :y copies them", function(t)
	t:buffer("|a\nb\nc")
	ex(t, "m$")
	t:expect("b\nc\n|a")
	ex(t, "m0")
	t:expect("|a\nb\nc")
	ex(t, "t1")
	t:expect("a\n|a\nb\nc")
	ex(t, "2,3y")
	local copied = (greed.clipboard.get() or {})[1]
	assert(copied == "a\nb\n", copied)
end)

test(":norm types keys on each line of the range, in normal mode", function(t)
	t:buffer("|a\nb\nc")
	greed.mode.set("vim")
	ex(t, "%norm A;")
	t:expect("a;\nb;\nc|;")
	greed.mode.set("helix")
end)
