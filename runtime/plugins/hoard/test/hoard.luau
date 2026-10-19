local test = require("@greed/test")
local greed = require("@greed")
local notes = require("@notes")
local hoard = require("@hoard")

local function day(offset: number): string
	return os.date("%Y-%m-%d", os.time() + offset * 86400) :: string
end

local function folder(t: test.TestContext, files: { [string]: string }): string
	local dir = t:tempdir(files)
	greed.option.set("notes-folder", dir)
	greed.option.set("notes-project-folder", `{dir}/.no-project-notes`)
	return dir
end

-- Shows the home and waits until it's drawn with the notes.
local function show(t: test.TestContext): greed.Buffer
	hoard.home.show()
	local buffer = greed.view():buffer()
	t:wait_for(function()
		return string.find(buffer:text(), "Recent notes", 1, true) ~= nil
	end)
	return buffer
end

test("the home shows today, the agenda by when things are due, and recent notes", function(t)
	folder(t, {
		[`daily/{day(0)}.md`] = `# {day(0)}\n\nwrote this morning\n`,
		["work.md"] = table.concat({
			"# Work",
			`- [ ] pay rent due:{day(0)}`,
			`- [ ] renew passport due:{day(-3)}`,
			`- [ ] dentist due:{day(2)}`,
			`- [ ] next year due:{day(300)}`,
			"- [x] done already due:" .. day(0),
			"",
		}, "\n"),
		["inbox.md"] = "- [ ] one\n- [ ] two\n",
	})
	local buffer = show(t)
	local text = buffer:text()
	assert(string.find(text, "wrote this morning", 1, true), text)
	local overdue = string.find(text, "Overdue", 1, true)
	local passport = string.find(text, "renew passport", 1, true)
	local today = string.find(text, "│ Today", 1, true)
	local rent = string.find(text, "pay rent", 1, true)
	local coming = string.find(text, "Next days", 1, true)
	local dentist = string.find(text, "dentist", 1, true)
	assert(overdue and passport and today and rent and coming and dentist, text)
	assert(
		overdue < passport
			and passport < today
			and today < rent
			and rent < coming
			and coming < dentist
	)
	assert(not string.find(text, "next year", 1, true), "only this week")
	assert(not string.find(text, "done already", 1, true), "only open ones")
	assert(string.find(text, "Inbox: 2 todos", 1, true), "what waits in the inbox")
	assert(string.find(text, "Work", 1, true), "a recent note")
end)

test("search finds notes by title, their headings and open todos", function(t)
	folder(t, {
		["plans.md"] = "# Garden plans\n\n## Tomatoes\n\n- [ ] buy seeds\n",
		["other.md"] = "# Other\n",
	})
	show(t)
	local function labels(query: string): string
		local out = {}
		for _, found in hoard.home.search(query) do
			table.insert(out, `{found.kind}:{found.label}`)
		end
		return table.concat(out, ",")
	end
	assert(string.find(labels("garden"), "note:Garden plans", 1, true), labels("garden"))
	assert(string.find(labels("tomat"), "heading:Tomatoes", 1, true), labels("tomat"))
	assert(string.find(labels("seeds"), "todo:buy seeds", 1, true), labels("seeds"))
end)

test("a todo is ticked from the home, and leaves the agenda", function(t)
	local dir = folder(t, { ["work.md"] = `- [ ] pay rent due:{day(0)}\n` })
	local buffer = show(t)
	local line = 0
	for n = 0, buffer:line_count() - 1 do
		if string.find(buffer:line_text(n), "pay rent", 1, true) then
			line = n
		end
	end
	local box = string.find(buffer:line_text(line), "☐", 1, true) :: number
	greed.view():set_cursor(buffer:line_start(line) + box - 1)
	t:keys("enter")
	t:wait_for(function()
		return string.find(greed.fs.read(`{dir}/work.md`) or "", "[x] pay rent", 1, true) ~= nil
	end)
	t:wait_for(function()
		return not string.find(buffer:text(), "pay rent", 1, true)
	end)
end)

test("what's written in the home's box goes to today's note, [] lines as todos", function(t)
	local dir = folder(t, {})
	local buffer = show(t)
	t:keys(
		"i [ ] space w a t e r space p l a n t s space t o m o r r o w enter m e t space A n n a"
	)
	t:run("hoard-add")
	local today = notes.daily()
	local tomorrow = notes.dates.add_days(notes.today(), 1)
	t:wait_for(function()
		local text = greed.fs.read(`{dir}/{today}.md`) or ""
		return string.find(text, `- [ ] water plants due:{tomorrow}`, 1, true) ~= nil
			and string.find(text, "- met Anna", 1, true) ~= nil
	end)
	assert(
		hoard.home.is(buffer) and string.sub(buffer:text(), -1) == "\n",
		"the box is empty again"
	)
	local said = hoard.home.add("first line\nsecond line\n")
	assert(said == "added to today's note", said)
	t:wait_for(function()
		return string.find(
			greed.fs.read(`{dir}/{today}.md`) or "",
			"\nfirst line\nsecond line\n",
			1,
			true
		) ~= nil
	end)
	assert(hoard.home.add("  \n") == nil, "nothing written")
end)

test("what's written in the box finds notes as it's written", function(t)
	folder(t, { ["plans.md"] = "# Garden plans\n" })
	local buffer = show(t)
	t:keys("i g a r d")
	t:wait_for(function()
		local text = buffer:text()
		return string.find(text, "Notes that match", 1, true) ~= nil
			and string.find(text, "Garden plans", 1, true) ~= nil
	end)
end)

test("/ in a note offers what a note holds, and puts in what's picked", function(t)
	local dir = folder(t, { ["a.md"] = "\n" })
	greed.open(`{dir}/a.md`)
	t:keys("i / t o")
	t:run("completion-ask")
	t:keys("enter")
	local buffer = greed.view():buffer()
	assert(buffer:line_text(0) == "- [ ] ", buffer:line_text(0))
	t:keys("b u y space s e e d s space / d u")
	t:run("completion-ask")
	t:keys("enter")
	local tomorrow = notes.dates.add_days(notes.today(), 1)
	assert(buffer:line_text(0) == `- [ ] buy seeds due:{tomorrow}`, buffer:line_text(0))
	-- Elsewhere, a / is a /.
	local other = t:tempdir({ ["b.txt"] = "\n" })
	greed.open(`{other}/b.txt`)
	t:keys("esc i a / b")
	assert(greed.view():buffer():line_text(0) == "a/b", greed.view():buffer():line_text(0))
end)

-- A note to write in, beside notes with headings, items and an alias.
local function linking(t: test.TestContext): greed.Buffer
	local dir = folder(t, {
		["Garden.md"] = "---\naliases: [yard]\n---\n# Garden\n\n## Seeds\n\n- buy tomatoes\n- water ^water\n",
		["Kitchen.md"] = "# Kitchen\n",
		["today.md"] = "\n",
	})
	notes.index.ensure()
	greed.open(`{dir}/today.md`)
	return greed.view():buffer()
end

test("[[ offers the notes and their aliases, and the closer comes along", function(t)
	local buffer = linking(t)
	t:keys("i [ [ g a r")
	t:run("completion-ask")
	t:keys("enter")
	assert(buffer:line_text(0) == "[[Garden]]", buffer:line_text(0))
	t:keys("esc o [ [ y a r")
	t:run("completion-ask")
	t:keys("enter")
	assert(buffer:line_text(1) == "[[yard]]", buffer:line_text(1))
end)

test("[[note# offers its headings, and #^ its items, giving one an id", function(t)
	local buffer = linking(t)
	t:keys("i [ [ G a r d e n # s e")
	t:run("completion-ask")
	t:keys("enter")
	assert(buffer:line_text(0) == "[[Garden#Seeds]]", buffer:line_text(0))
	t:keys("esc o [ [ G a r d e n # ^ t o m")
	t:run("completion-ask")
	t:keys("enter")
	local id = string.match(buffer:line_text(1), "^%[%[Garden#%^(%x+)%]%]$")
	assert(id, buffer:line_text(1))
	t:wait_for(function()
		return string.find(notes.read("Garden") or "", `- buy tomatoes ^{id}\n`, 1, true) ~= nil
	end)
	t:keys("esc o [ [ G a r d e n # ^ w a t")
	t:run("completion-ask")
	t:keys("enter")
	assert(buffer:line_text(2) == "[[Garden#^water]]", buffer:line_text(2))
end)

test("without pairs typed, a picked link brings its own ]]", function(t)
	local buffer = linking(t)
	greed.option.set("auto-pairs", "off")
	t:keys("i [ [ K i t")
	t:run("completion-ask")
	t:keys("enter")
	assert(buffer:line_text(0) == "[[Kitchen]]", buffer:line_text(0))
end)

test("Hoard types without modes, unless hoard-editing-style says to keep yours", function(t)
	local style = greed.option.get("editing-style")
	greed.option.set("hoard-language-servers", true)
	greed.option.set("editing-style", "helix")
	hoard.defaults()
	assert(greed.option.get("editing-style") == "vscode", "modeless")
	greed.option.set("editing-style", "helix")
	greed.option.set("hoard-editing-style", "same")
	hoard.defaults()
	assert(greed.option.get("editing-style") == "helix", "kept")
	greed.option.set("hoard-editing-style", "vscode")
	greed.option.set("editing-style", style)
end)

test("notes in Hoard have no line numbers", function(t)
	local dir = folder(t, { ["a.md"] = "a\n" })
	local here = hoard.here
	hoard.here = function()
		return true
	end
	greed.open(`{dir}/a.md`)
	hoard.here = here
	assert(not greed.view():buffer():line_numbers(), "no numbers")
end)

test("away from the home, the status line leads back, and so does going back", function(t)
	folder(t, { ["plans.md"] = "# Garden plans\n" })
	local home = show(t)
	local line = 0
	for n = 0, home:line_count() - 1 do
		if string.find(home:line_text(n), "Garden plans", 1, true) then
			line = n
		end
	end
	local at = string.find(home:line_text(line), "Garden", 1, true) :: number
	greed.view():set_cursor(home:line_start(line) + at - 1)
	t:keys("enter")
	t:wait_for(function()
		return greed.view():buffer() ~= home
	end)
	local here = hoard.here
	hoard.here = function()
		return true
	end
	local function status(): string
		local view = greed.view()
		local parts = require("@statusline").build({
			view = view,
			buffer = view:buffer(),
			mode = greed.mode.get(),
			width = 100,
		})
		local out = {}
		for _, segment in parts.left :: { greed.StatusSegment } do
			table.insert(out, if type(segment) == "string" then segment else segment.text)
		end
		return table.concat(out)
	end
	local away = status()
	t:run("jump-back")
	local back = status()
	hoard.here = here
	assert(string.find(away, "‹ Hoard", 1, true), away)
	assert(hoard.home.is(greed.view():buffer()), "back home")
	assert(not string.find(back, "‹ Hoard", 1, true), back)
end)

test("the home's box has the / menu and links, as notes do", function(t)
	local dir = folder(t, { ["plans.md"] = "# Garden plans\n" })
	local buffer = show(t)
	t:keys("i / t o")
	t:run("completion-ask")
	t:keys("enter")
	t:keys("s e e d s space [ [ p l a")
	t:run("completion-ask")
	t:keys("enter")
	local input = hoard.home.add(string.match(buffer:text(), "[^\n]*$") :: string)
	assert(input and string.find(input, "seeds", 1, true), input)
	local today = notes.daily()
	t:wait_for(function()
		return string.find(
			greed.fs.read(`{dir}/{today}.md`) or "",
			"- [ ] seeds [[plans]]",
			1,
			true
		) ~= nil
	end)
end)

test(":hoard in Hoard shows its home", function(t)
	folder(t, { ["plans.md"] = "# Garden plans\n" })
	local here = hoard.here
	hoard.here = function()
		return true
	end
	t:run("hoard")
	hoard.here = here
	assert(hoard.home.is(greed.view():buffer()), "home")
end)

test("up from the box goes to what matches, enter opens it, down comes back", function(t)
	local dir = folder(t, { ["plans.md"] = "# Garden plans\n" })
	local buffer = show(t)
	t:keys("i g a r d")
	t:wait_for(function()
		return string.find(buffer:text(), "Notes that match", 1, true) ~= nil
	end)
	t:keys("up")
	local view = greed.view()
	local line = buffer:line_text(buffer:line_of(view:cursor()))
	assert(string.find(line, "Garden plans", 1, true), line)
	assert(#buffer:decorations("hoard-focus") == 1, "highlighted")
	t:keys("down")
	assert(view:cursor() == buffer:len(), "back in the box")
	t:keys("up enter")
	t:wait_for(function()
		return greed.view():buffer():path() == `{dir}/plans.md`
	end)
end)

test("in the box, the / menu keeps its own arrows", function(t)
	folder(t, {})
	local buffer = show(t)
	t:keys("i /")
	t:run("completion-ask")
	t:keys("down enter")
	local box = string.match(buffer:text(), "[^\n]*$") :: string
	assert(box == notes.today(), box)
end)

test("in the box, tab goes through a snippet's places before anything else", function(t)
	folder(t, {})
	local buffer = show(t)
	t:keys("i / d u e")
	t:run("completion-ask")
	t:keys("enter")
	assert(require("@core").snippet.active(greed.view()), "filling in the date")
	t:keys("tab")
	assert(not require("@core").snippet.active(greed.view()), "at its end")
	assert(greed.view():cursor() == buffer:len(), "still in the box")
end)

test("in Hoard, esc in a note lets go of a selection, and then goes home", function(t)
	local dir = folder(t, { ["plans.md"] = "# Garden plans\n" })
	local style = greed.option.get("editing-style")
	greed.option.set("editing-style", "vscode")
	local here = hoard.here
	hoard.here = function()
		return true
	end
	greed.open(`{dir}/plans.md`)
	t:keys("shift-right esc")
	local view = greed.view()
	local range = view:selection().ranges[1]
	local kept = view:buffer():path() == `{dir}/plans.md` and range.anchor == range.head
	t:keys("esc")
	local went = hoard.home.is(greed.view():buffer())
	hoard.here = here
	greed.option.set("editing-style", style)
	assert(kept, "the first esc let go of the selection, in the note")
	assert(went, "the second went home")
end)

test("in Hoard, esc with the / menu open only closes the menu", function(t)
	local dir = folder(t, { ["plans.md"] = "\n" })
	local style = greed.option.get("editing-style")
	greed.option.set("editing-style", "vscode")
	local here = hoard.here
	hoard.here = function()
		return true
	end
	greed.open(`{dir}/plans.md`)
	t:keys("/")
	t:run("completion-ask")
	t:keys("esc")
	local stayed = greed.view():buffer():path() == `{dir}/plans.md`
	hoard.here = here
	greed.option.set("editing-style", style)
	assert(stayed, "still in the note")
end)

test("a todo added today without a date is on the agenda, not in the Today box", function(t)
	folder(t, {})
	local buffer = show(t)
	hoard.home.add("[] water the plants\nthe shed needs paint")
	t:wait_for(function()
		local text = buffer:text()
		local agenda = string.match(text, "Agenda(.-)Recent notes") or ""
		local today = string.match(text, "Today ─(.-)Open today") or ""
		return string.find(agenda, "water the plants", 1, true) ~= nil
			and string.find(today, "the shed needs paint", 1, true) ~= nil
			and not string.find(today, "water the plants", 1, true)
	end)
end)

test("a todo on the agenda is moved to another day, picked or in plain words", function(t)
	local dir = folder(t, { ["a.md"] = `- [ ] pay rent due:{notes.today()}\n` })
	local buffer = show(t)
	local line = 0
	t:wait_for(function()
		for n = 0, buffer:line_count() - 1 do
			if string.find(buffer:line_text(n), "pay rent", 1, true) then
				line = n
				return true
			end
		end
		return false
	end)
	greed.view():set_cursor(buffer:line_start(line))
	t:run("hoard-schedule")
	t:keys("T o m o r r o w enter")
	local tomorrow = notes.dates.add_days(notes.today(), 1)
	t:wait_for(function()
		return greed.fs.read(`{dir}/a.md`) == `- [ ] pay rent due:{tomorrow}\n`
	end)
	hoard.home.schedule({ note = "a", line = 0, text = "pay rent", due = tomorrow })
	t:keys("i n space 3 space d a y s enter")
	local later = notes.dates.add_days(notes.today(), 3)
	t:wait_for(function()
		return greed.fs.read(`{dir}/a.md`) == `- [ ] pay rent due:{later}\n`
	end)
	hoard.home.schedule({ note = "a", line = 0, text = "pay rent", due = later })
	t:keys("N o space d a t e enter")
	t:wait_for(function()
		return greed.fs.read(`{dir}/a.md`) == "- [ ] pay rent\n"
	end)
end)

test("a habit is on the agenda each of its days until it's ticked off", function(t)
	local dir = folder(t, { ["habits.md"] = "- [ ] stretch every:day!\n" })
	local buffer = show(t)
	local function agenda(): string
		return string.match(buffer:text(), "Agenda(.-)Recent notes") or ""
	end
	t:wait_for(function()
		return string.find(agenda(), "stretch ↻", 1, true) ~= nil
	end)
	notes.todos.update("habits", 0, { done = true })
	t:wait_for(function()
		return not string.find(agenda(), "stretch", 1, true)
	end)
	local text = greed.fs.read(`{dir}/habits.md`) or ""
	assert(string.find(text, `- [ ] stretch every:day! done:{notes.today()}`, 1, true), text)
end)

test("search finds what notes say anywhere in them, and takes a query", function(t)
	folder(t, {
		["plans.md"] = "# Garden plans\n\nThe shed needs paint before winter.\n",
		["late.md"] = `- [ ] call the bank due:{notes.dates.add_days(notes.today(), -1)}\n`,
	})
	local function labels(query: string): string
		local out = {}
		for _, found in hoard.home.search(query) do
			table.insert(out, found.label)
		end
		return table.concat(out, ",")
	end
	assert(labels("paint") == "Garden plans", labels("paint"))
	assert(labels("is:overdue") == "call the bank", labels("is:overdue"))
	assert(labels("winte") == "Garden plans", "the last word as it's typed")
end)

test(
	"the first time, the home says where notes are and how to add to them, until put away",
	function(t)
		local dir = folder(t, { ["work.md"] = "# Work\n" })
		assert(hoard.home.welcoming(), "a first start")
		local text = show(t):text()
		assert(string.find(text, "Welcome to Hoard", 1, true), text)
		local shown = require("@core").project.tilde(dir)
		assert(string.find(text, shown, 1, true), `where the notes are: {shown}`)
		assert(string.find(text, "greed capture", 1, true), "how to add from a shell")
		hoard.home.welcomed()
		assert(not hoard.home.welcoming(), "put away")
		assert(greed.fs.stat(`{greed.fs.dirs().data}/hoard/welcomed`), "for good")
		local buffer = show(t)
		t:wait_for(function()
			return not string.find(buffer:text(), "Welcome to Hoard", 1, true)
		end)
	end
)

test(
	"the agenda note is made the first time, its blocks queries that run, and then it's yours",
	function(t)
		local dir = folder(t, { ["work.md"] = `# Work\n- [ ] pay rent due:{day(-1)}\n` })
		hoard.agenda.open()
		local path = `{dir}/agenda.md`
		assert(greed.view():buffer():path() == path, greed.view():buffer():path())
		local text = assert(greed.fs.read(path))
		local count = 0
		for query in string.gmatch(text, "```notes\n(.-)\n```") do
			count += 1
			local items, problems = notes.query.run(query)
			assert(items, `{query}: {if problems[1] then problems[1].message else "?"}`)
		end
		assert(count == 5, tostring(count))
		-- Changed, it stays as you made it.
		greed.fs.write(path, "# Mine\n")
		hoard.agenda.open()
		assert(greed.fs.read(path) == "# Mine\n", "kept")
	end
)
