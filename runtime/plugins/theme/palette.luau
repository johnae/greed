-- A whole theme from a few colors: the backgrounds, the text and a set of
-- hues, with optional colors for the syntax roles where a theme departs
-- from the usual (Nord's keywords are blue, Dracula's are pink).

local kern = require("@kern")

export type Palette = {
	--- The editor's background, and two steps from it: one for the status
	--- line, floats and panels, one for the current item in a list.
	bg: string,
	bg_alt: string,
	bg_high: string,
	selection: string,
	fg: string,
	--- Quieter text, like the status line's; `fg` by default.
	fg_alt: string?,
	comment: string,
	--- Line numbers and borders.
	gutter: string,
	red: string,
	orange: string,
	yellow: string,
	green: string,
	cyan: string,
	blue: string,
	purple: string,
	--- The mode in the status line and the active tab; `blue` by default.
	accent: string?,
	--- Syntax roles, each with a hue by default.
	keyword: string?, -- purple
	func: string?, -- blue
	string: string?, -- green
	type: string?, -- yellow
	constant: string?, -- orange
	operator: string?, -- cyan
}

local M = {}

--- Every style name Kern and its plugins use, from `p`.
function M.styles(p: Palette): { [string]: kern.ThemeEntry }
	local fg_alt = p.fg_alt or p.fg
	local accent = p.accent or p.blue
	local keyword = p.keyword or p.purple
	local func = p.func or p.blue
	local str = p.string or p.green
	local typ = p.type or p.yellow
	local constant = p.constant or p.orange
	local operator = p.operator or p.cyan
	local severity: { [string]: string } =
		{ error = p.red, warning = p.yellow, info = p.blue, hint = p.cyan }
	local styles: { [string]: kern.ThemeEntry } = {
		["ui.text"] = { fg = p.fg, bg = p.bg },
		["ui.gutter"] = { fg = p.gutter },
		["ui.selection"] = { bg = p.selection },
		["ui.cursor"] = { reverse = true },
		["ui.statusline"] = { bg = p.bg_alt, fg = fg_alt },
		["ui.statusline.mode"] = { bg = accent, fg = p.bg, bold = true },
		["ui.statusline.message"] = { fg = p.yellow },
		["ui.float"] = { bg = p.bg_alt, fg = p.fg },
		["ui.float.border"] = { bg = p.bg_alt, fg = p.gutter },
		["ui.float.title"] = { bg = p.bg_alt, fg = p.fg, bold = true },
		["ui.panel"] = { bg = p.bg_alt, fg = p.fg },
		["ui.panel.border"] = { fg = p.gutter },
		["ui.panel.title"] = { fg = p.fg, bold = true },
		["ui.pane.border"] = { fg = p.gutter },
		["ui.tabline"] = { bg = p.bg_alt, fg = p.comment },
		["ui.tabline.active"] = { bg = accent, fg = p.bg, bold = true },
		["ui.menu.selected"] = { bg = p.bg_high, fg = p.fg },
		["ui.menu.match"] = { fg = p.yellow, bold = true },
		["ui.menu.doc"] = { fg = p.comment },
		["ui.button"] = { bg = p.bg_high, fg = p.fg },
		["ui.signature.parameter"] = { fg = p.yellow, bold = true },
		["ui.search.match"] = { bg = p.yellow, fg = p.bg },
		["ui.grep.location"] = { fg = p.cyan },
		["ui.flash"] = { bg = p.yellow, fg = p.bg },
		["ui.jump.label"] = { fg = p.red, bold = true },
		["ui.health.found"] = { fg = p.green },
		["ui.health.missing"] = { fg = p.comment },
		["ui.tree.directory"] = { fg = p.blue, bold = true },
		["ui.tree.open"] = { bg = p.bg_high },
		["ui.multibuffer.file"] = { fg = p.blue, bold = true },
		["ui.multibuffer.note"] = { fg = p.comment, italic = true },
		fold = { fg = p.comment },

		["diff.plus"] = { fg = p.green },
		["diff.minus"] = { fg = p.red, strikethrough = true },
		["diff.delta"] = { fg = p.yellow },
		["diff.plus.change"] = { fg = p.green, bold = true },
		["diff.minus.change"] = { fg = p.red, bold = true },

		["notes.todo"] = { fg = p.yellow },
		["notes.done"] = { fg = p.comment, strikethrough = true },
		["notes.done.box"] = { fg = p.green },
		["notes.heading"] = { fg = p.blue, bold = true },
		["notes.bullet"] = { fg = p.blue },
		["notes.due"] = { fg = p.cyan },
		["notes.overdue"] = { fg = p.red, bold = true },
		["notes.tag"] = { fg = p.purple },
		["notes.urgent"] = { fg = p.red, bold = true },

		keyword = { fg = keyword },
		["function"] = { fg = func },
		["function.macro"] = { fg = operator },
		constructor = { fg = func },
		string = { fg = str },
		["string.special"] = { fg = p.cyan },
		["string.regexp"] = { fg = p.orange },
		comment = { fg = p.comment, italic = true },
		type = { fg = typ },
		attribute = { fg = typ },
		label = { fg = typ },
		namespace = { fg = typ },
		constant = { fg = constant },
		["constant.character.escape"] = { fg = p.cyan, bold = true },
		operator = { fg = operator },
		["variable.builtin"] = { fg = p.red },
		punctuation = { fg = fg_alt },
		tag = { fg = func },
		special = { fg = p.cyan },

		["markup.heading"] = { fg = p.blue, bold = true },
		["markup.heading.marker"] = { fg = p.comment },
		["markup.list"] = { fg = keyword },
		["markup.bold"] = { bold = true },
		["markup.italic"] = { italic = true },
		["markup.strikethrough"] = { strikethrough = true },
		["markup.link"] = { fg = p.cyan, underline = "line" },
		["markup.link.url"] = { fg = p.cyan, underline = true },
		["markup.link.text"] = { fg = p.blue },
		["markup.link.label"] = { fg = p.blue },
		["markup.quote"] = { fg = p.comment, italic = true },
		["markup.raw"] = { fg = str },
	}
	for name, color in severity do
		styles[`ui.gutter.diagnostic.{name}`] = { fg = color }
		styles[`diagnostic.{name}`] =
			{ underline = if name == "hint" then "dotted" else "curl", underline_color = color }
		styles[`diagnostic.sign.{name}`] =
			{ fg = color, bold = name == "error" or name == "warning" }
		styles[`diagnostic.message.{name}`] = { fg = color, italic = true }
	end
	return styles
end

return M
