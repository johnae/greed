local test = require("@greed/test")
local greed = require("@greed")
local markdown = require("@markdown")

-- `text` open as a Markdown file with the cursor at its end (on a line of
-- its own), drawn without line numbers. Returns the rows.
local function shown(t: test.TestContext, text: string): { string }
	local dir = t:tempdir({ ["doc.md"] = text .. "\n" })
	greed.open(`{dir}/doc.md`)
	local view = greed.view()
	view:buffer():set_line_numbers(false)
	local last = view:buffer():len()
	view:set_selection({ ranges = { { anchor = last, head = last } }, primary = 1 })
	return t:draw(60, 12)
end

local function styled(style: string): { string }
	local buffer = greed.view():buffer()
	local out = {}
	for _, mark in buffer:decorations("markdown") do
		if mark.style == style then
			table.insert(out, buffer:slice(mark.from, mark.to))
		end
	end
	return out
end

test("headings lose their hashes, the top level twice the size", function(t)
	local rows = shown(t, "# Title\n## Part\ntext")
	assert(rows[1] == "Title", rows[1])
	assert(rows[2] == "", "the big heading takes the row below too")
	assert(rows[3] == "Part", rows[3])
	for _, mark in greed.view():buffer():decorations("markdown") do
		if mark.style == "markdown.heading.1" then
			assert(mark.scale == 2, "twice the size")
		end
	end
	assert(styled("markdown.heading.2")[1] == "Part")
end)

test("emphasis, code and links show without their markup", function(t)
	local rows = shown(t, "a **bold** and *slanted* ~~gone~~ `x = 1` [site](http://e.x) snake_case")
	assert(rows[1] == "a bold and slanted gone x = 1 site snake_case", rows[1])
	assert(styled("markdown.bold")[1] == "bold")
	assert(styled("markdown.italic")[1] == "slanted")
	assert(styled("markdown.strike")[1] == "gone")
	assert(styled("markdown.code")[1] == "x = 1")
	assert(styled("markdown.link")[1] == "site")
end)

test("markup inside code stays as written", function(t)
	local rows = shown(t, "`**not bold**` and *yes*")
	assert(rows[1] == "**not bold** and yes", rows[1])
end)

test("code blocks, quotes, rules and bullets", function(t)
	local rows = shown(t, "```lua\nlocal x = **1**\n```\n> wise words\n---\n- item")
	assert(rows[2] == "local x = **1**", `code keeps its markup: {rows[2]}`)
	assert(#styled("markdown.code.block") == 3, "the fences and the code between")
	assert(rows[4] == "▎ wise words", rows[4])
	assert(rows[5] ~= "" and (string.gsub(rows[5], "─", "")) == "", rows[5])
	assert(rows[6] == "• item", rows[6])
end)

test("a code block's result looks a little apart from code", function(t)
	shown(t, "```sh\nls\n```\n\n```result\na\n```")
	assert(#styled("markdown.code.block") == 3, "the code block")
	assert(#styled("markdown.code.block.result") == 3, "its result")
end)

test("typing on a line shows it as written", function(t)
	shown(t, "# Title\n**bold**")
	greed.view():set_selection({ ranges = { { anchor = 10, head = 10 } }, primary = 1 })
	t:keys("i")
	local rows = t:draw(60, 12)
	assert(rows[3] == "**bold**", `the line being typed on: {rows[3]}`)
	assert(rows[1] == "Title", "the others stay drawn")
	t:keys("esc")
	assert(t:draw(60, 12)[3] == "bold")
end)

test("markdown-look off shows the file as written", function(t)
	shown(t, "# Title")
	greed.option.set("markdown-look", false)
	assert(t:draw(60, 12)[1] == "# Title")
end)

test("a plugin can draw headings its own way", function(t)
	local undo = require("@markdown").claim(function()
		return { headings = true }
	end)
	local rows = shown(t, "# Title")
	assert(rows[1] == "# Title", rows[1])
	undo()
	assert(t:draw(60, 12)[1] == "Title")
end)

-- The hidden line ranges in the main view, e.g. "2-3".
local function hidden(): string
	local out = {}
	for _, lines in greed.view():hidden_lines() do
		table.insert(out, `{lines.from}-{lines.to}`)
	end
	return table.concat(out, " ")
end

test("tab folds the code block, list item or section around the cursor", function(t)
	local function at(line: number)
		local start = greed.view():buffer():line_start(line)
		greed.view():set_selection({ ranges = { { anchor = start, head = start } }, primary = 1 })
	end
	shown(
		t,
		"# Plan\n\n```sh\necho a\necho b\n```\n\n- [ ] ship it\n  - [ ] tests\n  - [ ] docs\n- [ ] rest\n\n# Later"
	)
	-- In the code: the block folds under its opening fence.
	at(3)
	t:keys("tab")
	assert(hidden() == "3-5", "the code block: " .. hidden())
	t:keys("tab")
	assert(hidden() == "", hidden())
	-- On a todo with subtasks: the subtasks fold under it.
	at(7)
	t:keys("tab")
	assert(hidden() == "8-9", "the subtasks: " .. hidden())
	t:keys("tab")
	-- On a line that's in neither: the section under the heading.
	at(1)
	t:keys("tab")
	assert(hidden() == "1-10", "the section, up to the blank line before the next: " .. hidden())
	-- shift-tab unfolds everything, and folds everything when nothing is.
	t:keys("shift-tab")
	assert(hidden() == "", hidden())
	t:keys("shift-tab")
	assert(hidden() ~= "", "folded again")
end)

test("choices show as buttons, and pressing one picks it and unpicks the rest", function(t)
	shown(t, "## How do you like to edit?\n\n- (x) Helix\n- ( ) Vim\n- ( ) No modes\n\nAfter")
	assert(
		#styled("markdown.chosen") == 1 and #styled("markdown.choice") == 2,
		"one picked, two not"
	)
	local buffer = greed.view():buffer()
	local heard: { string } = {}
	local stop = require("@markdown").choices.on_pick(function(_, group)
		for _, option in group.options do
			if option.picked then
				table.insert(heard, `{group.question}: {option.text}`)
			end
		end
	end)
	-- enter on a choice presses it, as a click does.
	local vim = buffer:line_start(3)
	greed.view():set_selection({ ranges = { { anchor = vim, head = vim } }, primary = 1 })
	t:keys("enter")
	assert(
		string.find(buffer:text(), "- ( ) Helix\n- (x) Vim\n- ( ) No modes", 1, true),
		buffer:text()
	)
	assert(heard[1] == "How do you like to edit?: Vim", heard[1])
	stop()
	local groups = require("@markdown").choices.list(buffer)
	assert(
		#groups == 1 and groups[1].question == "How do you like to edit?",
		"one group, its question"
	)
	assert(groups[1].options[2].picked and groups[1].options[2].text == "Vim")
end)

test("two lists of choices are two groups, each picked on its own", function(t)
	shown(t, "Light or dark?\n\n- (x) Dark\n- ( ) Light\n\nIcons?\n\n- ( ) Yes\n- (x) No")
	local buffer = greed.view():buffer()
	require("@markdown").choices.pick(buffer, 7)
	assert(
		string.find(buffer:text(), "- (x) Dark\n- ( ) Light", 1, true),
		"the first group is untouched"
	)
	assert(string.find(buffer:text(), "- (x) Yes\n- ( ) No", 1, true), buffer:text())
end)

test("markdown-look-toggle shows one file as written, and as a document again", function(t)
	shown(t, "# Title")
	t:keys("space m l")
	assert(t:draw(60, 12)[1] == "# Title", "off for this file")
	local said = table.concat(t:messages(), "\n")
	assert(string.find(said, "off for this file", 1, true) ~= nil, said)
	local _, right = t:status()
	assert(
		right ~= nil and string.find(right, "plain", 1, true) ~= nil,
		`the status line says so: {right}`
	)
	t:keys("space m l")
	assert(t:draw(60, 12)[1] == "Title", "on again")
	said = table.concat(t:messages(), "\n")
	assert(string.find(said, "on for this file", 1, true) ~= nil, said)
end)

test("a file's own look wins over markdown-look, until it matches it again", function(t)
	shown(t, "# Title")
	local buffer = greed.view():buffer()
	-- Off for this file, then the option goes off and on: the file stays off.
	t:keys("space m l")
	greed.option.set("markdown-look", false)
	greed.option.set("markdown-look", true)
	assert(t:draw(60, 12)[1] == "# Title", "still off")
	-- On again, it matches the option, so it follows the option from now on.
	t:keys("space m l")
	greed.option.set("markdown-look", false)
	assert(t:draw(60, 12)[1] == "# Title", "follows the option")
	-- With the option off, the toggle turns this one file on.
	t:keys("space m l")
	assert(t:draw(60, 12)[1] == "Title", "on for this file")
	-- Other files keep following the option.
	local dir = t:tempdir({ ["other.md"] = "# Other\n" })
	greed.open(`{dir}/other.md`)
	greed.view():buffer():set_line_numbers(false)
	assert(t:draw(60, 12)[1] == "# Other", t:draw(60, 12)[1])
	assert(buffer ~= greed.view():buffer())
end)

test("the look toggles from vim and from the vscode style too", function(t)
	shown(t, "# Title")
	greed.option.set("editing-style", "vim")
	t:keys("space m l")
	assert(t:draw(60, 12)[1] == "# Title", "vim")
	greed.option.set("editing-style", "vscode")
	t:keys("alt-V")
	assert(t:draw(60, 12)[1] == "Title", "the vscode style")
end)

test("the look toggle says when a file isn't Markdown", function(t)
	t:buffer("plain |text")
	t:run("markdown-look-toggle")
	assert(table.concat(t:messages(), "\n") == "not a Markdown file")
end)

test("tables show in columns with borders", function(t)
	local rows =
		shown(t, "Sizes:\n| Name | Size |\n|:--|--:|\n| a | 12 |\n| **long** name | 3 |\n\nafter")
	assert(rows[1] == "Sizes:", rows[1])
	assert(rows[2] == "┌───────────┬──────┐", rows[2])
	assert(rows[3] == "│ Name      │ Size │", rows[3])
	assert(rows[4] == "├───────────┼──────┤", rows[4])
	assert(rows[5] == "│ a         │   12 │", rows[5])
	assert(rows[6] == "│ long name │    3 │", rows[6])
	assert(rows[7] == "└───────────┴──────┘", rows[7])
	assert(rows[9] == "after", rows[9])
end)

test("a table row short of cells is filled out, and one with too many cut", function(t)
	local rows = shown(t, "| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |")
	assert(rows[1] == "│ a │ b │", rows[1])
	assert(rows[3] == "│ 1 │   │", rows[3])
	assert(rows[4] == "│ 1 │ 2 │", rows[4])
end)

test("pipes without a delimiter row aren't a table", function(t)
	local rows = shown(t, "a | b\nc | d")
	assert(rows[1] == "a | b", rows[1])
end)

-- A 8 by 64 PNG.
local PNG =
	"\137\80\78\71\13\10\26\10\0\0\0\13\73\72\68\82\0\0\0\8\0\0\0\64\8\0\0\0\0\2\111\105\86\0\0\0\18\73\68\65\84\120\156\99\104\128\2\134\81\198\40\131\116\6\0\19\32\0\16\91\154\159\85\0\0\0\0\73\69\78\68\174\66\96\130"

-- `text` in `doc.md` with `files` beside it, open with the cursor at the
-- start, drawn without line numbers.
local function opened(t: test.TestContext, text: string, files: { [string]: string }?): string
	local all: { [string]: string } = { ["doc.md"] = text }
	for name, contents in files or {} :: { [string]: string } do
		all[name] = contents
	end
	local dir = t:tempdir(all)
	greed.open(`{dir}/doc.md`)
	greed.view():buffer():set_line_numbers(false)
	return dir
end

test("the reading view hides all markup, even where the cursor is, and is read-only", function(t)
	opened(t, "# Title\n```lua\nx = 1\n```\n**bold**\n")
	local buffer = greed.view():buffer()
	buffer:set_line_numbers(true)
	t:keys("space m v")
	t:expect_mode("read")
	assert(buffer:readonly() and not buffer:line_numbers(), "read-only, without line numbers")
	local rows = t:draw(60, 12)
	assert(rows[1] == "Title", `the cursor's line too: {rows[1]}`)
	assert(rows[3] == "", `the fence: {rows[3]}`)
	assert(rows[4] == "x = 1", rows[4])
	assert(rows[5] == "", rows[5])
	t:keys("j j j j")
	assert(t:draw(60, 12)[6] == "bold", "bold on the cursor's line")
	t:keys("d")
	assert(buffer:text() == "# Title\n```lua\nx = 1\n```\n**bold**\n", "the text stays")
end)

test("esc or the same key goes back to editing, at the same place", function(t)
	local lines = {}
	for n = 1, 60 do
		table.insert(lines, `line {n}`)
	end
	opened(t, table.concat(lines, "\n") .. "\n")
	local view = greed.view()
	t:draw(60, 12)
	t:keys("space m v")
	t:keys("ctrl-f")
	t:draw(60, 12)
	local scroll, selection = view:scroll(), view:selection()
	assert(scroll > 0, "scrolled")
	t:keys("esc")
	t:expect_mode("helix")
	t:draw(60, 12)
	assert(view:scroll() == scroll, `the same scroll: {view:scroll()} {scroll}`)
	assert(view:selection().ranges[1].head == selection.ranges[1].head, "the same cursor")
	assert(not view:buffer():readonly() and not view:buffer():line_numbers(), "as it was")
	t:keys("space m v")
	t:expect_mode("read")
	t:keys("space m v")
	t:expect_mode("helix")
end)

test("the reading view comes from vim and vscode, and goes back to them", function(t)
	opened(t, "# Title\n")
	greed.option.set("editing-style", "vim")
	t:keys("space m v")
	t:expect_mode("read")
	t:keys("q")
	t:expect_mode("vim")
	greed.option.set("editing-style", "vscode")
	t:keys("alt-v")
	t:expect_mode("read")
	t:keys("alt-v")
	t:expect_mode("vscode")
end)

test("switching style ends the reading", function(t)
	opened(t, "# Title\n")
	local buffer = greed.view():buffer()
	t:keys("space m v")
	greed.option.set("editing-style", "vim")
	assert(not buffer:readonly(), "editable again")
	assert(not require("@markdown").reading(buffer))
end)

test("reading, links are their text and enter follows one to a heading", function(t)
	opened(t, "See [the end](#the-end).\n\ntext\n\n## The End\n")
	t:keys("space m v")
	local rows = t:draw(60, 12)
	assert(rows[1] == "See the end.", rows[1])
	t:keys("l l l l enter")
	local view = greed.view()
	assert(view:buffer():line_of(view:selection().ranges[1].head) == 4, "on the heading")
end)

test("a link to another Markdown file opens it, read too", function(t)
	opened(t, "[next](next%20page.md#two)\n", { ["next page.md"] = "# One\n\n# Two\n" })
	t:keys("space m v")
	t:draw(60, 12)
	t:mouse("press", 1, 0)
	local buffer = greed.view():buffer()
	assert(string.match(buffer:path() or "", "next page%.md$"), buffer:path())
	assert(require("@markdown").reading(buffer), "read too")
	assert(buffer:line_of(greed.view():selection().ranges[1].head) == 2, "at the heading")
	t:keys("esc")
	assert(not buffer:readonly(), "back to editing")
end)

test("a link to a file that isn't there says so", function(t)
	opened(t, "[gone](gone.md)\n")
	t:keys("space m v enter")
	assert(string.find(table.concat(t:messages(), "\n"), "no file", 1, true), "it says so")
	t:expect_mode("read")
end)

test("a web link opens with the link opener", function(t)
	opened(t, "[site](https://example.com)\n")
	greed.option.set("link-opener", "true")
	t:keys("space m v enter")
	local said = table.concat(t:messages(), "\n")
	assert(
		not string.find(said, "can't", 1, true) and not string.find(said, "no link", 1, true),
		said
	)
	assert(greed.view():selection().ranges[1].head == 0, "the cursor stays")
end)

test("reading, an image on its own line shows in place", function(t)
	opened(t, "above\n![a dot](dot.png)\nbelow\n![gone](nothing.png)\n", { ["dot.png"] = PNG })
	t:keys("space m v")
	local buffer = greed.view():buffer()
	local image: any = nil
	for _, mark in buffer:decorations("markdown") do
		if mark.image then
			image = mark
		end
	end
	assert(image and image.image.rows > 1, "drawn over a few rows")
	assert(#image.lines == image.image.rows - 1, "with room under its line")
	local rows = t:draw(60, 20)
	assert(rows[1] == "above", rows[1])
	assert(rows[2 + image.image.rows] == "below", `below the image: {rows[2 + image.image.rows]}`)
	assert(rows[3 + image.image.rows] == "gone", "one that doesn't load shows its description")
	t:keys("esc")
	for _, mark in buffer:decorations("markdown") do
		assert(mark.image == nil, "gone when editing")
	end
end)

test("a # line in a code block is code, not a heading, and doesn't end a section", function(t)
	local rows = shown(t, "# Setup\n\n```sh\n# install it\nmake\n```\n\nmore\n\n# Use")
	assert(table.find(rows, "# install it"), table.concat(rows, "|"))
	assert(#styled("markdown.heading.1") == 2, "two headings")
	local start = greed.view():buffer():line_start(7)
	greed.view():set_selection({ ranges = { { anchor = start, head = start } }, primary = 1 })
	t:keys("tab")
	assert(hidden() == "1-7", "the whole section: " .. hidden())
end)

local SAMPLE = table.concat({
	"# Title",
	"",
	"Underlined",
	"==========",
	"",
	"```lua",
	"# not a heading",
	"- not an item",
	"```",
	"",
	"- [ ] todo with [a link](other.md#part)",
	"  + [x] done",
	"* star",
	"1. numbered",
	"",
	"| a | b |",
	"|---|---|",
	"| 1 | 2 |",
	"",
	"> # quoted heading",
	"",
	"Some `[code](x)` and ![an image](pic.png).",
	"",
	"~~~",
	"open to the end",
}, "\n")

-- What a structure says, as text to compare.
local function summary(s: markdown.Structure): string
	local parts: { string } = {}
	for _, h in s.headings do
		table.insert(parts, `h{h.level} {h.line}-{h.last} {h.text} @{h.from}`)
	end
	for _, c in s.code do
		table.insert(
			parts,
			`code {c.open}-{c.close} {c.closed} [{c.info}] {c.lang} {c.from}-{c.to} {c.code_from}-{c.code_to}`
		)
	end
	for _, i in s.items do
		table.insert(parts, `item {i.line}-{i.last} {i.bullet} [{i.check or ""}] @{i.from}`)
	end
	for _, tbl in s.tables do
		table.insert(parts, `table {tbl.first}-{tbl.last}`)
	end
	for _, l in s.links do
		table.insert(
			parts,
			`link {l.line} {l.from}-{l.to} {l.text} {l.target} {l.target_from} {l.image}`
		)
	end
	return table.concat(parts, "\n")
end

test("the structure has headings, code, items, tables and links, tree or no tree", function(t)
	shown(t, SAMPLE)
	local buffer = greed.view():buffer()
	assert(buffer:tree(), "a syntax tree")
	local s = markdown.structure(buffer)
	local want = table.concat({
		"h1 0-0 Title @0",
		"h1 2-3 Underlined @9",
		"h1 19-19 quoted heading @180",
		"code 5-8 true [lua] lua 32-72 39-68",
		"code 23-25 false []  242-262 246-262",
		"item 10-11 - [ ] @74",
		"item 11-11 + [x] @116",
		"item 12-12 * [] @127",
		"item 13-13 1. [] @134",
		"table 15-17",
		"link 10 90-113 a link other.md#part 99 false",
		"link 21 219-239 an image pic.png 231 true",
	}, "\n")
	assert(summary(s) == want, summary(s))
	assert(markdown.structure(buffer) == s, "kept while the buffer doesn't change")
	-- Read from the text alone, line by line, it's the same.
	local scanned = markdown.structure(buffer:text())
	assert(summary(scanned) == want, summary(scanned))
	buffer:edit(function(e)
		e:insert(0, "x")
	end)
	assert(markdown.structure(buffer) ~= s, "worked out again after an edit")
end)

-- The marks in namespace `ns`, sorted, as text to compare.
local function marks_of(ns: string): string
	local out: { string } = {}
	for _, mark in greed.view():buffer():decorations(ns) do
		table.insert(
			out,
			`{mark.from}-{mark.to} {mark.style} {mark.text or ""} {mark.conceal} {#(mark.lines or {})}`
		)
	end
	table.sort(out)
	return table.concat(out, "\n")
end

test("after an edit only what changed is read and drawn again, as if all of it was", function(t)
	shown(t, SAMPLE)
	local buffer = greed.view():buffer()
	-- Each edit: the line it's on, where in the line, how much it replaces
	-- and with what.
	local edits: { { line: number, at: number, len: number, text: string } } = {
		-- A fence opening makes the rest of the file code, and taking it
		-- out again doesn't.
		{ line = 0, at = 0, len = 0, text = "```\n" },
		{ line = 0, at = 0, len = 4, text = "" },
		{ line = 9, at = 0, len = 0, text = "```\n" },
		{ line = 9, at = 0, len = 4, text = "" },
		-- A wider cell widens the whole table.
		{ line = 17, at = 2, len = 0, text = "wide" },
		-- Text under a line makes it a heading.
		{ line = 1, at = 0, len = 0, text = "Now a heading\n---" },
		-- An indented line goes on with the list item above it.
		{ line = 15, at = 0, len = 0, text = "  more of it\n" },
		-- A closing fence ends the code block that went to the end.
		{ line = 27, at = 0, len = 0, text = "~~~\n# after\n" },
		-- Lines go.
		{ line = 9, at = 0, len = 40, text = "" },
	}
	for i, edit in edits do
		local from = buffer:line_start(math.min(edit.line, buffer:line_count() - 1)) + edit.at
		buffer:edit(function(e)
			e:replace(from, math.min(from + edit.len, buffer:len()), edit.text)
		end)
		-- What the edit set off finishes first, even cut into time slices
		-- on a busy machine.
		t:wait(0)
		local read = summary(markdown.structure(buffer))
		local whole = summary(markdown.structure(buffer:text()))
		assert(read == whole, `edit {i}:\n{read}\n---\n{whole}`)
		local partly = marks_of("markdown")
		markdown.refresh()
		local all = marks_of("markdown")
		assert(partly == all, `edit {i}:\n{partly}\n---\n{all}`)
	end
end)

test("buffer.changed says which lines changed", function(t)
	t:buffer("a\nb\nc\nd|")
	local seen: { { number? } } = {}
	local function hear(event: greed.BufferChanged)
		table.insert(seen, { event.from_line, event.to_line })
	end
	greed.on("buffer.changed", hear)
	local buffer = greed.view():buffer()
	buffer:edit(function(e)
		e:insert(buffer:line_start(2), "new\n")
	end)
	buffer:edit(function(e)
		e:delete(buffer:line_start(1), buffer:line_start(2))
	end)
	greed.off("buffer.changed", hear)
	assert(seen[1][1] == 2 and seen[1][2] == 3, `{seen[1][1]}-{seen[1][2]}`)
	assert(seen[2][1] == 1 and seen[2][2] == 1, `{seen[2][1]}-{seen[2][2]}`)
end)

test("a Markdown buffer made with its text gets the look when it's first shown", function(t)
	t:buffer("|x")
	local buffer = greed.create_buffer(
		"file",
		"# Questions\n\n- ( ) one\n- ( ) two\n",
		{ language = "markdown" }
	)
	assert(#buffer:decorations("markdown") == 0, "nothing drawn before it shows")
	greed.float(buffer, { title = "page", width = 40, height = 8, focus = false })
	t:draw(60, 12)
	assert(#buffer:decorations("markdown") > 0, "drawn once a view shows it")
end)

test("bold holding code, brackets or a comma after it shows without its stars", function(t)
	local rows =
		shown(t, "- **Highlights TODO (yellow), NOTE (blue)**, bold\n**`github-dashboard`** plugin")
	assert(rows[1] == "• Highlights TODO (yellow), NOTE (blue), bold", rows[1])
	assert(rows[2] == "github-dashboard plugin", rows[2])
end)

test("a long bold line that wraps, indented as a transcript has it", function(t)
	local rows = shown(
		t,
		"  - **Highlights `TODO` (yellow), `FIXME` (red), `NOTE` (blue)**, bold, in every buffer — whole words only, so `todos` or `UNTODOED` don't light up."
	)
	assert(not string.find(rows[1], "**", 1, true), rows[1] .. "\n" .. rows[2])
end)

test("another plugin's marks inside bold leave its stars hidden", function(t)
	shown(t, "a **b TODO c** d")
	local buffer = greed.view():buffer()
	local at = (string.find(buffer:text(), "TODO", 1, true) :: number) - 1
	buffer:decorate("other", { { from = at, to = at + 4, style = "keyword" } })
	local rows = t:draw(60, 12)
	assert(rows[1] == "a b TODO c d", rows[1])
end)

local QUESTIONS = table.concat({
	"Will you use agents? <!-- id=agents -->",
	"",
	"- (x) Yes: they help",
	"- ( ) No",
	"",
	"<!-- if agents=yes -->",
	"Which model? <!-- id=provider -->",
	"",
	"- (x) Ollama: on this machine <!-- value=local -->",
	"- ( ) Anthropic",
	"<!-- end -->",
	"",
	"<!-- if agents!=yes -->",
	"Nothing more to ask.",
	"<!-- end -->",
	"",
	"done",
}, "\n")

test("named questions have answers, values from their text or a comment", function(t)
	shown(t, QUESTIONS)
	local buffer = greed.view():buffer()
	local groups = markdown.choices.list(buffer)
	assert(
		groups[1].id == "agents" and groups[1].question == "Will you use agents?",
		groups[1].question
	)
	assert(groups[1].options[1].value == "Yes" and groups[1].options[1].text == "Yes: they help")
	assert(groups[2].options[1].value == "local", groups[2].options[1].value)
	assert(groups[2].options[1].text == "Ollama: on this machine", groups[2].options[1].text)
	local answers = markdown.questions.answers(buffer)
	assert(answers.agents == "Yes" and answers.provider == "local", greed.json.encode(answers))
end)

test("a part shows only for the answers it names, and its questions count only then", function(t)
	local rows = table.concat(shown(t, QUESTIONS), "\n")
	assert(string.find(rows, "Which model?", 1, true), rows)
	assert(not string.find(rows, "Nothing more to ask", 1, true), rows)
	assert(not string.find(rows, "<!--", 1, true), "comments don't show: " .. rows)
	local buffer = greed.view():buffer()
	markdown.choices.pick(buffer, 3)
	local answers = markdown.questions.answers(buffer)
	assert(answers.agents == "No" and answers.provider == nil, greed.json.encode(answers))
	rows = table.concat(t:draw(60, 14), "\n")
	assert(not string.find(rows, "Which model?", 1, true), rows)
	assert(string.find(rows, "Nothing more to ask", 1, true), rows)
end)

test("a part can name several answers, and shows for any of them", function(t)
	shown(
		t,
		table.concat({
			"Style? <!-- id=style -->",
			"",
			"- ( ) vim",
			"- (x) helix",
			"- ( ) vscode",
			"",
			"<!-- if style=vim,helix -->",
			"modal",
			"<!-- end -->",
			"<!-- if style!=vim,helix -->",
			"modeless",
			"<!-- end -->",
		}, "\n")
	)
	local buffer = greed.view():buffer()
	local hidden = markdown.questions.state(buffer)
	assert(not hidden[7] and hidden[10], "helix is modal")
	markdown.choices.pick(buffer, 4)
	hidden = markdown.questions.state(buffer)
	assert(hidden[7] and not hidden[10], "vscode is modeless")
end)
