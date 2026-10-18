local test = require("@greed/test")
local greed = require("@greed")
local notes = require("@notes")
local todos = notes.todos

local function folder(t: test.TestContext, files: { [string]: string }?): string
	local dir = t:tempdir(files)
	greed.option.set("notes-folder", dir)
	greed.option.set("notes-project-folder", `{dir}/.no-project-notes`)
	return dir
end

local function day(offset: number): string
	return notes.dates.add_days(notes.today(), offset)
end

test("a todo captured in plain words is due when it says, with a reminder at its time", function(t)
	local dir = folder(t)
	local said = todos.capture("call the bank tomorrow 18:00", "inbox")
	local text = greed.fs.read(`{dir}/inbox.md`) or ""
	assert(text == `- [ ] call the bank due:{day(1)} remind:{day(1)} 18:00\n`, text)
	assert(string.find(said, "call the bank, due tomorrow, reminder at 18:00", 1, true), said)
	todos.capture("water plants every day", "inbox")
	text = greed.fs.read(`{dir}/inbox.md`) or ""
	assert(string.find(text, `- [ ] water plants every:day due:{day(0)}\n`, 1, true), text)
	todos.capture("just a thing", "inbox")
	text = greed.fs.read(`{dir}/inbox.md`) or ""
	assert(string.find(text, "- [ ] just a thing\n", 1, true), text)
end)

test("ticking a repeating todo brings it back for its next date", function(t)
	local dir = folder(t, {
		["chores.md"] = `- [ ] water plants every:day due:{day(0)} remind:{day(0)} 08:00\n- [ ] once\n`,
	})
	todos.update("chores", 0, { done = true })
	local text = greed.fs.read(`{dir}/chores.md`) or ""
	assert(
		text
			== `- [x] water plants every:day due:{day(0)} remind:{day(0)} 08:00 done:{day(0)}\n`
				.. `- [ ] water plants every:day due:{day(1)} remind:{day(1)} 08:00\n`
				.. "- [ ] once\n",
		text
	)
	todos.update("chores", 2, { done = true })
	text = greed.fs.read(`{dir}/chores.md`) or ""
	assert(
		select(2, string.gsub(text, "water plants", "")) == 2,
		"nothing comes back for a todo that doesn't repeat"
	)
end)

test("space n x on a repeating todo ticks it and brings the next one", function(t)
	local dir = folder(t, { ["c.md"] = `- [ ] stretch every:monday due:{day(0)}\n` })
	greed.open(`{dir}/c.md`)
	t:run("todo-toggle")
	local buffer = greed.view():buffer()
	local next = notes.dates.next(day(0), "monday")
	assert(
		buffer:text()
			== `- [x] stretch every:monday due:{day(0)} done:{day(0)}\n- [ ] stretch every:monday due:{next}\n`,
		buffer:text()
	)
end)

test("today's note starts from the daily template, with the date filled in", function(t)
	local dir = folder(t, { ["templates/daily.md"] = "# {{date}}, {{day}}\n\n## Plans\n" })
	local path = notes.make_daily()
	local text = greed.fs.read(path) or ""
	local day = os.date("%A %d %B", notes.clock())
	assert(text == `# {notes.today()}, {day}\n\n## Plans\n`, text)
	assert(path == `{dir}/daily/{notes.today()}.md`, path)
	greed.fs.write(path, "changed\n")
	notes.make_daily()
	assert(greed.fs.read(path) == "changed\n", "an existing note is left as it is")
end)
