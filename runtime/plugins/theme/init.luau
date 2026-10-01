-- The default theme. It only uses the terminal's 16 colors, so it follows
-- whatever palette your terminal has.
--
-- To change a few things, call `kern.theme.set` from your config with just
-- those names; to replace the theme, set everything. Names fall back to their
-- parent: "keyword.control" uses "keyword" unless it has its own entry.

local kern = require("@kern")

kern.theme.set({
	["ui.gutter"] = { fg = "bright-black" },
	["ui.gutter.diagnostic.error"] = { fg = "red" },
	["ui.gutter.diagnostic.warning"] = { fg = "yellow" },
	["ui.gutter.diagnostic.info"] = { fg = "blue" },
	["ui.gutter.diagnostic.hint"] = { fg = "cyan" },
	["ui.selection"] = { bg = "blue", fg = "bright-white" },
	["ui.cursor"] = { reverse = true },
	["ui.statusline"] = { bg = "bright-black", fg = "white" },
	["ui.statusline.mode"] = { bg = "blue", fg = "black", bold = true },
	["ui.statusline.message"] = { fg = "bright-yellow" },
	["ui.float.border"] = { fg = "bright-black" },
	["ui.float.title"] = { fg = "white", bold = true },
	["ui.menu.selected"] = { bg = "bright-black", fg = "bright-white" },
	["ui.menu.match"] = { fg = "yellow", bold = true },
	["ui.menu.doc"] = { dim = true },
	["ui.flash"] = { bg = "yellow", fg = "black" },

	["diagnostic.error"] = { underline = "curl", underline_color = "red" },
	["diagnostic.warning"] = { underline = "curl", underline_color = "yellow" },
	["diagnostic.info"] = { underline = "curl", underline_color = "blue" },
	["diagnostic.hint"] = { underline = "dotted", underline_color = "cyan" },
	["diagnostic.sign.error"] = { fg = "red", bold = true },
	["diagnostic.sign.warning"] = { fg = "yellow", bold = true },
	["diagnostic.sign.info"] = { fg = "blue" },
	["diagnostic.sign.hint"] = { fg = "cyan" },
	["diagnostic.message.error"] = { fg = "red", italic = true },
	["diagnostic.message.warning"] = { fg = "yellow", italic = true },
	["diagnostic.message.info"] = { fg = "blue", italic = true },
	["diagnostic.message.hint"] = { fg = "cyan", italic = true },

	keyword = { fg = "magenta" },
	conditional = { fg = "magenta" },
	["repeat"] = { fg = "magenta" },
	include = { fg = "magenta" },
	exception = { fg = "magenta" },
	string = { fg = "green" },
	character = { fg = "green" },
	comment = { fg = "bright-black", italic = true },
	["function"] = { fg = "blue" },
	method = { fg = "blue" },
	constructor = { fg = "blue" },
	type = { fg = "yellow" },
	attribute = { fg = "yellow" },
	label = { fg = "yellow" },
	constant = { fg = "cyan" },
	number = { fg = "cyan" },
	boolean = { fg = "cyan" },
	float = { fg = "cyan" },
	escape = { fg = "cyan" },
	["text.title"] = { fg = "blue", bold = true },
	["text.literal"] = { fg = "green" },
	["text.uri"] = { fg = "cyan", underline = true },
})

return {}
