local test = require("@greed/test")
local greed = require("@greed")

test("animations step from 0 to 1 on the editor's clock", function(t)
	local steps = {}
	greed.command({
		name = "animate-for-test",
		run = function()
			greed.animate(100, function(progress)
				table.insert(steps, progress)
			end)
		end,
	})
	local before = greed.now()
	t:run("animate-for-test")
	assert(#steps == 1 and steps[1] == 0, "the first step is at once, with 0")
	t:wait(150)
	assert(steps[#steps] == 1, "the last step is 1, got " .. tostring(steps[#steps]))
	assert(#steps >= 6, "about one step per frame, got " .. #steps)
	for i = 2, #steps do
		assert(steps[i] > steps[i - 1], "steps only go forward")
	end
	assert(greed.now() - before >= 100, "time moved on with the animation")
end)

test("copied text flashes, then goes back to normal", function(t)
	t:buffer("^hello| world")
	t:keys("y")
	local buffer = greed.view():buffer()
	local marks = buffer:decorations("flash")
	assert(#marks == 1 and marks[1].from == 0 and marks[1].to == 5, "the copied text is marked")
	t:wait(1000)
	assert(#buffer:decorations("flash") == 0, "the mark goes away")
end)

test("with hex colors the flash fades towards the text's background", function(t)
	greed.theme.set({ ["ui.flash"] = { bg = "#ffff00" }, ["ui.text"] = { bg = "#000000" } })
	t:buffer("^hello| world")
	t:keys("y")
	local function bg(): string?
		local entry = greed.theme.get("ui.flash.now")
		return entry and entry.bg
	end
	assert(bg() == "#ffff00", "starts at the flash color, got " .. tostring(bg()))
	t:wait(150)
	local middle = bg()
	assert(
		middle ~= "#ffff00" and middle ~= "#000000",
		"halfway it's in between, got " .. tostring(middle)
	)
	t:wait(500)
	assert(bg() == "#000000", "ends at the background, got " .. tostring(bg()))
end)

test("flash-duration sets how long the flash lasts", function(t)
	greed.option.set("flash-duration", 100)
	t:buffer("^hello| world")
	t:keys("y")
	local buffer = greed.view():buffer()
	t:wait(50)
	assert(#buffer:decorations("flash") == 1, "still showing halfway")
	t:wait(60)
	assert(#buffer:decorations("flash") == 0, "gone after 100ms")
end)

test("a second copy soon after keeps its flash when the first one's ends", function(t)
	greed.option.set("flash-duration", 300)
	t:buffer("^one| two")
	local buffer = greed.view():buffer()
	t:keys("y")
	t:wait(100)
	t:keys("e y")
	t:wait(250)
	local marks = buffer:decorations("flash")
	assert(
		#marks == 1 and buffer:slice(marks[1].from, marks[1].to) == " two",
		"the newer flash stays"
	)
	t:wait(200)
	assert(#buffer:decorations("flash") == 0, "and goes when its own time is up")
end)

test("every selection copied flashes", function(t)
	t:buffer("^ab| ^cd| ef")
	t:keys("y")
	assert(#greed.view():buffer():decorations("flash") == 2)
end)

test("with named colors the flash shows, then goes, without fading", function(t)
	greed.theme.set({ ["ui.flash"] = { bg = "yellow", fg = "black" } })
	t:buffer("^hello| world")
	t:keys("y")
	local now = greed.theme.get("ui.flash.now") :: greed.ThemeEntry
	assert(now.bg == "yellow", tostring(now.bg))
	t:wait(150)
	assert((greed.theme.get("ui.flash.now") :: greed.ThemeEntry).bg == "yellow", "no fading")
	t:wait(400)
	assert(#greed.view():buffer():decorations("flash") == 0)
end)

test("a buffer that goes away while flashing doesn't cause an error", function(t)
	t:buffer("^hello| world")
	t:keys("y")
	t:buffer("|other")
	t:wait(1000)
	for _, message in t:messages() do
		assert(not string.find(message, "closed", 1, true), message)
	end
end)
