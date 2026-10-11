local test = require("@greed/test")
local greed = require("@greed")

local function text(): string
	return greed.view():buffer():text()
end

local function has(wanted: string): () -> boolean
	return function()
		return string.find(text(), wanted, 1, true) ~= nil
	end
end

-- Shows `page` in a fresh buffer, the cursor at its start: written out,
-- as `t:buffer` reads `|` as a cursor.
local function page(t: test.TestContext, text: string)
	t:buffer("|")
	local buffer = greed.view():buffer()
	buffer:edit(function(e)
		e:insert(0, text)
	end)
	greed.view():set_cursor(0)
end

-- The marks the blocks plugin shows in the buffer, of `style` or any.
local function marks(style: string?): { greed.Mark }
	local out: { greed.Mark } = {}
	for _, mark in greed.view():buffer():decorations("blocks") do
		if style == nil or mark.style == style then
			table.insert(out, mark)
		end
	end
	return out
end

test("a shell block runs in the Greed shell, table stages and all", function(t)
	page(
		t,
		"```shell\nprintf 'NAME     SIZE\\napple    1\\nbanana   20\\n' | where SIZE > 5 | select NAME\n```"
	)
	t:run("block-run")
	t:wait_for(has("```result"))
	local result = string.match(text(), "```result\n(.-)\n```") or ""
	assert(string.find(result, "banana", 1, true), text())
	assert(not string.find(result, "apple", 1, true), text())
end)

test("several lines run in turn, stopping at one that fails", function(t)
	t:buffer("```shell\necho one\n# a comment\necho two\nfalse\necho never\n```|")
	t:run("block-run")
	t:wait_for(has("```result"))
	local result = string.match(text(), "```result exit=1\n(.-)\n```") or ""
	assert(result == "one\ntwo", text())
end)

test("a shell block's chart shows in its result with its colours", function(t)
	page(t, "```shell\nprintf 'name value\\na 3\\nb 7\\n' | chart\n```")
	t:run("block-run")
	t:wait_for(has("```result"))
	assert(string.find(text(), "█", 1, true), text())
	t:wait_for(function()
		return #marks() > 0 and #marks("blocks.run") < #marks()
	end)
	local coloured = false
	for _, mark in marks() do
		coloured = coloured or string.find(mark.style or "", "chart", 1, true) ~= nil
	end
	assert(coloured, "the bars have the chart's colours")
	-- Edited away from the chart, the result shows as the text it is.
	local buffer = greed.view():buffer()
	local at = assert((string.find(text(), "█", 1, true)))
	buffer:edit(function(e)
		e:replace(at - 1, at - 1 + #"█", "x")
	end)
	for _, mark in marks() do
		assert(not string.find(mark.style or "", "chart", 1, true), mark.style)
	end
end)

test("every=N keeps a block's result up to date until it's stopped", function(t)
	local dir = t:tempdir({})
	t:buffer(`\`\`\`shell every=0.2 dir={dir}\necho x >> n; wc -l < n\n\`\`\`|`)
	local buffer = greed.view():buffer()
	local before = #buffer:history()
	t:run("block-run")
	t:wait_for(has("```result"))
	local function count(): number
		return tonumber(string.match(text(), "```result\n%s*(%d+)")) or 0
	end
	-- The watch waits on the editor's clock, and its command for real.
	for _ = 1, 20 do
		local was = count()
		if was >= 3 then
			break
		end
		t:wait(250)
		pcall(t.wait_for, t, function()
			return count() > was
		end, 1000)
	end
	assert(count() >= 3, text())
	local live = marks("blocks.running")
	assert(#live == 1 and live[1].text == "● live", tostring(live[1] and live[1].text))
	-- The updates aren't edits to undo: only the first result is.
	assert(#buffer:history() <= before + 1, `{#buffer:history() - before} edits to undo`)
	greed.view():set_cursor(0)
	t:run("block-stop")
	local stopped = count()
	t:wait(600)
	assert(count() == stopped, `{count()} after stopping at {stopped}`)
	assert(#marks("blocks.running") == 0, "nothing shows as live once stopped")
end)

test("a live block stops when its block goes", function(t)
	t:buffer("```shell every=0.2\ndate +%N\n```|")
	t:run("block-run")
	t:wait_for(has("```result"))
	local buffer = greed.view():buffer()
	buffer:edit(function(e)
		e:replace(0, buffer:len(), "gone")
	end)
	t:wait(600)
	assert(text() == "gone", text())
	assert(#marks("blocks.running") == 0, "the live run ended")
end)

test("every=N takes one line", function(t)
	t:buffer("```shell every=1\necho a\necho b\n```|")
	t:run("block-run")
	t:wait_for(has("```result"))
	assert(string.find(text(), "every=N runs one line", 1, true), text())
end)

test("input= gives a shell block another block's result to start from", function(t)
	page(
		t,
		"```sh id=sizes\nprintf 'NAME     SIZE\\napple    1\\nbanana   20\\n'\n```\n\n"
			.. "```shell input=sizes\nwhere SIZE > 5 | select NAME\n```"
	)
	greed.view():set_cursor(assert((string.find(text(), "```shell", 1, true))) - 1)
	t:run("block-run")
	t:wait_for(function()
		local _, count = string.gsub(text(), "```result", "")
		return count == 2
	end)
	local last = string.match(text(), "```shell.-```result\n(.-)\n```") or ""
	assert(string.find(last, "banana", 1, true), text())
	assert(not string.find(last, "apple", 1, true), text())
end)
