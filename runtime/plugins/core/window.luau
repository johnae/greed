-- How the window (`greed --gui`) draws text. A window reads every option
-- named `gui-...`; terminals ignore them. `ctrl-=` and `ctrl--` make the
-- text bigger and smaller, `ctrl-0` puts it back.
--
--     greed.option.set("gui-font", "JetBrains Mono")
--     greed.option.set("gui-font-size", 14)

local greed = require("@greed")

-- The size the window's text starts at, and the sizes zooming keeps to.
local SIZE, SMALLEST, LARGEST = 15, 6, 72

greed.option.define({
	name = "gui-font",
	doc = "The font the window draws text in, by family name; empty for the system's monospaced font",
	default = "",
})

greed.option.define({
	name = "gui-font-size",
	doc = "The size of the window's text in pixels, before the screen's scale",
	default = SIZE,
})

-- The size before zooming started, which `font-reset` goes back to.
local before: number? = nil

local function current(): number
	return greed.option.get("gui-font-size") :: number
end

local function zoom(by: number)
	before = before or current()
	greed.option.set("gui-font-size", math.clamp(current() + by, SMALLEST, LARGEST))
end

greed.command({
	name = "font-bigger",
	doc = "Make the window's text bigger",
	run = function()
		zoom(1)
	end,
})

greed.command({
	name = "font-smaller",
	doc = "Make the window's text smaller",
	run = function()
		zoom(-1)
	end,
})

greed.command({
	name = "font-reset",
	doc = "Put the window's text back to its size before zooming",
	run = function()
		greed.option.set("gui-font-size", before or current())
		before = nil
	end,
})

-- An empty layer applies in every mode.
greed.keymap.bind({}, {
	["ctrl-="] = "font-bigger",
	["ctrl-+"] = "font-bigger",
	["ctrl--"] = "font-smaller",
	["ctrl-0"] = "font-reset",
})

return {}
