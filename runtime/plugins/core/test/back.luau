local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")

test("q and esc run the step a kind gives back", function(t)
	local ran = 0
	greed.command({
		name = "test-back-step",
		run = function()
			ran += 1
		end,
	})
	core.back.provide("back-stepped", "test-back-step")
	greed.view():show(greed.create_buffer("back-stepped", "one\ntwo", { readonly = true }))
	t:keys("q")
	t:keys("esc")
	assert(ran == 2, `ran {ran} times`)
end)

test("a step that goes nowhere goes back where you came from", function(t)
	local asked = 0
	core.back.provide("back-page", function(): boolean
		asked += 1
		return false
	end)
	local dir = t:tempdir({ ["a.txt"] = "one\ntwo" })
	greed.open(dir .. "/a.txt")
	local from = greed.view():buffer()
	t:keys("j")
	local page = greed.create_buffer("back-page", "a page", { readonly = true })
	greed.view():show(page)
	t:keys("q")
	assert(asked == 1, "its step was asked first")
	assert(greed.view():buffer():id() == from:id(), greed.view():buffer():kind())
end)

test("a float with nowhere to go back to closes; a pane says so", function(t)
	core.back.provide("back-float")
	local view = greed.float(greed.create_buffer("back-float", "floating", { readonly = true }), {})
	view:focus()
	t:keys("esc")
	assert(not view:valid(), "the float closed")

	local pane = greed.view()
	pane:show(greed.create_buffer("back-float", "in a pane", { readonly = true }))
	t:keys("q")
	assert(pane:valid(), "the pane stays")
	local said = table.concat(t:messages(), "\n")
	assert(string.find(said, "nothing to go back to", 1, true), said)
end)
