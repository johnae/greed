local test = require("@kern/test")
local kern = require("@kern")
local agent = require("@agent")

-- A notes folder of the test's own, holding `files`. Returns its path.
local function folder(t: test.TestContext, files: { [string]: string }?): string
	local dir = t:tempdir(files)
	kern.option.set("notes-folder", dir)
	return dir
end

local function concealed(): number
	local n = 0
	for _, mark in kern.view():buffer():decorations("notes") do
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
	kern.open(dir .. "/a.md")
	t:wait(10)
	assert(concealed() == 4, "two marks per link, got " .. concealed())

	local elsewhere = t:tempdir({ ["README.md"] = "see [[b]]\n" })
	kern.open(elsewhere .. "/README.md")
	t:wait(10)
	assert(concealed() == 0, "not a note")
	kern.option.set("notes-everywhere", true)
	assert(concealed() == 2, "with notes-everywhere it is")
	kern.option.set("notes-everywhere", false)
end)

test("g d follows a link, making the note; elsewhere it goes to the definition", function(t)
	local dir = folder(t, { ["a.md"] = "see [[ideas]] here\n" })
	kern.open(dir .. "/a.md")
	t:keys("w w")
	t:keys("g d")
	assert(kern.view():buffer():path() == dir .. "/ideas.md", kern.view():buffer():path())
	t:keys("i n e w esc")
	t:run("save")
	assert(kern.fs.read(dir .. "/ideas.md") == "new")
	kern.open(dir .. "/a.md")
	t:keys("g g g d")
	local messages = t:messages()
	assert(string.find(messages[#messages], "language server", 1, true), messages[#messages])
end)

test("a note lists the notes linking to it at its end", function(t)
	local dir =
		folder(t, { ["a.md"] = "about [[b]]\n", ["c.md"] = "[[b|bee]] too\n", ["b.md"] = "b\n" })
	kern.open(dir .. "/b.md")
	t:wait(10)
	local lines = nil
	for _, mark in kern.view():buffer():decorations("notes") do
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
		kern.view():buffer():text() == "- [ ] call\n- [ ] plain\n- [ ] item",
		kern.view():buffer():text()
	)
end)

test("the agenda lists open todos from every note, soonest due first", function(t)
	folder(t, {
		["work.md"] = "- [ ] later due:2026-12-01\n- [x] done already due:2026-01-01\n",
		["home.md"] = "- [ ] soon due:2026-10-02\n- [ ] someday\n",
	})
	t:buffer("|x")
	t:keys("space n a")
	local lines = string.split(kern.view():buffer():text(), "\n")
	assert(string.find(lines[2], "soon", 1, true), lines[2])
	assert(string.find(lines[3], "later", 1, true), lines[3])
	assert(string.find(lines[4], "someday", 1, true), lines[4])
	assert(
		lines[5] == nil or not string.find(lines[5], "done already", 1, true),
		"done ones are left out"
	)
	t:keys("enter")
	assert((string.find(kern.view():buffer():path() or "", "home.md", 1, true)))
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
		kern.fs.read(dir .. "/inbox.md") == "- [ ] buy milk\n",
		(kern.fs.read(dir .. "/inbox.md"))
	)
	t:keys("space n d")
	local today = os.date("%Y-%m-%d")
	assert(kern.view():buffer():path() == `{dir}/daily/{today}.md`, kern.view():buffer():path())
	assert(kern.view():buffer():text() == `# {today}\n\n`)
end)

test("z a folds the section under the cursor, and again unfolds it", function(t)
	t:buffer("# A\non|e\ntwo\n# B\nb")
	t:keys("z a")
	t:expect("|# A\none\ntwo\n# B\nb")
	local hidden = kern.view():hidden_lines()
	assert(#hidden == 1 and hidden[1].from == 1 and hidden[1].to == 2, "the section's lines")
	t:keys("j")
	t:expect("# A\none\ntwo\n|# B\nb")
	t:keys("k z a")
	assert(#kern.view():hidden_lines() == 0, "unfolded")
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
	assert(kern.fs.read(dir .. "/c.md") == "gamma\nmore\n", (kern.fs.read(dir .. "/c.md")))
	run_tool("notes_add_todo", { text = "ship it", due = "2026-10-05" })
	local open = run_tool("notes_todos")
	assert(#open == 1 and open[1].text == "ship it due:2026-10-05" and open[1].due == "2026-10-05")
	assert(not pcall(run_tool, "notes_read", { name = "nope" }), "a missing note fails")
end)
