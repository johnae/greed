-- Looking back: the weekly review, and what the home brings back.

local test = require("@greed/test")
local greed = require("@greed")
local notes = require("@notes")
local hoard = require("@hoard")

local function folder(t: test.TestContext, files: { [string]: string }): string
	local dir = t:tempdir(files)
	greed.option.set("notes-folder", dir)
	greed.option.set("notes-project-folder", `{dir}/.no-project-notes`)
	notes.index.ensure()
	return dir
end

-- Runs `f` with the clock `days` days on, so the notes look that old.
local function later(days: number, f: () -> ())
	local clock = notes.clock
	local now = clock()
	notes.clock = function(): number
		return now + days * 86400
	end
	local ok, err = pcall(function()
		f()
	end)
	notes.clock = clock
	assert(ok, tostring(err))
end

test("the weekly review says what was done, overdue, coming, in the inbox and written", function(t)
	local today = notes.today()
	local dates = notes.dates
	folder(t, {
		["a.md"] = table.concat({
			`- [x] paid the rent done:{today}`,
			`- [ ] call the bank due:{dates.add_days(today, -1)}`,
			`- [ ] plan the trip due:{dates.add_days(today, 2)}`,
			"",
		}, "\n"),
		["inbox.md"] = "- [ ] sort the photos\n",
		[`daily/{today}.md`] = "met Anna\n",
	})
	local text = hoard.review.text()
	local function says(part: string, line: string)
		local body = string.match(text, `## {part}\n\n(.-)\n\n`) or ""
		assert(string.find(body, line, 1, true), `{part}: {body}`)
	end
	says("Done", "- paid the rent ([[a]])")
	says("Overdue", "- call the bank ([[a]], due ")
	says("Coming up", "- plan the trip ([[a]], due ")
	says("Inbox", "- sort the photos ([[inbox]])")
	says("Written", `- [[daily/{today}]]`)
end)

test("the review is written once a week, and what you add to it stays", function(t)
	local dir = folder(t, { ["a.md"] = "- [ ] call\n" })
	t:run("hoard-review")
	local name = hoard.review.name()
	local path = `{dir}/{name}.md`
	assert(greed.view():buffer():path() == path, greed.view():buffer():path())
	local buffer = greed.view():buffer()
	buffer:edit(function(e)
		e:insert(buffer:len(), "- a thought of mine\n")
	end)
	buffer:save()
	t:run("hoard-review")
	assert(string.find(greed.fs.read(path) or "", "a thought of mine", 1, true), "kept")
end)

test("the home brings back todos that waited long and an old note", function(t)
	folder(t, {
		["old.md"] = "# Old ideas\n\n- [ ] someday learn the cello\n",
		["dated.md"] = "- [ ] dentist due:2030-01-01\n",
	})
	later(40, function()
		local waiting = hoard.review.waiting()
		assert(#waiting == 1 and waiting[1].text == "someday learn the cello", tostring(#waiting))
		hoard.home.show()
		local buffer = greed.view():buffer()
		t:wait_for(function()
			local text = buffer:text()
			return string.find(text, "Waiting a while", 1, true) ~= nil
				and string.find(text, "someday learn the cello", 1, true) ~= nil
				and string.find(text, "Remember this?", 1, true) ~= nil
		end)
	end)
end)
