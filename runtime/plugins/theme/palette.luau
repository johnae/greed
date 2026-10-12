-- A whole theme from a few colors: the backgrounds, the text and a set of
-- hues, with optional colors for the syntax roles where a theme departs
-- from the usual (Nord's keywords are blue, Dracula's are pink).

local greed = require("@greed")
local effects = require("@core").effects

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

--- Every style name Greed and its plugins use, from `p`.
function M.styles(p: Palette): { [string]: greed.ThemeEntry }
	local fg_alt = p.fg_alt or p.fg
	local accent = p.accent or p.blue
	-- What lit letters glow towards: brighter text on a dark theme, the
	-- accent on a light one.
	local bg, text = effects.rgb(p.bg), effects.rgb(p.fg)
	local glow = if bg
			and text
			and effects.lightness(bg) < 0.5
		then effects.mix(text, { 255, 255, 255 }, 0.7)
		else accent
	-- A little of `color` over the background, for highlights that fade.
	local function tint(color: string, amount: number): string
		local over = effects.rgb(color)
		return if bg and over then effects.mix(bg, over, amount) else p.selection
	end
	local keyword = p.keyword or p.purple
	local func = p.func or p.blue
	local str = p.string or p.green
	local typ = p.type or p.yellow
	local constant = p.constant or p.orange
	local operator = p.operator or p.cyan
	local severity: { [string]: string } =
		{ error = p.red, warning = p.yellow, info = p.blue, hint = p.cyan }
	-- What only the window draws: fonts, and controls in place of text.
	local prose: greed.Style = { font = "prose" }
	local mono: greed.Style = { font = "mono" }
	local empty_box: greed.Style = { checkbox = "empty" }
	local checked_box: greed.Style = { checkbox = "checked" }
	local choice: greed.Style = { checkbox = "choice", hover = true }
	local chosen: greed.Style = { checkbox = "chosen", hover = true }
	local styles: { [string]: greed.ThemeEntry } = {
		["ui.text"] = { fg = p.fg, bg = p.bg },
		["ui.gutter"] = { fg = p.gutter },
		["ui.selection"] = { bg = p.selection },
		["ui.cursor"] = { reverse = true },
		["ui.statusline"] = { bg = p.bg_alt, fg = fg_alt },
		["ui.statusline.mode"] = { bg = p.green, fg = p.bg, bold = true },
		["ui.statusline.message"] = { fg = p.yellow },
		["ui.statusline.warning"] = { fg = p.red, bold = true },
		["ui.statusline.dim"] = { fg = p.comment },
		["ui.statusline.tab"] = { bg = accent, fg = p.bg },
		["ui.statusline.tab.number"] = { bg = p.yellow, fg = p.bg, bold = true },
		["ui.statusline.host"] = { bg = p.cyan, fg = p.bg },
		["ui.statusline.session"] = { bg = p.blue, fg = p.bg, bold = true },
		["ui.float"] = { bg = p.bg_alt, fg = p.fg, gui = { rounded = true, shadow = true } },
		["ui.float.border"] = { bg = p.bg_alt, fg = p.gutter },
		["ui.float.title"] = { bg = p.bg_alt, fg = p.fg, bold = true },
		["ui.float.hint"] = { bg = p.bg_alt, fg = p.comment },
		["ui.screen.note"] = { fg = p.comment, italic = true },
		["ui.float.attention"] = { bg = p.bg_alt, fg = p.yellow, bold = true },
		["ui.panel"] = { bg = p.bg_alt, fg = p.fg },
		["ui.panel.border"] = { fg = p.gutter },
		["ui.panel.title"] = { fg = p.fg, bold = true },
		["ui.pane.border"] = { fg = p.gutter },
		["ui.pane.inactive"] = {},
		["ui.pane.label"] = { bg = p.yellow, fg = p.bg, bold = true },
		["ui.tabline"] = { bg = p.bg_alt, fg = p.comment },
		["ui.tabline.active"] = { bg = accent, fg = p.bg, bold = true },
		["ui.menu.selected"] = { bg = p.selection, fg = p.fg },
		["ui.menu.match"] = { fg = p.yellow, bold = true },
		["ui.menu.doc"] = { fg = p.comment },
		["ui.menu.badge"] = { fg = accent },
		["ui.button"] = { bg = p.bg_high, fg = p.fg, gui = { badge = true, hover = true } },
		["ui.signature.parameter"] = { fg = p.yellow, bold = true },
		["ui.search.match"] = { bg = p.yellow, fg = p.bg },
		["ui.grep.location"] = { fg = p.cyan },
		["ui.flash"] = { bg = p.yellow, fg = p.bg },
		-- Text someone else changed, and the line a jump landed on: faint,
		-- and fading to the background (core.effects).
		["ui.changed"] = { bg = tint(p.yellow, 0.3) },
		["ui.jumped"] = { bg = tint(accent, 0.28) },
		["ui.jump.label"] = { fg = p.red, bold = true },
		["ui.motion.hint"] = { fg = p.bg, bg = p.yellow, bold = true, gui = { badge = true } },
		["ui.motion.hint.far"] = {
			fg = p.bg,
			bg = p.fg_alt or p.fg,
			bold = true,
			gui = { badge = true },
		},
		["ui.health.found"] = { fg = p.green },
		["ui.health.missing"] = { fg = p.comment },
		["ui.tree.directory"] = { fg = p.blue, bold = true },
		["ui.tree.open"] = { bg = p.bg_high },
		["ui.tree.guide"] = { fg = p.gutter },
		["ui.tree.hover"] = { bg = p.selection },
		["markdown.text"] = { gui = prose },
		["markdown.marker"] = { fg = p.comment },
		["markdown.heading"] = { fg = p.blue, bold = true },
		["markdown.heading.1"] = { fg = p.purple, bold = true },
		["markdown.heading.2"] = { fg = p.blue, bold = true },
		["markdown.bold"] = { bold = true },
		["markdown.italic"] = { italic = true },
		["markdown.strike"] = { fg = p.comment, strikethrough = true },
		["markdown.code"] = { fg = p.green, bg = p.bg_high, gui = mono },
		["markdown.code.block"] = { bg = p.bg_alt },
		["markdown.code.block.result"] = { bg = p.bg_alt, fg = p.fg_alt or p.fg },
		["blocks.run"] = { fg = p.green, gui = { bg = p.bg_high, badge = true } },
		["blocks.running"] = { fg = p.yellow },
		["markdown.fence"] = { fg = p.comment },
		["markdown.link"] = { fg = p.blue, underline = true },
		["markdown.value"] = { fg = p.green },
		["markdown.value.error"] = { fg = p.red },
		["markdown.field"] = { bg = p.bg_high, fg = p.fg, gui = { badge = true, hover = true } },
		["markdown.quote"] = { fg = p.comment, italic = true },
		["markdown.quote.bar"] = { fg = p.purple },
		["markdown.rule"] = { fg = p.gutter },
		["markdown.bullet"] = { fg = p.blue },
		["markdown.table"] = { fg = p.gutter, gui = mono },
		["markdown.table.header"] = { bold = true, gui = mono },
		["markdown.table.cell"] = { gui = mono },
		["markdown.image"] = { fg = p.purple, italic = true },
		["ui.multibuffer.file"] = { fg = p.blue, bold = true },
		["ui.multibuffer.note"] = { fg = p.comment, italic = true },
		["agent.you"] = { bg = p.bg_high },
		["agent.you.bar"] = { fg = p.blue },
		["agent.bar"] = { fg = p.purple },
		["agent.box"] = { fg = p.gutter },
		["agent.box.title"] = { fg = p.fg, bold = true },
		["agent.auto"] = { bg = p.green, fg = p.bg, bold = true, gui = { badge = true } },
		["agent.manual"] = { bg = p.bg_high, fg = p.fg, bold = true, gui = { badge = true } },
		["agent.hint"] = { fg = p.comment },
		["agent.picked"] = { bg = tint(accent, 0.28) },
		["agent.working"] = { fg = p.yellow },
		["agent.waiting"] = { bg = p.yellow, fg = p.bg, bold = true },
		["agent.done"] = { fg = p.green },
		["agent.failed"] = { fg = p.red },
		["shell.prompt"] = { fg = p.blue, bold = true },
		["shell.agent"] = { fg = p.purple, bold = true },
		["shell.cwd"] = { fg = p.comment },
		["shell.segment"] = { fg = p.cyan },
		["shell.segment.git"] = { fg = p.purple },
		["shell.segment.kubernetes"] = { fg = p.blue },
		["shell.segment.environment"] = { fg = p.cyan },
		["shell.segment.warning"] = { fg = p.red, bold = true },
		["shell.prompt.warning"] = { fg = p.red, bold = true },
		["shell.status"] = { fg = p.comment },
		["shell.number"] = { fg = p.comment },
		["shell.running"] = { fg = p.yellow },
		["shell.done"] = { fg = p.green },
		["shell.failed"] = { fg = p.red },
		["shell.stderr"] = { fg = p.red },
		["shell.separator"] = { fg = p.gutter },
		["shell.suggestion"] = { fg = p.comment },
		["shell.changed"] = { fg = p.yellow },
		["shell.table.header"] = { fg = p.comment, bold = true },
		["shell.table.good"] = { fg = p.green },
		["shell.table.bad"] = { fg = p.red },
		["shell.table.warn"] = { fg = p.yellow },
		["shell.table.dim"] = { fg = p.comment },
		["shell.log.time"] = { fg = p.comment },
		["shell.log.error"] = { fg = p.red, bold = true },
		["shell.log.warn"] = { fg = p.yellow },
		["shell.log.info"] = { fg = p.green },
		["shell.log.debug"] = { fg = p.comment },
		["shell.log.field"] = { fg = p.comment },
		["shell.log.message"] = { fg = p.fg },
		-- Charts: up to eight series, then the axes and words around them.
		["chart.series.1"] = { fg = p.blue },
		["chart.series.2"] = { fg = p.orange },
		["chart.series.3"] = { fg = p.green },
		["chart.series.4"] = { fg = p.purple },
		["chart.series.5"] = { fg = p.cyan },
		["chart.series.6"] = { fg = p.red },
		["chart.series.7"] = { fg = p.yellow },
		["chart.series.8"] = { fg = p.fg },
		["chart.axis"] = { fg = p.gutter },
		["chart.grid"] = { fg = p.gutter },
		["chart.label"] = { fg = p.comment },
		["chart.title"] = { fg = p.fg, bold = true },
		["shell.strip"] = { italic = true },
		["shell.selected"] = { bg = p.bg_alt },
		["shell.hint"] = { fg = p.comment, italic = true },
		fold = { fg = p.comment },
		["ui.glow"] = { fg = glow },

		["diff.plus"] = { fg = p.green },
		["diff.minus"] = { fg = p.red, strikethrough = true },
		["diff.delta"] = { fg = p.yellow },
		["diff.plus.change"] = { fg = p.green, bold = true },
		["diff.minus.change"] = { fg = p.red, bold = true },

		["notes.todo"] = { fg = p.yellow, gui = empty_box },
		["notes.done"] = { fg = p.comment, strikethrough = true },
		["notes.done.box"] = { fg = p.green, gui = checked_box },
		["markdown.choice"] = { fg = p.comment, gui = choice },
		["markdown.chosen"] = { fg = p.blue, gui = chosen },
		["notes.heading"] = { fg = p.blue, bold = true },
		["notes.bullet"] = { fg = p.blue },
		["notes.due"] = { fg = p.cyan },
		["notes.overdue"] = { fg = p.red, bold = true },
		["notes.due.today"] = { fg = p.yellow, bold = true },
		["notes.due.soon"] = { fg = p.yellow },
		["notes.remind"] = { fg = p.purple },
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
	-- Other clients' cursors and selections, in each client's color.
	for n, hue in { p.purple, p.green, p.yellow, p.cyan, p.red, p.blue } do
		styles[`ui.cursor.peer.{n}`] = { bg = hue, fg = p.bg }
		styles[`ui.selection.peer.{n}`] = { underline = true, underline_color = hue }
	end
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
