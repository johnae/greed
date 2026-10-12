-- Small animations that say where you are and what just happened.
--
-- Two of them tell you something, so they are on unless you turn them off,
-- each with an option of its own:
--
-- - `effects-changes`: text someone other than you changed (an agent, a
--   formatter, a language server's rename, a plugin, the file changing on
--   disk) lights up where a view shows it, then fades out.
-- - `effects-jumps`: the line a jump lands on (a search hit, a definition,
--   the jumplist, a picker, a move of more than a screen) lights up
--   briefly; core.jumps says when.
--
-- `effects-dim` dims the panes you're not in (the theme plugin does that),
-- and `effects` turns on the ones that are only decoration, like a wave of
-- light through the status line's file name when you switch files. Both
-- are off unless you turn them on:
--
--     require("@greed").option.set("effects", true)
--
-- They take their colors from the theme. Fading needs "#rrggbb" colors;
-- with the terminal's 16 a highlight shows, then goes.

local greed = require("@greed")

greed.option.define({
	name = "effects",
	doc = "Small animations, like a wave of light through the status line when you switch files",
	default = false,
})

greed.option.define({
	name = "effects-changes",
	doc = "Light up text someone other than you changed, like an agent or a formatter, fading out",
	default = true,
})

greed.option.define({
	name = "effects-jumps",
	doc = "Light up the line a jump lands on, briefly",
	default = true,
})

greed.option.define({
	name = "effects-dim",
	doc = "Dim the text of the panes you're not in",
	default = false,
})

local M = {}

--- Whether effects are on.
function M.enabled(): boolean
	return greed.option.get("effects") == true
end

--- The red, green and blue of a "#rrggbb" color, or nil for another kind.
function M.rgb(color: string?): { number }?
	local r, g, b = string.match(color or "", "^#(%x%x)(%x%x)(%x%x)$")
	if r == nil then
		return nil
	end
	return { tonumber(r, 16) :: number, tonumber(g, 16) :: number, tonumber(b, 16) :: number }
end

--- The color `t` of the way from `from` to `to`, as "#rrggbb".
function M.mix(from: { number }, to: { number }, t: number): string
	local out = {}
	for i = 1, 3 do
		out[i] = math.floor(from[i] + (to[i] - from[i]) * t + 0.5)
	end
	return string.format("#%02x%02x%02x", out[1], out[2], out[3])
end

--- How light a color looks, from 0 to 1.
function M.lightness(color: { number }): number
	return (0.2126 * color[1] + 0.7152 * color[2] + 0.0722 * color[3]) / 255
end

--- How far apart two colors are, from 0 (the same) to about 441 (black and
--- white).
function M.distance(a: { number }, b: { number }): number
	return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2)
end

-- How many characters either side of a wave's middle light up.
local REACH = 3

-- Smooth at both ends rather than a sharp peak.
local function smooth(level: number): number
	return level * level * (3 - 2 * level)
end

--- How lit each of `count` characters is, from 0 to 1, as a wave `t` of
--- the way through them: brightest in its middle and fading either side.
function M.wave(count: number, t: number): { number }
	-- The middle starts before the first character and ends after the last,
	-- so the wave comes in and goes out.
	local middle = -REACH + t * (count - 1 + 2 * REACH)
	local lit = {}
	for i = 1, count do
		lit[i] = smooth(math.max(0, 1 - math.abs((i - 1) - middle) / REACH))
	end
	return lit
end

--- How lit each of `count` characters is, from 0 to 1, as a glow `t` of the
--- way through: it starts in their middle and spreads out both ways at
--- once, two crests fading out past the ends.
function M.burst(count: number, t: number): { number }
	local middle = (count - 1) / 2
	-- From the middle to past the ends.
	local reached = t * (middle + REACH)
	local lit = {}
	for i = 1, count do
		local from_middle = math.abs((i - 1) - middle)
		lit[i] = smooth(math.max(0, 1 - math.abs(from_middle - reached) / REACH)) * (1 - t)
	end
	return lit
end

-- How many steps a highlight fades out in. Each step is a theme entry, so a
-- terminal shows the same fade as the window, and a fade costs a redraw a
-- step rather than one a frame.
local STEPS = 8

-- The look each style's steps were last made from.
local made: { [string]: string } = {}

-- A theme entry as text, to tell whether it changed.
local function spelled(entry: { [string]: any }?): string
	local fields: { [string]: any } = entry or {}
	local parts = {}
	for key, value in fields do
		table.insert(parts, `{key}={if type(value) == "table" then spelled(value) else value}`)
	end
	table.sort(parts)
	return table.concat(parts, ",")
end

-- Sets the theme entries for `style`'s steps: "STYLE.STEPS" looks as
-- `style` does, and each step below it is closer to the text's background.
-- Without "#rrggbb" colors to mix, every step looks as `style` does.
local function make_steps(style: string)
	local entry = greed.theme.get(style)
	local text = greed.theme.get("ui.text")
	local background = text and text.bg
	local look = `{spelled(entry :: any)}|{background}`
	if made[style] == look then
		return
	end
	made[style] = look
	local from, to = M.rgb(background), M.rgb(entry and entry.bg)
	local base: greed.ThemeEntry = entry or {} :: any
	local entries: { [string]: greed.ThemeEntry } = {}
	for step = 1, STEPS do
		local shade = table.clone(base)
		if from and to then
			shade.bg = M.mix(from, to, step / STEPS)
		end
		entries[`{style}.{step}`] = shade
	end
	greed.theme.set(entries)
end

-- Restyles `buffer`'s highlights in `style` for the time `now`, dropping
-- those whose time is up. Returns when the next one changes step, or nil
-- once none are left.
local function restyle(buffer: greed.Buffer, style: string, now: number): number?
	local marks = {}
	local next: number? = nil
	for _, mark in buffer:decorations(style) do
		local data = mark.data
		local fades = data.start + (data.hold or 0)
		local left = 1 - math.max(now - fades, 0) / data.ms
		if left > 0 then
			local step = math.min(math.ceil(left * STEPS), STEPS)
			mark.style = `{style}.{step}`
			table.insert(marks, mark)
			local at = fades + data.ms * (1 - (step - 1) / STEPS)
			next = math.min(next or at, at)
		end
	end
	buffer:decorate(style, marks)
	return next
end

-- The buffers and styles with a fade going, as "ID STYLE".
local fading: { [string]: boolean } = {}

--- A range to light up: text, or with `line` the whole lines it touches.
export type Lit = { from: number, to: number, line: boolean? }

--- Lights up `ranges` of `buffer` in theme style `style` (its background),
--- holding for `hold` milliseconds, if given, then fading out over `ms`.
--- They are marks in the namespace `style`, so they move with edits; each
--- fades on its own, and once all are gone nothing runs.
function M.highlight(
	buffer: greed.Buffer,
	style: string,
	ranges: { Lit },
	ms: number,
	hold: number?
)
	if #ranges == 0 then
		return
	end
	make_steps(style)
	local start = greed.now()
	local marks = buffer:decorations(style)
	for _, range in ranges do
		table.insert(marks, {
			from = range.from,
			to = range.to,
			line = range.line,
			style = `{style}.{STEPS}`,
			data = { start = start, ms = ms, hold = hold },
		})
	end
	buffer:decorate(style, marks)
	local key = `{buffer:id()} {style}`
	if fading[key] then
		return
	end
	fading[key] = true
	greed.spawn(function()
		pcall(function()
			while buffer:valid() do
				local at = restyle(buffer, style, greed.now())
				if at == nil then
					break
				end
				greed.sleep(math.max(at - greed.now(), 1))
			end
		end)
		fading[key] = nil
	end)
end

-- How long changed text stays fully lit, then how long it takes to fade, in
-- milliseconds: long enough to catch from the corner of your eye.
local CHANGED_HOLD = 1000
local CHANGED_MS = 1500

-- An edit with more changes than this lights up only its first ones.
local MOST_CHANGES = 200

-- Where the text `entry` put in is in the text after it. Text with a line
-- break lights up as whole lines, and where text was only deleted, its line.
local function put_in(entry: greed.HistoryEntry): { Lit }
	local out = {}
	local shift = 0
	for i, change in entry.changes do
		if i > MOST_CHANGES then
			break
		end
		local from = change.from + shift
		local to = from + #change.text
		shift += #change.text - (change.to - change.from)
		if string.find(change.text, "\n", 1, true) then
			local last = if string.sub(change.text, -1) == "\n" then to - 1 else to
			table.insert(out, { from = from, to = math.max(last, from), line = true })
		else
			table.insert(out, { from = from, to = to, line = from == to })
		end
	end
	return out
end

-- The last edit looked at in each buffer, by id: an edit kept out of the
-- history leaves the one before it there, which isn't new.
local looked: { [number]: number } = {}

greed.on("buffer.changed", function(event: greed.BufferChanged)
	local buffer = event.buffer
	local ok, last = pcall(function(): greed.HistoryEntry?
		if buffer:path() == nil or buffer:readonly() then
			return nil
		end
		return buffer:history({ limit = 1 })[1]
	end)
	if not ok or last == nil or looked[buffer:id()] == last.id then
		return
	end
	looked[buffer:id()] = last.id
	if
		last.author ~= "user"
		and greed.option.get("effects-changes") == true
		and #buffer:views() > 0
	then
		M.highlight(buffer, "ui.changed", put_in(last), CHANGED_MS, CHANGED_HOLD)
	end
end)

greed.on("buffer.closed", function(event: greed.BufferClosed)
	looked[event.id] = nil
end)

-- How long the line a jump lands on stays lit, in milliseconds.
local JUMPED_MS = 400

--- Lights up the line `view`'s cursor is on, briefly, after a jump; see
--- core.jumps, which says when. Does nothing with `effects-jumps` off.
function M.jumped(view: greed.View)
	if greed.option.get("effects-jumps") ~= true then
		return
	end
	local pos = view:cursor()
	M.highlight(view:buffer(), "ui.jumped", { { from = pos, to = pos, line = true } }, JUMPED_MS)
end

return M
