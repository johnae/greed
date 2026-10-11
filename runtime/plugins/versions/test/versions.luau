local test = require("@greed/test")
local greed = require("@greed")
local versions = require("@versions")

local function info(t: test.TestContext, over: { [string]: any }?): versions.Info
	local made: any = {
		session = "john",
		theirs = "0.1.1",
		ours = "0.1.3",
		unsaved = {},
		busy = {},
		old = true,
		answer = `{t:tempdir()}/answer`,
	}
	local extra: { [string]: any } = over or {}
	for key, value in extra do
		made[key] = value
	end
	return made
end

test("the page says which versions and what's at stake, with a button for each choice", function(t)
	local asked = info(t, { unsaved = { "notes.md", "src/main.rs" }, busy = { "cargo test" } })
	local text = versions.text(asked)
	assert(string.find(text, "**john** runs Greed 0.1.1, and this is Greed 0.1.3", 1, true), text)
	assert(string.find(text, "unsaved changes in `notes.md` and `src/main.rs`", 1, true), text)
	assert(string.find(text, "Still running in it: `cargo test`", 1, true), text)
	assert(
		string.find(
			text,
			'button="1  End it, losing those changes, and start Greed 0.1.3"',
			1,
			true
		),
		text
	)
	assert(
		string.find(text, 'button="2  Open it with Greed 0.1.1, to save your work first"', 1, true),
		text
	)
	assert(string.find(text, 'button="3  Start Greed 0.1.3 beside it', 1, true), text)
	-- Over ssh it says where, and without that version here there's no
	-- opening it with it.
	local remote = versions.text(info(t, { host = "build-box", old = false }))
	assert(string.find(remote, "**john** on build-box", 1, true), remote)
	assert(not string.find(remote, "Open it with", 1, true), remote)
	assert(string.find(remote, 'button="2  Start Greed 0.1.3 beside it', 1, true), remote)
end)

test("a number picks its choice, and esc cancels, writing the answer", function(t)
	t:buffer("|")
	local asked = info(t)
	versions.ask(asked)
	assert(greed.view():buffer():kind() == "versions")
	t:keys("3")
	local answer = greed.fs.read(asked.answer)
	assert(answer == "beside", tostring(answer))
	local again = info(t)
	versions.ask(again)
	t:keys("esc")
	assert(greed.fs.read(again.answer) == "cancel")
end)

test("enter on a button presses it", function(t)
	t:buffer("|")
	local asked = info(t)
	versions.ask(asked)
	-- Shown, as a client shows it, the buttons are drawn; the cursor starts
	-- on the first.
	t:draw(80, 24)
	t:keys("enter")
	t:wait_for(function()
		return greed.fs.read(asked.answer) ~= nil
	end)
	local answer = greed.fs.read(asked.answer)
	assert(answer == "end", tostring(answer))
end)

test("an error the window can't say elsewhere shows on a page, closed with esc", function(t)
	t:buffer("|")
	versions.tell("couldn't attach on eris: refused")
	local buffer = greed.view():buffer()
	assert(buffer:kind() == "versions")
	local text = buffer:text()
	assert(string.find(text, "# Greed can't go on", 1, true), text)
	assert(string.find(text, "couldn't attach on eris: refused", 1, true), text)
	assert(string.find(text, 'button="Close"', 1, true), text)
end)
