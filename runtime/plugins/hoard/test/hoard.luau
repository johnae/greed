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
	t:run("hoard")
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

test("a todo added on the home goes to today's note", function(t)
	local dir = folder(t, {})
	local buffer = show(t)
	local line = 0
	for n = 0, buffer:line_count() - 1 do
		if string.find(buffer:line_text(n), "Add a todo", 1, true) then
			line = n
		end
	end
	local at = string.find(buffer:line_text(line), "[", 1, true) :: number
	greed.view():set_cursor(buffer:line_start(line) + at - 1)
	t:keys("enter")
	t:keys("w a t e r space p l a n t s enter")
	local today = notes.daily()
	t:wait_for(function()
		return string.find(greed.fs.read(`{dir}/{today}.md`) or "", "- [ ] water plants", 1, true)
			~= nil
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
