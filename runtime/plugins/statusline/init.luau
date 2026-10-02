-- The status line: on the left the mode, the tab, the file (or the latest
-- message) and whether keys are being recorded; on the right problems the
-- language server found, where the cursor is, the machine and the session.
-- With the statusline-pills option some are pills, with rounded ends drawn
-- in the theme's colors, and with the effects option a wave of light goes
-- through the tab, the file or the mode when they change.
--
-- Add to it from your config, or take a piece away:
--
--     local statusline = require("@statusline")
--     statusline.add("right", "clock", function() return os.date("%H:%M") end)
--     statusline.remove("host")
--
-- `kern.statusline` with a function of your own replaces it all; the last
-- one set wins.

local kern = require("@kern")
local core = require("@core")
local style = core.style
local effects = core.effects

kern.option.define({
	name = "statusline-pills",
	doc = "Show the mode, tab, machine and session in the status line as pills in their colors",
	default = false,
})

kern.option.define({
	name = "statusline-caps",
	doc = 'The ends of status line pills: "round" (needs a Nerd Font) or "none"',
	default = "round",
})

--- What a piece of the status line shows: text, or a pill in a style with
--- rounded ends. A piece made of several pills, like the tab's number and
--- name, gives a list.
export type Pill = { text: string, style: string? }
export type Part = string | Pill | { Pill }
export type Piece = (ctx: kern.StatusContext) -> Part?

type Entry = { name: string, build: Piece }

local M = {}

M.left = {} :: { Entry }
M.right = {} :: { Entry }

--- Adds a piece called `name` to the `side` ("left" or "right"), at its end
--- or before the piece called `before`. A piece returns nil to show nothing.
function M.add(side: "left" | "right", name: string, build: Piece, before: string?)
	local list = if side == "left" then M.left else M.right
	local at = #list + 1
	for i, entry in list do
		if entry.name == before then
			at = i
			break
		end
	end
	table.insert(list, at, { name = name, build = build })
end

--- Takes the piece called `name` away, from either side.
function M.remove(name: string)
	for _, list in { M.left, M.right } do
		for i, entry in list do
			if entry.name == name then
				table.remove(list, i)
				return
			end
		end
	end
end

-- The machine's name, read once.
local host: string? = nil
local function machine(): string?
	if host == nil then
		local named = kern.fs.read("/etc/hostname")
		host = named and string.match(named, "^%s*(%S+)") or ""
	end
	return if host ~= "" then host else nil
end

-- Without /etc/hostname (macOS), `hostname` says, once the editor runs.
kern.on("editor.started", function()
	if machine() == nil then
		local done = kern.process.run({ "hostname" })
		host = done and done.code == 0 and string.match(done.stdout, "^%s*(%S+)") or ""
	end
end)

-- A pill showing `text` in the style `look`, or nothing without text.
local function pill(text: string?, look: string): Part?
	if text == nil then
		return nil
	end
	local made: Pill = { text = text, style = look }
	return made
end

M.add("left", "mode", function(ctx)
	return pill(string.upper(style.label(ctx.mode)), "ui.statusline.mode")
end)

M.add("left", "tab", function()
	local tabs = kern.tab.list()
	for i, tab in tabs do
		if tab.current then
			local name = tab.name or string.match(kern.project.current().root, "[^/]+$") or "tab"
			local parts: { Pill } = {
				{ text = tostring(i), style = "ui.statusline.tab.number" },
				{ text = name, style = "ui.statusline.tab" },
			}
			return parts
		end
	end
	return nil
end)

M.add("left", "file", function(ctx)
	if ctx.message then
		return pill(ctx.message, "ui.statusline.message")
	end
	local name = ctx.buffer:path() or "[scratch]"
	-- Files in the project show from its root.
	local root = kern.project.current().root .. "/"
	if string.sub(name, 1, #root) == root then
		name = string.sub(name, #root + 1)
	end
	return if ctx.buffer:modified() then name .. " [+]" else name
end)

M.add("left", "macro", function()
	local macro = core.registers.recording()
	return pill(macro and `recording @{macro}`, "ui.statusline.message")
end)

-- Counts of errors and warnings from the language server, if any.
M.add("right", "problems", function(ctx)
	local counts = { 0, 0 }
	for _, d in kern.lsp.diagnostics(ctx.buffer) do
		if d.severity <= 2 then
			counts[d.severity] += 1
		end
	end
	local parts = {}
	if counts[1] > 0 then
		table.insert(parts, `E{counts[1]}`)
	end
	if counts[2] > 0 then
		table.insert(parts, `W{counts[2]}`)
	end
	return if #parts > 0 then table.concat(parts, " ") else nil
end)

M.add("right", "position", function(ctx)
	local selection = ctx.view:selection()
	local head = selection.ranges[selection.primary].head
	local line = ctx.buffer:line_of(head)
	local column = (utf8.len(ctx.buffer:slice(ctx.buffer:line_start(line), head)) or 0) + 1
	return `{line + 1}:{column}`
end)

M.add("right", "host", function()
	return pill(machine(), "ui.statusline.host")
end)

M.add("right", "session", function()
	return pill(kern.session.current(), "ui.statusline.session")
end)

-- A theme entry's color as an inline style can take it.
local function color(name: string, key: "fg" | "bg"): string?
	local entry = kern.theme.get(name)
	return entry and (entry :: any)[key]
end

-- Pieces a wave of light is going through, and how far it has got, from 0
-- to 1.
local waves: { [string]: number } = {}

-- How long a wave takes to go through a piece, in milliseconds.
local WAVE = 600

-- The color lit letters glow towards on the background `back`: the theme's
-- glow if it stands apart enough, or else white or black, whichever stands
-- apart more.
local function glow_for(back: { number }): { number }
	local glow = effects.rgb(color("ui.glow", "fg"))
	if glow and effects.contrast(glow, back) >= 0.35 then
		return glow
	end
	return if effects.lightness(back) < 0.5 then { 255, 255, 255 } else { 0, 0, 0 }
end

-- `text` in the style `look` as one segment per character, each lit as the
-- wave `t` of the way through says. False when the colors aren't "#rrggbb".
local function lit(text: string, look: string, t: number, out: { kern.StatusSegment }): boolean
	local background = color(look, "bg") or color("ui.statusline", "bg")
	local fore = effects.rgb(color(look, "fg") or color("ui.statusline", "fg"))
	local back = effects.rgb(background)
	if fore == nil or back == nil then
		return false
	end
	local target = glow_for(back)
	local entry = kern.theme.get(look)
	local rest = ` bg:{background}{if entry and entry.bold then " bold" else ""}`
	local chars = {}
	for _, code in utf8.codes(text) do
		table.insert(chars, utf8.char(code))
	end
	for i, level in effects.wave(#chars, t) do
		table.insert(
			out,
			{ text = chars[i], style = `=fg:{effects.mix(fore, target, level)}{rest}` }
		)
	end
	return true
end

-- The pills of `part`, or nil for plain text.
local function pills(part: Part): { Pill }?
	if type(part) == "string" then
		return nil
	elseif (part :: Pill).text then
		local pill = part :: Pill
		return if pill.style then { pill } else nil
	end
	return part :: { Pill }
end

-- `text` in the style `look` (or plain), lit by the wave `t` if there is one.
local function text_in(text: string, look: string?, t: number?, out: { kern.StatusSegment })
	if t and lit(text, look or "ui.statusline", t, out) then
		return
	end
	table.insert(out, if look then { text = text, style = look } else text)
end

-- `part` as segments, lit by the wave `t` if there is one. With the
-- statusline-pills option, pills sit side by side between rounded ends in
-- their colors; without, only the mode keeps its colors and the rest is
-- plain text. Each piece has a space either side.
local function segments(part: Part, t: number?, out: { kern.StatusSegment })
	local list = pills(part)
	if list == nil or kern.option.get("statusline-pills") ~= true then
		local text: string, kept: string?
		if list == nil then
			text = if type(part) == "string" then part else (part :: Pill).text
		else
			local texts = {}
			for _, pill in list do
				table.insert(texts, pill.text)
			end
			text = table.concat(texts, " ")
			local look = list[1].style
			if look == "ui.statusline.mode" or look == "ui.statusline.message" then
				kept = look
			end
		end
		local space = if kept then { text = " ", style = kept } else " "
		table.insert(out, space)
		text_in(text, kept, t, out)
		table.insert(out, space)
		return
	end
	local round = kern.option.get("statusline-caps") == "round"
	local under = color("ui.statusline", "bg")
	local function cap(glyph: string, pill: Pill)
		local bg = color(pill.style :: string, "bg")
		if round and bg then
			local around = if under then ` bg:{under}` else ""
			table.insert(out, { text = glyph, style = `=fg:{bg}{around}` })
		else
			table.insert(out, " ")
		end
	end
	cap("\u{e0b6}", list[1])
	for _, pill in list do
		table.insert(out, { text = " ", style = pill.style })
		text_in(pill.text, pill.style, t, out)
		table.insert(out, { text = " ", style = pill.style })
	end
	cap("\u{e0b4}", list[#list])
end

--- The status line's segments for `ctx`, as built from the pieces.
function M.build(ctx: kern.StatusContext): kern.StatusParts
	local function side(list: { Entry }): { kern.StatusSegment }
		local out = {}
		for _, entry in list do
			local part = entry.build(ctx)
			if part then
				segments(part, waves[entry.name], out)
			end
		end
		return out
	end
	return { left = side(M.left), right = side(M.right) }
end

kern.statusline(M.build)

--- Sends a wave of light through the piece called `name`, with the effects
--- option on.
function M.wave(name: string)
	if not effects.enabled() then
		return
	end
	kern.animate(WAVE, function(t)
		waves[name] = if t < 1 then t else nil
	end)
end

-- What the waves follow: the shown tab and the main view's buffer.
local function where(): (number, number)
	return kern.tab.current().id, kern.view():buffer():id()
end

-- After a command or a click, a wave goes through what changed.
local function follow()
	if not effects.enabled() then
		return
	end
	local tab, buffer = where()
	-- Waits for the command to finish.
	kern.sleep(0)
	local now_tab, now_buffer = where()
	if now_tab ~= tab then
		M.wave("tab")
	end
	if now_buffer ~= buffer then
		M.wave("file")
	end
end

kern.on("command.run", follow)
kern.on("mouse", follow)
kern.on("mode.changed", function()
	M.wave("mode")
end)

return M
