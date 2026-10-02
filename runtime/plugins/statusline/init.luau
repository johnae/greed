-- The status line: on the left the mode, the tab, the file (or the latest
-- message) and whether keys are being recorded; on the right problems the
-- language server found, where the cursor is, the machine and the session.
-- Some are pills, with rounded ends drawn in the theme's colors.
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

-- `part` as segments: pills side by side between rounded ends in their
-- colors, or plain text with a space either side.
local function segments(part: Part, out: { kern.StatusSegment })
	local list = pills(part)
	if list == nil then
		local text = if type(part) == "string" then part else (part :: Pill).text
		table.insert(out, ` {text} `)
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
		table.insert(out, { text = ` {pill.text} `, style = pill.style })
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
				segments(part, out)
			end
		end
		return out
	end
	return { left = side(M.left), right = side(M.right) }
end

kern.statusline(M.build)

return M
