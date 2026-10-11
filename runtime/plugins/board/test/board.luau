local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")
local shell = require("@shell")
local blocks = require("@blocks")
local board = require("@board")

local OPS = [[
# ops

Some words about it, which aren't cards.

## files

```sh title="the list" height=2
printf 'a\nb\nc\nd\n'
```

```sh every=5 dir=sub
pwd
```

## other

```luau
print("not a card")
```

```sh live
echo live
```
]]

test("a board's file is its title, its sections and a card for each shell block", function()
	local parsed = board.file.parse(OPS)
	assert(parsed.title == "ops", parsed.title)
	assert(#parsed.cards == 3, tostring(#parsed.cards))
	local list = parsed.cards[1]
	assert(list.title == "the list" and list.height == 2 and list.every == nil)
	assert(list.command == "printf 'a\\nb\\nc\\nd\\n'" and list.section == "files", list.command)
	local here = parsed.cards[2]
	assert(here.every == 5 and here.dir == "sub" and here.title == "pwd" and here.height == 10)
	local live = parsed.cards[3]
	assert(live.every == 2 and live.section == "other", tostring(live.every))
end)

test("a card's text, and a watch as a card", function()
	local text =
		board.file.card_text("kubectl get pods", { every = 5, title = "the pods", dir = "infra" })
	assert(text == '```sh every=5 title="the pods" dir=infra\nkubectl get pods\n```\n', text)
	local card = board.file.parse(text).cards[1]
	assert(card.command == "kubectl get pods" and card.every == 5 and card.title == "the pods")
	local line, every = board.file.unwatched("watch -n 3 df -h")
	assert(line == "df -h" and every == 3, line)
	assert(board.file.unwatched("df -h") == "df -h")
end)

-- A board at `ops.md` in a folder of its own, trusted, with a `sub` folder.
local function make(t: test.TestContext, text: string): (string, string)
	local dir = t:tempdir({ ["ops.md"] = text, ["sub/keep"] = "" })
	local path = `{dir}/ops.md`
	blocks.trust(path)
	return dir, path
end

local function text(): string
	return greed.view():buffer():text()
end

local function settled(t: test.TestContext, b: board.Board)
	t:wait_for(function()
		for _, block in b.blocks do
			if block.watching == nil and block.status == "running" then
				return false
			end
			if block.output == "" then
				return false
			end
		end
		return true
	end)
end

test("a board shows each card's output, cut at its height, under its section", function(t)
	local dir, path = make(t, OPS)
	local b = assert(board.open(path, { root = dir }))
	settled(t, b)
	local shown = text()
	assert(string.find(shown, "^ops\n"), shown)
	assert(string.find(shown, "files\n\n✓ the list", 1, true), shown)
	assert(string.find(shown, "\na\nb\n… 2 more lines", 1, true), shown)
	assert(string.find(shown, `\n{dir}/sub\n`, 1, true), "dir runs it in a folder: " .. shown)
	assert(
		string.find(shown, "other\n", 1, true) and string.find(shown, "\nlive\n", 1, true),
		shown
	)
	assert(not string.find(shown, "not a card", 1, true), shown)
	-- The board's shell is out of sight, and goes with it.
	local sh = b.shell
	assert(#sh.buffer:views() == 0, "its shell isn't shown")
	-- enter on a card opens its block in a float.
	greed.view():set_cursor(assert((string.find(shown, "\nb\n", 1, true))))
	t:keys("esc enter")
	assert(#t:floats() == 1, "a float")
	t:keys("esc")
	-- It stays while something else shows, until it's closed.
	greed.view():show(greed.create_buffer("text", ""))
	assert(b.buffer:valid(), "it stays")
	b.buffer:close()
	t:wait_for(function()
		return not sh.buffer:valid()
	end)
	for _, block in b.blocks do
		assert(block.status ~= "running", "it stops what ran")
	end
end)

test("saving a board's file shows the board as it says, in the blocks it had", function(t)
	local dir, path = make(t, "# ops\n\n```sh\necho one\n```\n\n```sh\necho two\n```\n")
	local b = assert(board.open(path, { root = dir }))
	settled(t, b)
	local first = b.blocks[1]
	t:run("board-edit")
	local source = greed.view():buffer()
	assert(source:path() == path, tostring(source:path()))
	source:edit(function(e)
		e:replace(0, source:len(), "# ops\n\n```sh\necho three\n```\n")
	end)
	source:save()
	t:wait_for(function()
		return #b.blocks == 1 and string.find(b.buffer:text(), "three", 1, true) ~= nil
	end)
	assert(b.blocks[1] == first, "the same block")
	t:wait_for(function()
		return #b.shell.blocks == 1
	end)
end)

test("a board from a file you didn't trust asks before it runs anything", function(t)
	local dir = t:tempdir({ ["ops.md"] = "```sh\necho hi\n```\n" })
	local opened: board.Board? = nil
	local done = false
	greed.spawn(function()
		opened = board.open(`{dir}/ops.md`, { root = dir })
		done = true
	end)
	t:wait_for(function()
		local said = t:messages()
		return string.find(said[#said] or "", "run the commands from", 1, true) ~= nil
	end)
	t:keys("n")
	t:wait_for(function()
		return done
	end)
	assert(opened == nil, "nothing ran")
end)

test("a shell block pinned to a board becomes a card; space a adds one there", function(t)
	local dir, path = make(t, "# ops\n")
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = `{dir}/sub`
	local block = assert(shell.run(sh, "watch -n 4 ls"))
	shell.interrupt(block)
	t:wait_for(function()
		return block.status ~= "running"
	end)
	local object = assert(core.objects.get(`shell-block:{sh.buffer:id()}.{block.number}`))
	-- The project's root is where boards are, so pick the one at `path`.
	local listed = board.list
	board.list = function()
		return { { name = "ops", path = path } }
	end
	core.objects.act(object, "pin to board")
	t:keys("o p s enter")
	board.list = listed
	local saved = greed.fs.read(path) or ""
	assert(string.find(saved, "```sh every=4 dir=", 1, true), saved)
	assert(string.find(saved, "\nls\n```\n", 1, true), saved)
	local b = assert(board.open(path, { root = dir }))
	t:wait_for(function()
		return b.blocks[1].output ~= ""
	end)
	t:keys("esc space a")
	t:keys("e c h o space a d d e d enter")
	t:wait_for(function()
		return string.find(b.buffer:text(), "\nadded", 1, true) ~= nil
	end)
	assert((string.find(greed.fs.read(path) or "", "```sh\necho added\n```\n", 1, true)))
end)

local function piece(name: string, lines: { string }, section: string?, span: number?): any
	return { head = name, title = #name, lines = lines, section = section, span = span or 1 }
end

test("cards lie side by side as the board is wide enough, a section starting a row", function()
	local lay = board.layout.lay
	assert(board.layout.columns(80, 30) == 2 and board.layout.columns(61, 30) == 1)
	local laid = lay("ops", {
		piece("one", { "a", "b" }, "s"),
		piece("two", { "a much longer line than fits" }, "s"),
		piece("three", {}, "s"),
		piece("four", { "x" }, "t"),
	}, 40, 15)
	local expected = table.concat({
		"ops",
		"",
		"s",
		"",
		"one                  two",
		"a                    a much longer line…",
		"b",
		"",
		"three",
		"",
		"t",
		"",
		"four",
		"x",
		"",
	}, "\n")
	assert(laid.text == expected, "\n" .. laid.text)
	-- What's on each line, for the cursor.
	assert(board.layout.card(laid.at[4], 0) == 1 and board.layout.card(laid.at[4], 21) == 2)
	assert(board.layout.card(laid.at[4], 20) == 1, "in the gap, the one to the left")
	assert(board.layout.card(laid.at[8], 0) == 3 and laid.at[2] == nil)
	-- A wide card takes the whole row, and span columns at most all of them.
	local wide =
		lay(nil, { piece("one", {}, nil, 0), piece("two", {}), piece("three", {}, nil, 5) }, 40, 15)
	assert(wide.text == "one\n\ntwo\n\nthree\n", "\n" .. wide.text)
end)

test("on a wide view cards show side by side, and < and > move them, in the file too", function(t)
	local dir, path = make(t, "# ops\n\n```sh\necho first\n```\n\n```sh\necho second\n```\n")
	local b = assert(board.open(path, { root = dir }))
	settled(t, b)
	t:draw(120, 30)
	t:wait_for(function()
		return b.width == 120
	end)
	settled(t, b)
	local shown = b.buffer:text()
	assert(string.find(shown, "\nfirst%s+second\n"), shown)
	local first = b.blocks[1]
	-- On the second card, < takes it before the first.
	greed.view():set_cursor(assert((string.find(shown, "second", 1, true))) - 1)
	t:keys("esc <")
	local saved = greed.fs.read(path) or ""
	assert(string.find(saved, "echo second\n```\n\n```sh\necho first", 1, true), saved)
	assert(b.cards[1].command == "echo second", b.cards[1].command)
	assert(b.blocks[2] == first, "it kept its block, without running it again")
	local line = b.buffer:slice(greed.view():cursor(), greed.view():cursor() + 20)
	assert(string.find(line, "second", 1, true), "the cursor went with it: " .. line)
	t:keys(">")
	assert(b.cards[2].command == "echo second", "and back")
end)

test("a card with chart is drawn as a chart as big as the card", function(t)
	local parsed =
		board.file.parse('```sh chart="bar 2" height=4\nprintf "a 1 3\\nb 2 1\\n"\n```\n')
	assert(parsed.cards[1].chart == "bar 2", tostring(parsed.cards[1].chart))
	assert(board.file.parse("```sh chart\nx\n```\n").cards[1].chart == "")
	local dir, path = make(t, '# ops\n\n```sh chart height=3\nprintf "a 1\\nb 3\\n"\n```\n')
	local b = assert(board.open(path, { root = dir }))
	settled(t, b)
	local block = b.blocks[1]
	assert(string.find(block.command, "| chart  --width 80 --height 3", 1, true), block.command)
	t:wait_for(function()
		return string.find(b.buffer:text(), "█", 1, true) ~= nil
	end)
	local shown = b.buffer:text()
	assert(string.find(shown, "\nb █", 1, true) and string.find(shown, "█ 3\n", 1, true), shown)
end)

test("i on a card opens the board's file at that card's command", function(t)
	local dir, path = make(t, "# ops\n\n```sh\necho one\n```\n\n```sh every=2\necho two\n```\n")
	local b = assert(board.open(path, { root = dir }))
	settled(t, b)
	local shown = b.buffer:text()
	greed.view():set_cursor(assert((string.find(shown, "echo two", 1, true))) - 1)
	t:keys("esc i")
	local file = greed.view():buffer()
	assert(file:path() == path, tostring(file:path()))
	local line = file:line_of(greed.view():cursor())
	assert(file:slice(file:line_start(line), file:line_end(line)) == "echo two")
end)

test("from a card's place in the file, jumping back goes to the board", function(t)
	local dir, path = make(t, "# ops\n\n```sh\necho one\n```\n")
	local b = assert(board.open(path, { root = dir }))
	settled(t, b)
	greed.view():set_cursor(assert((string.find(b.buffer:text(), "one", 1, true))) - 1)
	t:keys("esc i")
	assert(greed.view():buffer():path() == path)
	local said = t:messages()
	assert(
		said[#said] == "saving puts your changes on the board; ctrl-o goes back to it",
		said[#said]
	)
	t:keys("esc ctrl-o")
	assert(greed.view():buffer() == b.buffer, tostring(greed.view():buffer():path()))
end)
