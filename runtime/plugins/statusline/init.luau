-- The status line: on the left the mode, the tab, the file (or the latest
-- message) and whether keys are being recorded; on the right the branch,
-- problems, the language and its server, anything unusual about the file,
-- how many selections there are, where the cursor is, the machine and the
-- session.
-- With the statusline-pills option some are pills, with rounded ends drawn
-- in the theme's colors, and with the effects option light goes through the
-- tab or the file when you go to another, and the mode when it changes.
--
-- Add to it from your config, or take a piece away:
--
--     local statusline = require("@statusline")
--     statusline.add("right", "clock", function() return os.date("%H:%M") end)
--     statusline.remove("host")
--
-- `greed.statusline` with a function of your own replaces it all; the last
-- one set wins.

local greed = require("@greed")
local core = require("@core")
local style = core.style
local effects = core.effects

greed.option.define({
	name = "statusline-pills",
	doc = "Show the mode, tab, machine and session in the status line as pills in their colors",
	default = false,
})

greed.option.define({
	name = "statusline-caps",
	doc = 'The ends of status line pills: "round" (needs a Nerd Font) or "none"',
	default = "round",
	choices = { "round", "none" },
})

--- What a piece of the status line shows: text, or a pill in a style with
--- rounded ends. A piece made of several pills, like the tab's number and
--- name, gives a list. A pill's `action` is a command a click on the piece
--- runs (the first pill's, for a list).
export type Pill = { text: string, style: string?, action: string? }
export type Part = string | Pill | { Pill }
export type Piece = (ctx: greed.StatusContext) -> Part?

type Entry = { name: string, build: Piece }

local M = {}

M.left = {} :: { Entry }
M.right = {} :: { Entry }

--- Adds a piece called `name` to the `side` ("left" or "right"), at its end
--- or before the piece called `before`. A piece returns nil to show nothing.
--- It goes when the plugin (or config) that added it does.
function M.add(side: "left" | "right", name: string, build: Piece, before: string?)
	local list: { Entry } = if side == "left" then M.left else M.right
	local entry = { name = name, build = build }
	local at = #list + 1
	for i, other in list do
		if other.name == before then
			at = i
			break
		end
	end
	table.insert(list, at, entry)
	greed.plugin.tie(core.registry.remover(list, entry))
end

--- How a piece that takes time to find refreshes: `refresh` runs the way a
--- command does, so it can wait on `greed.process.run`, `greed.http` and the
--- rest, and returns what to show. It runs when the editor starts, every
--- `every` milliseconds if given, and on each event in `on`.
export type AsyncPiece = {
	refresh: () -> Part?,
	every: number?,
	on: { string }?,
}

-- The async pieces shown, by name; one taken away stops refreshing.
local async: { [string]: AsyncPiece } = {}
-- What each async piece last found, and whether a refresh is running.
local found: { [string]: Part? } = {}
local refreshing: { [string]: boolean } = {}

-- Runs `spec.refresh` for the piece `name` unless it's already running or
-- was taken away, and keeps what it returns. A failing refresh shows
-- nothing.
local function refresh(name: string, spec: AsyncPiece)
	if refreshing[name] or async[name] ~= spec then
		return
	end
	refreshing[name] = true
	local ok, part = pcall(spec.refresh)
	refreshing[name] = false
	if async[name] == spec then
		found[name] = if ok then part else nil
	end
end

-- The events async pieces refresh on, each heard once for all of them.
local heard: { [string]: boolean } = {}

local function hear(event: string)
	if heard[event] then
		return
	end
	heard[event] = true
	local on = greed.on :: (event: string, handler: (any) -> ()) -> ()
	on(event, function()
		for name, spec in async do
			if spec.on and table.find(spec.on, event) then
				refresh(name, spec)
			end
		end
	end)
end

--- Adds a piece whose text takes time to find, like a repository's state in
--- a big monorepo, without the status line ever waiting for it: drawing shows
--- what the last refresh found. It goes, and stops refreshing, when the
--- plugin (or config) that added it does.
---
---     statusline.add_async("right", "change", {
---         refresh = function()
---             local done = greed.process.run({ "jj", "log", "-r", "@", "--no-graph", "-T", "change_id.short()" })
---             return done and done.code == 0 and done.stdout or nil
---         end,
---         every = 5000,
---         on = { "buffer.saved" },
---     })
function M.add_async(side: "left" | "right", name: string, spec: AsyncPiece, before: string?)
	async[name] = spec
	found[name] = nil
	M.add(side, name, function()
		return found[name]
	end, before)
	local events: { string } = spec.on or {}
	for _, event in events do
		hear(event)
	end
	greed.plugin.tie(function()
		if async[name] == spec then
			async[name] = nil
			found[name] = nil
		end
	end)
	greed.spawn(function()
		refresh(name, spec)
		while spec.every and async[name] == spec do
			greed.sleep(spec.every)
			refresh(name, spec)
		end
	end)
end

--- Takes the piece called `name` away, from either side.
function M.remove(name: string)
	async[name] = nil
	found[name] = nil
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
local host = greed.hostname()

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
	local tabs = greed.tab.list()
	for i, tab in tabs do
		if tab.current then
			local name = tab.name or core.project.basename(greed.project.current().root) or "tab"
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
	local path = ctx.buffer:path()
	-- Files in the project show from its root.
	local name = if path then core.project.relative(path) else "[scratch]"
	return if ctx.buffer:modified() then name .. " [+]" else name
end)

M.add("left", "macro", function()
	local macro = core.registers.recording()
	return pill(macro and `recording @{macro}`, "ui.statusline.message")
end)

-- Counts of errors and warnings from the language server, if any.
M.add("right", "problems", function(ctx)
	local counts = { 0, 0 }
	for _, d in greed.lsp.diagnostics(ctx.buffer) do
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

-- The language and the features on for the buffer, e.g. "markdown · notes".
M.add("right", "language", function(ctx)
	local language = ctx.buffer:language()
	if language == nil then
		return nil
	end
	local parts = { language }
	for _, feature in core.features.of(ctx.buffer) do
		table.insert(parts, feature)
	end
	return table.concat(parts, " · ")
end)

-- What's unusual about the file, and only that: Windows line breaks,
-- indented with tabs where its language indents with spaces (or the other
-- way round), or read-only, e.g. "CRLF · read-only".
M.add("right", "file-settings", function(ctx)
	local buffer = ctx.buffer
	local parts = {}
	local lines = buffer:line_count()
	if lines > 1 and buffer:char_at(buffer:line_end(0)) == "\r" then
		table.insert(parts, "CRLF")
	end
	-- How the first 200 lines start.
	local tabs, spaces = 0, 0
	for n = 0, math.min(lines, 200) - 1 do
		local first = buffer:char_at(buffer:line_start(n))
		if first == "\t" then
			tabs += 1
		elseif first == " " then
			spaces += 1
		end
	end
	local unit = core.indent.unit(buffer)
	if tabs > spaces and unit ~= "\t" then
		table.insert(parts, "tabs")
	elseif spaces > tabs and unit == "\t" then
		table.insert(parts, "spaces")
	end
	if buffer:readonly() then
		table.insert(parts, "read-only")
	end
	return if #parts > 0 then table.concat(parts, " · ") else nil
end)

-- How many selections there are, once there's more than one.
M.add("right", "selections", function(ctx)
	local count = #ctx.view:selection().ranges
	return if count > 1 then `{count} selections` else nil
end)

M.add("right", "position", function(ctx)
	local head = ctx.view:cursor()
	local line = ctx.buffer:line_of(head)
	local column = (utf8.len(ctx.buffer:slice(ctx.buffer:line_start(line), head)) or 0) + 1
	return `{line + 1}:{column}`
end)

M.add("right", "host", function()
	return pill(host, "ui.statusline.host")
end)

M.add("right", "session", function()
	return pill(greed.session.current(), "ui.statusline.session")
end)

-- A theme entry's color as an inline style can take it.
local function color(name: string, key: "fg" | "bg"): string?
	local entry = greed.theme.get(name)
	return entry and (entry :: any)[key]
end

-- How lit each of `count` letters is, `t` of the way through (from effects).
type Shape = (count: number, t: number) -> { number }

-- Light going through a piece, lit as `shape` says, `t` of the way through.
type Glow = { t: number, shape: Shape }

-- The pieces light is going through.
local glows: { [string]: Glow } = {}

-- The color letters of the color `fore` glow towards: the theme's glow if
-- it's far enough from them to see the change, or else white or black,
-- whichever is the way the glow lies (dark letters on a light pill light up
-- rather than go black).
local function glow_for(fore: { number }): { number }
	local glow = effects.rgb(color("ui.glow", "fg")) or { 255, 255, 255 }
	if effects.distance(glow, fore) >= 60 then
		return glow
	end
	return if effects.lightness(glow) >= effects.lightness(fore)
		then { 255, 255, 255 }
		else { 0, 0, 0 }
end

-- `text` in the style `look` as one segment per character, each lit as the
-- glow says. False when the colors aren't "#rrggbb".
local function lit(text: string, look: string, glow: Glow, out: { greed.StatusSegment }): boolean
	local background = color(look, "bg") or color("ui.statusline", "bg")
	local fore = effects.rgb(color(look, "fg") or color("ui.statusline", "fg"))
	local back = effects.rgb(background)
	if fore == nil or back == nil then
		return false
	end
	local target = glow_for(fore)
	local entry = greed.theme.get(look)
	local rest = ` bg:{background}{if entry and entry.bold then " bold" else ""}`
	local chars = {}
	for _, code in utf8.codes(text) do
		table.insert(chars, utf8.char(code))
	end
	for i, level in glow.shape(#chars, glow.t) do
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

-- `text` in the style `look` (or plain), lit by `glow` if there is one.
local function text_in(text: string, look: string?, glow: Glow?, out: { greed.StatusSegment })
	if glow and lit(text, look or "ui.statusline", glow, out) then
		return
	end
	table.insert(out, if look then { text = text, style = look } else text)
end

-- The styles pieces keep without the statusline-pills option.
local KEPT = {
	["ui.statusline.mode"] = true,
	["ui.statusline.message"] = true,
	["ui.statusline.warning"] = true,
}

-- `part` as segments, lit by `glow` if there is one. With the
-- statusline-pills option, pills sit side by side between rounded ends in
-- their colors; without, only the mode, messages and warnings
-- (`ui.statusline.warning`) keep their colors and the rest is plain text.
-- Each piece has a space either side.
local function segments(part: Part, glow: Glow?, out: { greed.StatusSegment })
	local list = pills(part)
	if list == nil or greed.option.get("statusline-pills") ~= true then
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
			if KEPT[look :: string] then
				kept = look
			end
		end
		local space: greed.StatusSegment = if kept then { text = " ", style = kept } else " "
		table.insert(out, space)
		text_in(text, kept, glow, out)
		table.insert(out, space)
		return
	end
	local round = greed.option.get("statusline-caps") == "round"
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
		text_in(pill.text, pill.style, glow, out)
		table.insert(out, { text = " ", style = pill.style })
	end
	cap("\u{e0b4}", list[#list])
	-- Room between one pill and the next.
	table.insert(out, " ")
end

-- The command a click on `part` runs, if it has one.
local function action_of(part: Part): string?
	if type(part) == "string" then
		return nil
	end
	local list = part :: { Pill }
	return (part :: Pill).action or (list[1] and list[1].action)
end

-- Makes the segments from `first` on run `action` when clicked: the whole
-- piece, its spaces and ends too.
local function clickable(out: { greed.StatusSegment }, first: number, action: string)
	for i = first, #out do
		local segment = out[i]
		out[i] = if type(segment) == "string"
			then { text = segment, action = action }
			else { text = segment.text, style = segment.style, action = action }
	end
end

--- The status line's segments for `ctx`, as built from the pieces.
function M.build(ctx: greed.StatusContext): greed.StatusParts
	local function side(list: { Entry }): { greed.StatusSegment }
		local out: { greed.StatusSegment } = {}
		for _, entry in list do
			local part = entry.build(ctx)
			if part then
				local first = #out + 1
				segments(part, glows[entry.name], out)
				local action = action_of(part)
				if action then
					clickable(out, first, action)
				end
			end
		end
		return out
	end
	return { left = side(M.left), right = side(M.right) }
end

greed.statusline(M.build)

--- Sends light through the piece called `name` for `ms` milliseconds, with
--- the effects option on: lit as `shape` says (effects.wave by default, a
--- wave going through it; effects.burst spreads out from its middle).
function M.glow(name: string, ms: number?, shape: Shape?)
	if not effects.enabled() then
		return
	end
	local glow: Glow = { t = 0, shape = shape or effects.wave }
	glows[name] = glow
	greed.animate(ms or 600, function(t)
		glow.t = t
		if t >= 1 and glows[name] == glow then
			glows[name] = nil
		end
	end)
end

-- What the light follows: the shown tab, and the file in its active pane,
-- so floats like the command line coming and going don't count.
local function where(): (number, string?)
	local tab = greed.tab.current()
	return tab.id, tab.active:buffer():path()
end

local shown_tab, shown_file = where()

-- Light goes through what changed: the tab pill for another tab, the file
-- for another file in the active pane.
local function follow()
	local tab, file = where()
	if effects.enabled() then
		if tab ~= shown_tab then
			M.glow("tab")
		elseif file ~= shown_file and file then
			M.glow("file")
		end
	end
	shown_tab, shown_file = tab, file
end

greed.on("view.focused", follow)
greed.on("selection.changed", follow)
-- A new mode glows from the middle of its name out.
greed.on("mode.changed", function()
	M.glow("mode", 450, effects.burst)
end)

return M
