-- How the window (`greed --gui`) draws text. A window reads every option
-- named `gui-...`; terminals ignore them.
--
--     greed.option.set("gui-font", "JetBrains Mono")
--     greed.option.set("gui-font-size", 14)

local greed = require("@greed")

greed.option.define({
	name = "gui-font",
	doc = "The font the window draws text in, by family name; empty for the system's monospaced font",
	default = "",
})

greed.option.define({
	name = "gui-font-size",
	doc = "The size of the window's text in pixels, before the screen's scale",
	default = 15,
})

return {}
