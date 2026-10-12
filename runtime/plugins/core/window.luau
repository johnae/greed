-- How the window (`greed --gui`) draws text. A window reads every option
-- named `gui-...`; terminals ignore them. `ctrl-=` and `ctrl--` make the
-- text bigger and smaller in the window you type them in, and `ctrl-0`
-- puts it back: each window attached to a session zooms on its own.
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
	name = "gui-font-prose",
	doc = "The proportional font the window draws prose in (styles with font = \"prose\", like Markdown's text), by family name; empty for the system's sans-serif",
	default = "",
})

greed.option.define({
	name = "gui-font-size",
	doc = "The size of the window's text in pixels, before the screen's scale; "
		.. "zooming gives a window a size of its own",
	default = SIZE,
})

greed.option.define({
	name = "gui-smooth-scroll",
	doc = "Whether the window glides a view's text to where it scrolled, rather than jumping there",
	default = true,
})

local function current(): number
	return greed.option.get("gui-font-size") :: number
end

-- Zooms the acting client's window alone, with a size of its own.
local function zoom(by: number)
	greed.option.set(
		"gui-font-size",
		math.clamp(current() + by, SMALLEST, LARGEST),
		{ client = true }
	)
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
		greed.option.set("gui-font-size", nil, { client = true })
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
