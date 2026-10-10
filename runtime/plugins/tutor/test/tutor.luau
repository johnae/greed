local test = require("@greed/test")
local greed = require("@greed")
local markdown = require("@markdown")
local tutor = require("@tutor")

local function page(): greed.Buffer
	local buffer = greed.view():buffer()
	assert(buffer:kind() == "tutor", "the tutor shows")
	return buffer
end

-- Opens a fresh tutor in `style`.
local function open(t: test.TestContext, style: string): greed.Buffer
	t:buffer("|")
	greed.option.set("editing-style", style)
	t:run("tutor")
	return page()
end

test(":tutor asks which style, with yours picked, and teaches its keys", function(t)
	local buffer = open(t, "vim")
	local answers = markdown.questions.answers(buffer)
	assert(answers.style == "vim", greed.json.encode(answers))
	local rows = table.concat(t:draw(100, 200), "\n")
	assert(string.find(rows, "d w", 1, true), "vim's keys: " .. rows)
	assert(not string.find(rows, "ctrl-backspace", 1, true), "not vscode's: " .. rows)
	assert(not string.find(rows, "<!--", 1, true), "comments hidden")
	greed.option.set("editing-style", "helix")
end)

test("picking another style switches to it and shows its keys", function(t)
	local buffer = open(t, "helix")
	local vscode: number? = nil
	for _, group in markdown.choices.list(buffer) do
		for _, option in group.options do
			if option.value == "vscode" then
				vscode = option.line
			end
		end
	end
	local line = assert(vscode, "vscode is a choice")
	markdown.choices.pick(buffer, line)
	assert(greed.option.get("editing-style") == "vscode", "switched")
	local rows = table.concat(t:draw(100, 200), "\n")
	assert(string.find(rows, "ctrl-backspace", 1, true), rows)
	greed.option.set("editing-style", "helix")
end)

for _, style in { "vim", "helix", "vscode" } do
	test(`every exercise is done with the keys {style} is taught`, function(t)
		local buffer = open(t, style)
		local count = #tutor.exercises(buffer)
		assert(count >= 4, `{count} exercises`)
		for i = 1, count do
			local exercise = tutor.exercises(buffer)[i]
			assert(not tutor.done(buffer, exercise), `exercise {i} isn't done to begin with`)
			local keys = assert(exercise.keys[style], `exercise {i} has keys for {style}`)
			greed.view():set_cursor(exercise.from)
			t:keys(keys)
			exercise = tutor.exercises(buffer)[i]
			assert(
				tutor.done(buffer, exercise),
				`{style}, exercise {i}, {keys}: {buffer:slice(exercise.from, exercise.to)}`
			)
		end
		local rows = table.concat(t:draw(100, 250), "\n")
		local _, done = string.gsub(rows, "✓ done", "")
		assert(done == count, `{done} of {count} marked done`)
		greed.option.set("editing-style", "helix")
	end)
end

test("the page's want blocks stay hidden, and :tutor goes to the page that's open", function(t)
	local buffer = open(t, "helix")
	local rows = table.concat(t:draw(100, 250), "\n")
	assert(not string.find(rows, "```want", 1, true), rows)
	t:run("tutor")
	assert(page() == buffer, "the same page")
	t:buffer("|other")
	t:run("tutor")
	assert(page() ~= buffer, "a fresh one once it's gone")
end)
