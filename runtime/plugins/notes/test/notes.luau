local test = require("@greed/test")
local greed = require("@greed")
local agent = require("@agent")

-- A notes folder of the test's own, holding `files`. Returns its path.
local function folder(t: test.TestContext, files: { [string]: string }?): string
	local dir = t:tempdir(files)
	greed.option.set("notes-folder", dir)
	return dir
end

local function concealed(): number
	local n = 0
	for _, mark in greed.view():buffer():decorations("notes") do
		if mark.conceal then
			n += 1
		end
	end
	return n
end

local function run_tool(name: string, args: { [string]: any }?): any
	for _, tool in agent.tools() do
		if tool.name == name then
			return tool.run(args or {})
		end
	end
	error(`no tool {name}`)
end

test("links in notes hide their brackets; other Markdown is left alone", function(t)
	local dir = folder(t, { ["a.md"] = "see [[b]] and [[c|the c note]]\n" })
	greed.open(dir .. "/a.md")
	t:wait(10)
	assert(concealed() == 4, "two marks per link, got " .. concealed())

	local elsewhere = t:tempdir({ ["README.md"] = "see [[b]]\n" })
	greed.open(elsewhere .. "/README.md")
	t:wait(10)
	assert(concealed() == 0, "not a note")
	greed.option.set("notes-everywhere", true)
	assert(concealed() == 2, "with notes-everywhere it is")
	greed.option.set("notes-everywhere", false)
end)

test("g d follows a link, making the note; elsewhere it goes to the definition", function(t)
	local dir = folder(t, { ["a.md"] = "see [[ideas]] here\n" })
	greed.open(dir .. "/a.md")
	t:keys("w w")
	t:keys("g d")
	assert(greed.view():buffer():path() == dir .. "/ideas.md", greed.view():buffer():path())
	t:keys("i n e w esc")
	t:run("save")
	assert(greed.fs.read(dir .. "/ideas.md") == "new")
	greed.open(dir .. "/a.md")
	t:keys("g g g d")
	local messages = t:messages()
	assert(string.find(messages[#messages], "language server", 1, true), messages[#messages])
end)

test("a note lists the notes linking to it at its end", function(t)
	local dir =
		folder(t, { ["a.md"] = "about [[b]]\n", ["c.md"] = "[[b|bee]] too\n", ["b.md"] = "b\n" })
	greed.open(dir .. "/b.md")
	t:wait(10)
	local lines = nil
	for _, mark in greed.view():buffer():decorations("notes") do
		lines = mark.lines or lines
	end
	assert(lines, "backlinks shown")
	local text = table.concat(lines :: { string }, "\n")
	assert(string.find(text, "[[a]]", 1, true) and string.find(text, "[[c]]", 1, true), text)
end)

test("space n x ticks a todo, unticks it, and makes a line a todo", function(t)
	folder(t)
	t:buffer("|- [ ] call\nplain\n- item")
	t:keys("space n x")
	t:expect("|- [x] call\nplain\n- item")
	t:keys("space n x")
	t:expect("|- [ ] call\nplain\n- item")
	t:keys("j space n x j space n x")
	assert(
		greed.view():buffer():text() == "- [ ] call\n- [ ] plain\n- [ ] item",
		greed.view():buffer():text()
	)
end)

test("the agenda lists open todos from every note, soonest due first", function(t)
	folder(t, {
		["work.md"] = "- [ ] later due:2026-12-01\n- [x] done already due:2026-01-01\n",
		["home.md"] = "- [ ] soon due:2026-10-02\n- [ ] someday\n",
	})
	t:buffer("|x")
	t:keys("space n a")
	local lines = string.split(greed.view():buffer():text(), "\n")
	assert(string.find(lines[2], "soon", 1, true), lines[2])
	assert(string.find(lines[3], "later", 1, true), lines[3])
	assert(string.find(lines[4], "someday", 1, true), lines[4])
	assert(
		lines[5] == nil or not string.find(lines[5], "done already", 1, true),
		"done ones are left out"
	)
	t:keys("enter")
	assert((string.find(greed.view():buffer():path() or "", "home.md", 1, true)))
end)

test("capture adds a todo to the inbox, and the daily note is made on first use", function(t)
	local dir = folder(t)
	t:buffer("|x")
	t:keys("space n c")
	for _, char in string.split("buy milk", "") do
		t:keys(if char == " " then "space" else char)
	end
	t:keys("enter")
	assert(
		greed.fs.read(dir .. "/inbox.md") == "- [ ] buy milk\n",
		(greed.fs.read(dir .. "/inbox.md"))
	)
	t:keys("space n d")
	local today = os.date("%Y-%m-%d")
	assert(greed.view():buffer():path() == `{dir}/daily/{today}.md`, greed.view():buffer():path())
	assert(greed.view():buffer():text() == `# {today}\n\n`)
end)

test("z a folds the section under the cursor, and again unfolds it", function(t)
	t:buffer("# A\non|e\ntwo\n# B\nb")
	greed.view():buffer():set_language("markdown")
	t:keys("z a")
	t:expect("|# A\none\ntwo\n# B\nb")
	local hidden = greed.view():hidden_lines()
	assert(#hidden == 1 and hidden[1].from == 1 and hidden[1].to == 2, "the section's lines")
	t:keys("j")
	t:expect("# A\none\ntwo\n|# B\nb")
	t:keys("k z a")
	assert(#greed.view():hidden_lines() == 0, "unfolded")
end)

test("agents can list, search, read and write notes and their todos", function(t)
	local dir = folder(t, { ["a.md"] = "alpha [[b]]\n", ["b.md"] = "beta\n" })
	assert(table.concat(run_tool("notes_list"), ",") == "a,b")
	local found = run_tool("notes_search", { pattern = "bet" })
	assert(#found == 1 and found[1].note == "b" and found[1].line == 1)
	local read = run_tool("notes_read", { name = "b" })
	assert(read.text == "beta\n" and read.linked_from[1] == "a")
	run_tool("notes_write", { name = "c", text = "gamma\n" })
	run_tool("notes_write", { name = "c", text = "more", append = true })
	assert(greed.fs.read(dir .. "/c.md") == "gamma\nmore\n", (greed.fs.read(dir .. "/c.md")))
	run_tool("notes_add_todo", { text = "ship it", due = "2026-10-05" })
	local open = run_tool("notes_todos")
	assert(#open == 1 and open[1].text == "ship it due:2026-10-05" and open[1].due == "2026-10-05")
	assert(not pcall(run_tool, "notes_read", { name = "nope" }), "a missing note fails")
end)

-- A note open with `text` and the cursor on its last line, drawn without
-- line numbers. Returns the rows.
local function shown(t: test.TestContext, text: string): { string }
	local dir = folder(t, { ["plans.md"] = text })
	greed.open(`{dir}/plans.md`)
	local view = greed.view()
	view:buffer():set_line_numbers(false)
	local last = view:buffer():len()
	view:set_selection({ ranges = { { anchor = last, head = last } }, primary = 1 })
	return t:draw(50, 8)
end

test("markup in notes shows as symbols, as written only while typing on its line", function(t)
	local rows =
		shown(t, "# Plans\n- [ ] call the bank due:2020-01-01\n- [x] pay rent\n- milk\n- [ ] here")
	assert(rows[1] == "◉ Plans", rows[1])
	assert(rows[2] == "☐ call the bank 📅 1 Jan 2020", rows[2])
	assert(rows[3] == "☑ pay rent", rows[3])
	assert(rows[4] == "• milk", rows[4])
	assert(rows[5] == "☐ here", `the cursor's line too, in normal mode: {rows[5]}`)
	t:keys("i")
	assert(t:draw(50, 8)[5] == "- [ ] here", "typing on it shows it as written")
	assert(t:draw(50, 8)[2] == "☐ call the bank 📅 1 Jan 2020", "other lines stay")
	t:keys("esc")
	assert(t:draw(50, 8)[5] == "☐ here", "and back")
	local styles: { [string]: boolean } = {}
	for _, mark in greed.view():buffer():decorations("notes-look") do
		styles[mark.style] = true
	end
	assert(styles["notes.overdue"] and styles["notes.done"], "overdue and done have their styles")
end)

test("clicking a todo's box ticks it, and it stays a box", function(t)
	shown(t, "- [ ] call the bank\n\n")
	t:mouse("press", 0, 0)
	local text = greed.view():buffer():text()
	assert(string.sub(text, 1, 6) == "- [x] ", text)
	local row = t:draw(50, 8)[1]
	assert(row == "☑ call the bank", row)
end)

test("enter on a todo's box ticks it", function(t)
	shown(t, "- [ ] call the bank\n")
	greed.view():set_selection({ ranges = { { anchor = 2, head = 2 } }, primary = 1 })
	t:keys("enter")
	local text = greed.view():buffer():text()
	assert(string.sub(text, 1, 6) == "- [x] ", text)
	assert(t:draw(50, 8)[1] == "☑ call the bank")
end)

test("without modes, markup shows once the cursor is inside it", function(t)
	shown(t, "- [ ] call the bank\n")
	greed.mode.set("edit")
	local function at(pos: number): string
		greed.view():set_selection({ ranges = { { anchor = pos, head = pos } }, primary = 1 })
		return t:draw(50, 8)[1]
	end
	assert(at(0) == "☐ call the bank", "at its start, where a click puts it")
	assert(at(3) == "- [ ] call the bank", "inside it")
	assert(at(10) == "☐ call the bank", "elsewhere on the line")
end)

test("symbols can change and rules of your own add styles and symbols", function(t)
	local notes = require("@notes")
	notes.symbols({ todo = "o", bullet = "-" })
	notes.rule({ pattern = "#[%w_-]+", style = "notes.tag" })
	notes.rule({ pattern = "!!", show = "(!)", style = "notes.urgent" })
	local rows = shown(t, "- [ ] ring #home !!\n- milk\n")
	assert(rows[1] == "o ring #home (!)", rows[1])
	assert(rows[2] == "- milk", rows[2])
	local tagged = false
	local buffer = greed.view():buffer()
	for _, mark in buffer:decorations("notes-look") do
		tagged = tagged
			or (mark.style == "notes.tag" and buffer:slice(mark.from, mark.to) == "#home")
	end
	assert(tagged, "the tag is styled")
	notes.symbols({ todo = "☐", bullet = "•" })
end)
