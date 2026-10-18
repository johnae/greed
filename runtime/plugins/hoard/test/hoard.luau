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
