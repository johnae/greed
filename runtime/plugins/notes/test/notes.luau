local test = require("@greed/test")
local greed = require("@greed")
local agent = require("@agent")

-- A notes folder of the test's own, holding `files`. Returns its path.
-- The project's notes go in a folder of the test's own too, one that isn't
-- there, so nothing lands in the project the tests run in.
local function folder(t: test.TestContext, files: { [string]: string }?): string
	local dir = t:tempdir(files)
	greed.option.set("notes-folder", dir)
	greed.option.set("notes-project-folder", `{dir}/.no-project-notes`)
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
			return tool.run(args or {}, agent.caller())
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

test("+ items are bullets too, and code blocks keep their markup", function(t)
	local rows = shown(t, "+ milk\n```sh\n# comment\n- [ ] not a todo\n```\n- eggs")
	assert(rows[1] == "• milk", rows[1])
	assert(rows[3] == "# comment", `no heading in code: {rows[3]}`)
	assert(rows[4] == "- [ ] not a todo", `no box in code: {rows[4]}`)
	assert(rows[6] == "• eggs", rows[6])
end)

test("a fence typed above makes the lines after it code, and taking it out undoes that", function(t)
	shown(t, "intro\n\n# Plans\n- [ ] call\n\n- milk")
	local buffer = greed.view():buffer()
	buffer:edit(function(e)
		e:insert(6, "```\n")
	end)
	local rows = t:draw(50, 8)
	assert(rows[4] == "# Plans" and rows[5] == "- [ ] call" and rows[7] == "- milk", rows[4])
	buffer:edit(function(e)
		e:delete(6, 10)
	end)
	rows = t:draw(50, 8)
	assert(rows[3] == "◉ Plans" and rows[4] == "☐ call" and rows[6] == "• milk", rows[3])
end)

test("todos in code blocks aren't todos", function(t)
	folder(t, { ["a.md"] = "- [ ] real\n```\n- [ ] example\n```\n+ [ ] plus\n" })
	local texts: { string } = {}
	for _, todo in run_tool("notes_todos") do
		table.insert(texts, todo.text)
	end
	table.sort(texts)
	assert(#texts == 2 and texts[1] == "plus" and texts[2] == "real", table.concat(texts, ", "))
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
	greed.mode.set("vscode")
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

-- Your notes in one folder and the project's in another.
local function places(
	t: test.TestContext,
	mine: { [string]: string },
	project: { [string]: string }
): (string, string)
	local dir = folder(t, mine)
	local project_dir = t:tempdir(project)
	greed.option.set("notes-project-folder", project_dir)
	return dir, project_dir
end

test("the project's notes are named project:NAME and listed with yours", function(t)
	local _, project_dir = places(
		t,
		{ ["ideas.md"] = "mine\n" },
		{ ["plan.md"] = "- [ ] ship it\n" }
	)
	local all = table.concat(require("@notes").all(), " ")
	assert(all == "ideas project:plan", all)
	assert(
		run_tool("notes_read", { name = "project:plan" }).text == "- [ ] ship it\n",
		"read by name"
	)
	assert(require("@notes").path("project:plan") == `{project_dir}/plan.md`, "its file")
	greed.open(`{project_dir}/plan.md`)
	assert(require("@notes").is_note(greed.view():buffer()), "a note")
end)

test("todos and search cover every place", function(t)
	places(t, { ["inbox.md"] = "- [ ] call the bank\n" }, { ["plan.md"] = "- [ ] ship it\n" })
	local found = {}
	for _, todo in run_tool("notes_todos") do
		table.insert(found, `{todo.note}: {todo.text}`)
	end
	table.sort(found)
	assert(
		table.concat(found, ", ") == "inbox: call the bank, project:plan: ship it",
		table.concat(found, ", ")
	)
	local hits = run_tool("notes_search", { pattern = "ship" })
	assert(#hits == 1 and hits[1].note == "project:plan", tostring(#hits))
end)

test("capture goes to the project's inbox when it keeps notes, otherwise yours", function(t)
	local dir, project_dir = places(t, {}, {})
	run_tool("notes_add_todo", { text = "for the project" })
	assert(greed.fs.read(`{project_dir}/inbox.md`) == "- [ ] for the project\n", "the project's")
	greed.option.set("notes-project-folder", project_dir .. "/missing")
	run_tool("notes_add_todo", { text = "for me" })
	assert(greed.fs.read(`{dir}/inbox.md`) == "- [ ] for me\n", "mine")
end)

test("a link goes to its own place first, and backlinks find it", function(t)
	places(t, { ["ideas.md"] = "mine\n", ["shared.md"] = "personal\n" }, {
		["plan.md"] = "see [[design]] and [[ideas]] and [[project:design]]\n",
		["design.md"] = "the design\n",
	})
	local notes = require("@notes")
	assert(notes.resolve("design", "project:plan") == "project:design", "same place")
	assert(notes.resolve("ideas", "project:plan") == "ideas", "only in yours")
	assert(notes.resolve("new", "project:plan") == "project:new", "a new one is made beside it")
	assert(notes.resolve("design", "ideas") == "design", "from yours, yours")
	local back = run_tool("notes_read", { name = "project:design" }).linked_from
	assert(#back == 1 and back[1] == "project:plan", table.concat(back, " "))
end)

test("places added in the config are searched and named too", function(t)
	places(t, {}, {})
	local work = t:tempdir({ ["meeting.md"] = "- [ ] send notes\n" })
	require("@notes").add_place("work", work)
	assert(
		table.concat(require("@notes").all(), " ") == "work:meeting",
		table.concat(require("@notes").all(), " ")
	)
	assert(run_tool("notes_todos")[1].note == "work:meeting", "its todos")
end)

test("space n t jots a thought down in the inbox, with today's date", function(t)
	local dir = folder(t)
	t:buffer("|x")
	t:keys("space n t")
	for _, char in string.split("rope for undo", "") do
		t:keys(if char == " " then "space" else char)
	end
	t:keys("enter")
	local today = os.date("%Y-%m-%d")
	local text = greed.fs.read(dir .. "/inbox.md")
	assert(text == `- rope for undo ({today})\n`, text)
end)

-- The date `days` from today, and with `time` the minute `seconds` from now.
local function day(days: number): string
	return os.date("%Y-%m-%d", os.time() + days * 86400) :: string
end
local function minute(seconds: number): string
	return os.date("%Y-%m-%d %H:%M", os.time() + seconds) :: string
end

-- Whether a float shows text with `text` in it.
local function floating(t: test.TestContext, text: string): boolean
	for _, shown in t:floats() do
		if string.find(shown, text, 1, true) then
			return true
		end
	end
	return false
end

test(
	"a reminder that came due shows until dismissed, goes to the desktop, and only once",
	function(t)
		greed.option.set("notes-remind-desktop", false)
		folder(t, {
			["inbox.md"] = `- [ ] call the bank remind:{minute(-3600)}\n`
				.. `- [x] ticked remind:{minute(-3600)}\n`
				.. `- [ ] later remind:{minute(7200)}\n`
				.. `plain line remind:{minute(-60)}\n`,
		})
		t:buffer("|x")
		t:wait(61000)
		assert(
			floating(t, "call the bank") and floating(t, "plain line"),
			table.concat(t:floats(), "|")
		)
		assert(
			not floating(t, "ticked") and not floating(t, "later"),
			table.concat(t:floats(), "|")
		)
		local notices = t:notices()
		assert(#notices == 1 and notices[1].title == "2 reminders", tostring(#notices))
		assert(notices[1].body == "call the bank\nplain line", notices[1].body)
		local record = greed.fs.read(`{greed.fs.dirs().cache}/notes-reminders`) or ""
		assert(string.find(record, "call the bank", 1, true), record)
		t:keys("space n r")
		assert(not floating(t, "call the bank"), "dismissed")
		t:wait(61000)
		assert(#t:notices() == 0 and not floating(t, "call the bank"), "once")
	end
)

test("a reminder with only a date goes off at notes-remind-time", function(t)
	greed.option.set("notes-remind-desktop", false)
	local now = os.date("*t") :: any
	-- A minute that has passed today, or the first one.
	local past = string.format("%02d:%02d", now.hour, math.max(now.min - 1, 0))
	greed.option.set("notes-remind-time", past)
	folder(t, { ["inbox.md"] = `- [ ] water the plants remind:{day(0)}\n` })
	t:buffer("|x")
	t:wait(61000)
	assert(floating(t, "water the plants"), "it went off")
	greed.option.set("notes-remind-time", "09:00")
end)

test("saving a note with a reminder that's due shows it at once; clicking it opens it", function(t)
	greed.option.set("notes-remind-desktop", false)
	local dir = folder(t, { ["work.md"] = "# Work\n" })
	greed.open(dir .. "/work.md")
	local buffer = greed.view():buffer()
	buffer:edit(function(e)
		e:insert(buffer:len(), `- [ ] send the report remind:{minute(-120)}\n`)
	end)
	t:run("save")
	assert(floating(t, "send the report"), "shown on save")
	t:draw(100, 20)
	-- Its first line, at the top right, inside the border.
	t:mouse("press", 97, 1)
	t:wait(10)
	assert(not floating(t, "send the report"), "the notice closed")
	local view = greed.view()
	assert(view:buffer():path() == dir .. "/work.md", view:buffer():path())
	local selection = view:selection()
	assert(view:buffer():line_of(selection.ranges[1].head) == 1, "on the reminder's line")
end)

test("the status line counts what's due today, warns of overdue, and opens the agenda", function(t)
	folder(t, {
		["a.md"] = `- [ ] pay rent due:{day(0)}\n- [ ] renew due:{day(-2)}\n- [ ] later due:{day(5)}\n`,
	})
	t:buffer("|x")
	t:wait(61000)
	local _, right = t:status()
	assert(right and string.find(right, "1 overdue, 1 due today", 1, true), right)
	local rows = t:draw(100, 10)
	local at = string.find(rows[10], "overdue", 1, true)
	assert(at, rows[10])
	t:mouse("press", utf8.len(string.sub(rows[10], 1, at - 1)) or 0, 9)
	local text = greed.view():buffer():text()
	assert(string.find(text, "pay rent", 1, true), "the agenda opened: " .. text)
	t:keys("esc")

	folder(t, { ["a.md"] = `- [ ] pay rent due:{day(0)}\n` })
	t:wait(61000)
	_, right = t:status()
	assert(right and string.find(right, " 1 due today ", 1, true), right)
	assert(not string.find(right, "overdue", 1, true), right)
	folder(t, { ["a.md"] = "- [ ] someday\n" })
	t:wait(61000)
	_, right = t:status()
	assert(right and not string.find(right, "due", 1, true), right)
end)

test("space k on a due date or a reminder says when it is in words", function(t)
	folder(t)
	t:buffer(`- [ ] x due:{day(0)} due:{day(3)} remind:{day(1)} 18:00 end|`)
	local buffer = greed.view():buffer()
	local function words_at(marker: string): string
		local from = string.find(buffer:text(), marker, 1, true) :: number
		greed.view():set_selection({ ranges = { { anchor = from, head = from } }, primary = 1 })
		t:keys("space k")
		local messages = t:messages()
		return messages[#messages] or ""
	end
	assert(words_at(`due:{day(0)}`) == "due today", words_at(`due:{day(0)}`))
	local soon = words_at(`due:{day(3)}`)
	assert(string.find(soon, ", in 3 days", 1, true), soon)
	local remind = words_at("remind:")
	assert(string.match(remind, "^remind tomorrow, 18:00, in %d+ hours$"), remind)
	local elsewhere = words_at("end")
	assert(not string.find(elsewhere, "due", 1, true), "elsewhere it's the usual hover")
	-- Every style's hover key asks the same way.
	t:run("style", { "vim" })
	local from = string.find(buffer:text(), "remind:", 1, true) :: number
	greed.view():set_selection({ ranges = { { anchor = from, head = from } }, primary = 1 })
	t:keys("K")
	local messages = t:messages()
	assert(string.match(messages[#messages], "^remind tomorrow"), messages[#messages])
end)

test("due dates are colored by how close they are, and reminders show their time", function(t)
	local rows = shown(
		t,
		`- [ ] a due:{day(-1)}\n- [ ] b due:{day(0)}\n- [ ] c due:{day(2)}\n`
			.. `- [ ] d due:{day(30)} remind:2027-01-02 18:00\n- [ ] here`
	)
	assert(string.match(rows[4], "^☐ d 📅 %d+ %a+ ?%d* ⏰ 2 Jan 2027 18:00$"), rows[4])
	local styles: { [string]: boolean } = {}
	for _, mark in greed.view():buffer():decorations("notes-look") do
		styles[mark.style] = true
	end
	for _, style in
		{ "notes.overdue", "notes.due.today", "notes.due.soon", "notes.due", "notes.remind" }
	do
		assert(styles[style], style)
	end
end)

test("agents set reminders and change todos one at a time", function(t)
	local dir = folder(t, { ["inbox.md"] = "- [ ] call the bank due:2026-10-05\nplain\n" })
	run_tool("notes_remind", { note = "inbox", line = 1, when = "2026-10-06T18:00" })
	run_tool("notes_remind", { note = "inbox", line = 1, when = "2026-10-06 19:30" })
	run_tool("notes_remind", { text = "buy milk", when = "2026-10-07" })
	local text = greed.fs.read(dir .. "/inbox.md")
	assert(
		text
			== "- [ ] call the bank due:2026-10-05 remind:2026-10-06 19:30\nplain\n"
				.. "- [ ] buy milk remind:2026-10-07\n",
		text
	)
	assert(
		not pcall(run_tool, "notes_remind", { text = "x", when = "tonight" }),
		"a bad time fails"
	)
	assert(not pcall(run_tool, "notes_remind", { when = "2026-10-07" }), "neither line nor text")
	assert(not pcall(run_tool, "notes_remind", { note = "inbox", line = 9, when = "2026-10-07" }))

	local function update(args: { [string]: any }, expected: string)
		args.note, args.line = "inbox", 1
		local changed: string = run_tool("notes_update_todo", args)
		assert(changed == expected, changed)
	end
	update(
		{ text = "call the bank about the loan" },
		"- [ ] call the bank about the loan due:2026-10-05 remind:2026-10-06 19:30"
	)
	update(
		{ due = "", remind = "2026-10-08 08:00", done = true },
		"- [x] call the bank about the loan remind:2026-10-08 08:00"
	)
	update(
		{ done = false, due = "2026-11-01" },
		"- [ ] call the bank about the loan remind:2026-10-08 08:00 due:2026-11-01"
	)
	assert(
		not pcall(run_tool, "notes_update_todo", { note = "inbox", line = 2, done = true }),
		"not a todo"
	)
	assert(
		not pcall(run_tool, "notes_update_todo", { note = "inbox", line = 1, due = "soon" }),
		"a bad date"
	)
	local todo = run_tool("notes_todos")[1]
	assert(todo.remind == "2026-10-08 08:00" and todo.due == "2026-11-01", todo.remind)
	-- An open note changes in the editor.
	greed.open(dir .. "/inbox.md")
	run_tool("notes_update_todo", { note = "inbox", line = 3, done = true })
	assert(
		string.find(greed.view():buffer():text(), "- [x] buy milk", 1, true),
		greed.view():buffer():text()
	)
	assert(not greed.view():buffer():modified(), "and is saved")
end)

test("note names stay inside their place, whatever an agent names", function(t)
	local root = t:tempdir({ ["CLAUDE.md"] = "rules\n", ["notes/a.md"] = "a\n" })
	greed.option.set("notes-folder", `{root}/notes`)
	greed.option.set("notes-project-folder", `{root}/notes/project`)
	for _, name in { "../CLAUDE", "project:../../CLAUDE", "x/../../CLAUDE", "/tmp/x", "./a" } do
		local ok, err = pcall(run_tool, "notes_write", { name = name, text = "pwned" })
		assert(not ok and string.find(tostring(err), "isn't a note's name", 1, true), name)
		assert(not pcall(run_tool, "notes_read", { name = name }), `reading {name} fails too`)
		assert(not pcall(run_tool, "notes_add_todo", { text = "x", note = name }), name)
	end
	assert(greed.fs.read(`{root}/CLAUDE.md`) == "rules\n", "left alone")
	assert(require("@notes").path("sub/b") == `{root}/notes/sub/b.md`, "folders inside are fine")
end)

test("an agent rewriting a note that's there proposes it; a new one is written", function(t)
	local dir = folder(t, { ["a.md"] = "one\ntwo\n" })
	run_tool("notes_write", { name = "new", text = "fresh\n" })
	assert(greed.fs.read(`{dir}/new.md`) == "fresh\n", "a new note is written")
	local said: string? = nil
	greed.spawn(function()
		said = run_tool("notes_write", { name = "a", text = "one\nTWO\n" })
	end)
	t:wait(10)
	assert(said == nil, "it waits for the user")
	assert(greed.fs.read(`{dir}/a.md`) == "one\ntwo\n", "nothing written yet")
	assert(agent.pending() == 1, `{agent.pending()} pending`)
	greed.open(`{dir}/a.md`)
	t:run("proposal-accept-all")
	t:wait_for(function()
		return said ~= nil
	end)
	assert(string.find(tostring(said), "accepted 1", 1, true), said)
	assert(greed.fs.read(`{dir}/a.md`) == "one\nTWO\n", (greed.fs.read(`{dir}/a.md`)))
end)

test("searching notes ignores case unless notes-search-case says otherwise", function(t)
	folder(t, { ["inbox.md"] = "Call Detectiv about the contract\n" })
	local core = require("@core")
	local notes = require("@notes")
	local found = notes.grep(core.search.pattern("detectiv", "notes")) or {}
	assert(#found == 1, "a lowercase search finds it")
	found = notes.grep(core.search.pattern("DETECTIV", "notes")) or {}
	assert(#found == 1, "so does one in capitals")
	greed.option.set("notes-search-case", "match")
	found = notes.grep(core.search.pattern("detectiv", "notes")) or {}
	assert(#found == 0, "unless it should mind case")
	greed.option.set("notes-search-case", "ignore")
end)

test("notes and their todos are objects: listed, related, opened and ticked", function(t)
	local core = require("@core")
	local dir = folder(t, {
		["plan.md"] = "# plan\n\n- [ ] ship it due:2026-10-20\n- [x] write it\n",
		["log.md"] = "see [[plan]]\n",
	})
	local note = assert(core.objects.get("note:plan"))
	local linked = core.objects.related(note).linked_from
	assert(linked and #linked == 1 and linked[1].id == "note:log", "the notes linking here")
	local open: any = nil
	for _, object in core.objects.list("todo") do
		if object.label == "ship it due:2026-10-20" then
			open = object
		end
	end
	assert(open and open.id == "todo:plan#2", open and open.id)
	assert(core.objects.inspect(open).due == "2026-10-20")
	assert(core.objects.related(open).note[1].id == "note:plan")
	assert(core.objects.actions(open)[1].name == "open")
	assert(core.objects.act(open, "tick"))
	t:wait_for(function()
		return string.find(greed.fs.read(`{dir}/plan.md`) or "", "- [x] ship it", 1, true) ~= nil
	end)
end)

test("space . on a todo in a note offers to tick it", function(t)
	local core = require("@core")
	local dir = folder(t, { ["plan.md"] = "- [ ] ship it\n" })
	greed.open(`{dir}/plan.md`)
	t:wait(10)
	local found: any = nil
	for _, target in core.actions.at(greed.view()) do
		if target.kind == "todo" then
			found = target
		end
	end
	assert(found and found.id == "todo:plan#0", found and found.id)
end)
