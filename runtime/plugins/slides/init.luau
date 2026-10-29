-- Slides from a Markdown file. A `---` line with a blank line above it
-- starts the next slide (right under text, `---` underlines a heading),
-- and front matter at the top isn't a slide. `:slides` (space m P) shows
-- the slide the cursor is on in a float over the whole screen, a view of
-- the file itself, so a block on a slide runs there and its result shows.
--
--   right, space, l, pagedown   the next     left, backspace, h, pageup   the one before
--   home, g            the first            end, G               the last
--   r                  run the block the cursor is on (it lands on the first)
--   q, esc             back to the file
--
-- A ```` ```notes ```` block at the end of a slide is what you'd say there:
-- it isn't shown on the slide.
--
-- The slides are a talk, and every client can show it: `:slides` on another
-- screen joins it, and `:slides-presenter` shows the slide with the notes,
-- the next slide and the time beside it. Going to another slide on any of
-- them goes there on all; q leaves one, and the talk ends with the last.

local greed = require("@greed")
local markdown = require("@markdown")
local blocks = require("@blocks")
local core = require("@core")

local M = {}

--- A slide: its first and last line (0-based) as shown, and its notes.
export type Slide = { first: number, last: number, notes: string? }

local function blank(text: string): boolean
	return string.find(text, "^%s*$") ~= nil
end

--- The slides in `buffer`, in order. Blank lines around a slide and the
--- notes at its end are left out of its lines.
function M.slides(buffer: greed.Buffer): { Slide }
	local s = markdown.structure(buffer)
	local out: { Slide } = {}
	-- Adds the slide from `first` to `last`, unless there's nothing on it.
	local function add(first: number, last: number)
		local notes: { string } = {}
		for _, code in s.code do
			if code.lang == "notes" and code.open >= first and code.close <= last then
				table.insert(notes, buffer:slice(code.code_from, code.code_to))
			end
		end
		while true do
			while first <= last and blank(s.lines[first + 1]) do
				first += 1
			end
			while last >= first and blank(s.lines[last + 1]) do
				last -= 1
			end
			local code = s.code_at[last]
			if last < first or code == nil or code.lang ~= "notes" then
				break
			end
			last = code.open - 1
		end
		if first <= last then
			table.insert(out, {
				first = first,
				last = last,
				notes = if #notes > 0 then table.concat(notes, "\n\n") else nil,
			})
		end
	end
	local start = if s.front then s.front + 1 else 0
	for line = start, #s.lines - 1 do
		local text = s.lines[line + 1]
		if string.find(text, "^%-%-%-%s*$") and not s.inside[line] and not s.heading_at[line] then
			add(start, line - 1)
			start = line + 1
		end
	end
	add(start, #s.lines - 1)
	return out
end

-- A talk: a deck shown on one screen or more, every one on the same slide.
-- Where that slide starts is followed through edits; `started` is when the
-- talk began, on `greed.now()`'s clock, and `images` the images its
-- pictures loaded, by file (false for one that didn't load).
type Talk = {
	buffer: greed.Buffer,
	at: greed.Anchor,
	started: number,
	images: { [string]: number | false },
	screens: { Screen },
}

-- A client showing a talk: a view of the deck narrowed to the slide, as
-- wide as `share` of the screen, and for a presenter, a view of the notes,
-- the next slide and the time beside it. `status_line` is whether the
-- client had its status line before.
type Screen = {
	talk: Talk,
	view: greed.View,
	client: number,
	share: number,
	status_line: boolean,
	notes: greed.View?,
}

-- Talks by their deck's buffer id, and the screens showing them by the id
-- of each of their views.
local talks: { [number]: Talk } = {}
local screens: { [number]: Screen } = {}

-- The slide `talk` is on, by its number, and every slide.
local function current(talk: Talk): (number, { Slide })
	local list = M.slides(talk.buffer)
	local line = talk.buffer:line_of(talk.at:pos() or 0)
	local n = 1
	for i, slide in list do
		if slide.first <= line then
			n = i
		end
	end
	return n, list
end

-- The first code block on `slide` that runs, if there's one: where the
-- cursor goes, so `r` runs it.
local function first_block(buffer: greed.Buffer, slide: Slide): number?
	for _, block in blocks.runnable(buffer) do
		local line = buffer:line_of(block.from)
		if line >= slide.first and line <= slide.last then
			return block.from
		end
	end
	return nil
end

greed.option.define({
	name = "slides-scale",
	doc = 'How many times bigger slides\' text is drawn, 1 to 4, in the window and in kitty, a big heading twice that; "fit" draws each slide as big as fits',
	default = 1,
})
greed.option.define({
	name = "slides-center",
	doc = "Center what's on a slide, across and down: each heading, and the rest as one block",
	default = false,
})
greed.option.define({
	name = "slides-margin",
	doc = "Cells left empty above and left of a slide",
	default = 2,
})

-- A setting for the deck: its front matter's (`slides-center: true`), or
-- the option's.
local function setting(s: markdown.Structure, name: string): any
	for n = 2, s.front or 0 do
		local key, value = string.match(s.lines[n], "^([%w%-]+):%s*(.-)%s*$")
		if key == name then
			if value == "true" or value == "false" then
				return value == "true"
			end
			return tonumber(value) or value
		end
	end
	return greed.option.get(name)
end

-- The room `screen`'s slide has inside its border, its share of the
-- client's screen, and whether that client draws scaled text bigger.
local function room(screen: Screen): (number, number, boolean)
	for _, client in greed.client.list() do
		local size = client.size
		if client.id == screen.client and size then
			return math.floor(size.width * screen.share) - 2, size.height - 2, client.scaled_text
		end
	end
	local rows, cols = screen.view:size()
	return cols or 80, rows or 24, true
end

-- How many rows `line` takes at `scale`: a big heading twice as many.
local function rows_at(s: markdown.Structure, line: number, scale: number): number
	local heading = s.heading_at[line]
	return if heading and heading.level == 1 then math.min(4, scale * 2) else scale
end

-- How wide and tall a line of a slide is drawn at a scale.
type SizeAt = (line: number, scale: number) -> (number, number)

-- The biggest scale, up to 4, at which `slide` fits in `cols` by `rows`.
local function fitting(slide: Slide, size_at: SizeAt, cols: number, rows: number): number
	for scale = 4, 2, -1 do
		local taken, widest = 0, 0
		for line = slide.first, slide.last do
			local w, h = size_at(line, scale)
			taken += h
			widest = math.max(widest, w)
		end
		if taken <= rows and widest <= cols then
			return scale
		end
	end
	return 1
end

-- A picture on a slide: the image, its description, and the cells it
-- takes.
type Picture = { id: number, alt: string, cols: number, rows: number }

-- The pictures on `slide`, by line: each on a line of its own, as big as
-- fits in `cols` by `rows` beside the slide's other lines, never bigger
-- than it is.
local function pictures(talk: Talk, slide: Slide, cols: number, rows: number): { [number]: Picture }
	local buffer = talk.buffer
	local out: { [number]: Picture } = {}
	local spare = math.max(1, rows - (slide.last - slide.first))
	for line = slide.first, slide.last do
		local alt, path = markdown.image_on_line(buffer, buffer:line_text(line))
		local id = if path then markdown.image(path, talk.images) else nil
		if id then
			local natural_cols, natural_rows = greed.image.cells(id)
			if natural_cols and natural_rows then
				local k = math.min(1, cols / natural_cols, spare / natural_rows)
				out[line] = {
					id = id,
					alt = alt or "",
					cols = math.max(1, math.floor(natural_cols * k)),
					rows = math.max(1, math.floor(natural_rows * k)),
				}
			end
		end
	end
	return out
end

-- Lays `slide` out on `screen` as the deck's settings say: its text
-- scaled, its pictures shown, and centered with margins around it.
local function lay_out(screen: Screen, slide: Slide)
	local view, buffer = screen.view, screen.talk.buffer
	local s = markdown.structure(buffer)
	local margin = math.max(0, tonumber(setting(s, "slides-margin")) or 0)
	local width, height, scales = room(screen)
	-- The room inside the margins.
	local cols, rows = width - 2 * margin, height - 2 * margin
	-- Measured without what this lays out.
	view:decorate("slides.scale", {})
	view:decorate("slides.center", {})
	view:decorate("slides.pictures", {})
	local shown = pictures(screen.talk, slide, cols, rows)
	-- Each line's width at scale 1: a big heading is drawn twice as wide
	-- already, so half that.
	local base: { [number]: number } = {}
	for line = slide.first, slide.last do
		base[line] = view:drawn_column(buffer:line_end(line)) / rows_at(s, line, 1)
	end
	local function size_at(line: number, k: number): (number, number)
		local picture = shown[line]
		if picture then
			return picture.cols, picture.rows
		end
		return base[line] * rows_at(s, line, k), rows_at(s, line, k)
	end
	-- Bigger only where it's drawn bigger: a terminal without kitty's text
	-- sizing would only spread the text out.
	local wanted = setting(s, "slides-scale")
	local scale = if not scales
		then 1
		elseif wanted == "fit" then fitting(slide, size_at, cols, rows)
		else math.clamp(tonumber(wanted) or 1, 1, 4)
	local drawn: { greed.Mark } = {}
	for line, picture in shown do
		-- Empty lines under it for the rows it takes.
		local below: { greed.MarkLine } = {}
		for _ = 2, picture.rows do
			table.insert(below, "")
		end
		local mark: greed.Mark = {
			from = buffer:line_start(line),
			to = buffer:line_end(line),
			style = "markdown.image",
			-- Where images can't show, the description does.
			text = picture.alt,
			conceal = true,
			reveal = "never",
			image = { id = picture.id, cols = picture.cols, rows = picture.rows },
			lines = below,
		}
		table.insert(drawn, mark)
	end
	view:decorate("slides.pictures", drawn)
	local scaled: { greed.Mark } = {}
	for line = slide.first, slide.last do
		local taken = rows_at(s, line, scale)
		if taken > 1 and not shown[line] then
			table.insert(scaled, {
				from = buffer:line_start(line),
				to = buffer:line_end(line),
				style = "",
				scale = taken,
			})
		end
	end
	view:decorate("slides.scale", scaled)
	local top, left = margin, margin
	if setting(s, "slides-center") == true then
		local taken = 0
		for line = slide.first, slide.last do
			taken += select(2, size_at(line, scale))
		end
		top += math.max(0, (rows - taken) // 2)
		-- Each heading and picture centered on its own, the rest as one
		-- block, so code and lists keep their indents.
		local function alone(line: number): boolean
			return s.heading_at[line] ~= nil or shown[line] ~= nil
		end
		local function shift(line: number): number
			return math.max(0, (cols - (size_at(line, scale))) // 2)
		end
		local block = 0
		for line = slide.first, slide.last do
			if not alone(line) then
				block = math.max(block, (size_at(line, scale)))
			end
		end
		local body = math.max(0, (cols - block) // 2)
		local shifts: { [number]: number } = {}
		local least = body
		for line = slide.first, slide.last do
			shifts[line] = if alone(line) then shift(line) else body
			least = math.min(least, shifts[line])
		end
		-- What every line moves by is padding, which moves a list's bullet
		-- too; spaces before a line move it further.
		left += least
		local spaces: { greed.Mark } = {}
		for line, by in shifts do
			if by > least then
				local start = buffer:line_start(line)
				local text = string.rep(" ", by - least)
				table.insert(spaces, { from = start, to = start, style = "", text = text })
			end
		end
		view:decorate("slides.center", spaces)
	end
	view:set_padding({ top = top, left = left })
end

-- What a presenter sees beside the slide: where the talk is and how long
-- it's gone, the slide's notes, and the start of the next slide.
local function notes_text(talk: Talk, n: number, list: { Slide }): string
	local seconds = math.floor((greed.now() - talk.started) / 1000)
	local slide, upcoming = list[n], list[n + 1]
	local out = {
		`Slide {n} of {#list} · {seconds // 60}:{string.format("%02d", seconds % 60)}`,
		"",
		"## Notes",
		"",
		if slide and slide.notes then slide.notes else "No notes for this slide.",
		"",
		"## Next",
		"",
	}
	if upcoming then
		local buffer = talk.buffer
		for line = upcoming.first, math.min(upcoming.last, upcoming.first + 5) do
			table.insert(out, buffer:line_text(line))
		end
	else
		table.insert(out, "The end.")
	end
	return table.concat(out, "\n")
end

-- Writes the notes on `screen`, a presenter's, as they are now.
local function draw_notes(screen: Screen, n: number, list: { Slide })
	local notes = screen.notes
	if notes == nil or not notes:valid() then
		return
	end
	local buffer = notes:buffer()
	local text = notes_text(screen.talk, n, list)
	if buffer:text() ~= text then
		buffer:set_readonly(false)
		buffer:edit(function(e)
			e:replace(0, buffer:len(), text)
		end, { undo = false })
		buffer:set_readonly(true)
	end
end

-- Shows slide `n` of `list` on `screen`; with `go`, its cursor goes to it.
local function draw_screen(screen: Screen, n: number, list: { Slide }, go: boolean?)
	local slide = list[n]
	local view = screen.view
	if slide == nil or not view:valid() then
		return
	end
	local buffer = screen.talk.buffer
	local block = first_block(buffer, slide)
	if go then
		view:set_cursor(block or buffer:line_start(slide.first))
	end
	-- The cursor shows where it does something: on a block, to run.
	view:hide_cursor(block == nil)
	view:narrow(slide.first, slide.last)
	view:configure({ label = `{n}/{#list}` })
	lay_out(screen, slide)
	draw_notes(screen, n, list)
end

-- Shows the slide `talk` is on on every screen; with `go`, it's a slide
-- just gone to, and the cursors go there.
local function draw(talk: Talk, go: boolean?)
	local n, list = current(talk)
	for _, screen in talk.screens do
		draw_screen(screen, n, list, go)
	end
end

-- The views `screen` shows: its slide's, and its notes' if it has them.
local function views_of(screen: Screen): { greed.View }
	local out = { screen.view }
	local notes = screen.notes
	if notes then
		table.insert(out, notes)
	end
	return out
end

-- Takes `screen` off its talk, giving its client back the status line it
-- had; the talk ends with its last screen.
local function forget(screen: Screen)
	local talk = screen.talk
	for _, view in views_of(screen) do
		screens[view:id()] = nil
	end
	local i = table.find(talk.screens, screen)
	if i then
		table.remove(talk.screens, i)
	end
	-- The client may have gone meanwhile.
	pcall(greed.client.set_status_line, screen.status_line, screen.client)
	if #talk.screens == 0 then
		talks[talk.buffer:id()] = nil
		talk.at:forget()
		for _, id in talk.images do
			if type(id) == "number" then
				greed.image.forget(id)
			end
		end
	end
end

-- Takes `screen` off its talk and closes its views.
local function stop(screen: Screen)
	forget(screen)
	for _, view in views_of(screen) do
		if view:valid() then
			view:close()
		end
	end
end

-- The screen the focused view is part of, if it is.
local function focused(ctx: greed.Context): Screen?
	return screens[ctx.view:id()]
end

-- A command moving the talk the focused view shows to the slide `to`
-- picks, from the one it's on (`n`) of `count`, on every screen.
local function moving(name: string, doc: string, to: (n: number, count: number) -> number)
	greed.command({
		name = name,
		doc = doc,
		run = function(ctx)
			local screen = focused(ctx)
			if screen == nil then
				return
			end
			local talk = screen.talk
			local n, list = current(talk)
			local slide = list[math.clamp(to(n, #list), 1, math.max(#list, 1))]
			if slide then
				talk.at:forget()
				talk.at = talk.buffer:track(talk.buffer:line_start(slide.first))
				draw(talk, true)
			end
		end,
	})
end

moving("slide-next", "Go to the next slide, on every screen showing the slides", function(n)
	return n + 1
end)
moving("slide-prev", "Go to the slide before, on every screen showing the slides", function(n)
	return n - 1
end)
moving("slide-first", "Go to the first slide, on every screen showing the slides", function()
	return 1
end)
moving("slide-last", "Go to the last slide, on every screen showing the slides", function(_, count)
	return count
end)

greed.command({
	name = "slides-stop",
	doc = "Stop showing slides here and go back to the file; other screens go on",
	run = function(ctx)
		local screen = focused(ctx)
		if screen then
			stop(screen)
		end
	end,
})

local KEYS = {
	right = "slide-next",
	space = "slide-next",
	l = "slide-next",
	pagedown = "slide-next",
	left = "slide-prev",
	backspace = "slide-prev",
	h = "slide-prev",
	pageup = "slide-prev",
	home = "slide-first",
	g = "slide-first",
	["end"] = "slide-last",
	G = "slide-last",
	-- The cursor lands on the slide's first block, so this runs it, as you.
	r = "block-run",
	q = "slides-stop",
	esc = "slides-stop",
}

-- The talk to show on this client: the one about the focused file, or the
-- only one going, or a new one about the focused file, from the slide its
-- cursor is on. Nil and why when there's none to show.
local function talk_for(ctx: greed.Context): (Talk?, string?)
	local buffer = ctx.buffer
	local going = talks[buffer:id()]
	if going then
		return going, nil
	end
	if buffer:language() ~= "markdown" then
		local id, only = next(talks)
		if id and next(talks, id) == nil then
			return only, nil
		end
		return nil, "slides come from a Markdown file"
	end
	if #M.slides(buffer) == 0 then
		return nil, "there's nothing on any slide here"
	end
	local talk: Talk = {
		buffer = buffer,
		at = buffer:track(ctx.view:cursor()),
		started = greed.now(),
		images = {},
		screens = {},
	}
	talks[buffer:id()] = talk
	-- The time on the presenter's notes keeps up while the talk goes on.
	greed.spawn(function()
		while talks[buffer:id()] == talk do
			greed.sleep(1000)
			if talks[buffer:id()] == talk then
				local n, list = current(talk)
				for _, screen in talk.screens do
					draw_notes(screen, n, list)
				end
			end
		end
	end)
	return talk, nil
end

-- Shows `talk` on this client: the slide over the whole screen, or for a
-- presenter (`presenting`), on the left with the notes on the right.
local function show(talk: Talk, presenting: boolean)
	local buffer = talk.buffer
	local title = core.project.basename(buffer:path() or "") or "slides"
	local share = if presenting then 0.6 else 1
	local notes: greed.View? = nil
	if presenting then
		local text =
			greed.create_buffer("slides-notes", "", { readonly = true, language = "markdown" })
		notes = greed.float(text, {
			x = "60%",
			y = 0,
			width = "40%",
			height = "100%",
			title = "notes",
			focus = false,
		})
	end
	local view = greed.float(buffer, {
		x = 0,
		y = 0,
		width = if presenting then "60%" else "100%",
		height = "100%",
		title = title,
		footer = "← → slides · r runs · q back",
	})
	local client = greed.client.current()
	local screen: Screen = {
		talk = talk,
		view = view,
		client = client.id,
		share = share,
		status_line = client.status_line,
		notes = notes,
	}
	table.insert(talk.screens, screen)
	for _, shown in views_of(screen) do
		screens[shown:id()] = screen
		shown:set_keys(KEYS)
	end
	-- Problems a language server found, like a prose checker's, aren't
	-- part of the talk, nor is the status line.
	view:hide_marks({ "diagnostics", "lsp" })
	greed.client.set_status_line(false)
	local n, list = current(talk)
	draw_screen(screen, n, list, true)
end

-- A command showing the talk `talk_for` picks on this client.
local function showing(name: string, doc: string, presenting: boolean)
	greed.command({
		name = name,
		doc = doc,
		run = function(ctx)
			local talk, why = talk_for(ctx)
			if talk then
				show(talk, presenting)
			else
				greed.echo(why or "")
			end
		end,
	})
end

showing(
	"slides",
	"Show this Markdown file as slides, from the one the cursor is on, or join the slides another screen shows",
	false
)
showing(
	"slides-presenter",
	"Show the slides with their notes, the next slide and the time beside them, for whoever presents",
	true
)

-- What a slide shows changes as its file does, like a block's result
-- coming in: every screen is narrowed to the slide again.
greed.on("buffer.changed", function(event: greed.BufferChanged)
	local talk = talks[event.buffer:id()]
	if talk then
		draw(talk)
	end
end)

-- Centered slides are laid out for the room they have.
greed.on("view.resized", function(event: greed.ViewResized)
	local screen = screens[event.view:id()]
	if screen and event.view == screen.view then
		local n, list = current(screen.talk)
		draw_screen(screen, n, list)
	end
end)

-- A screen whose slide or notes close goes, the other view with it.
greed.on("view.closed", function(event: greed.ViewClosed)
	local screen = screens[event.view]
	if screen then
		stop(screen)
	end
end)

greed.keymap.bind({ layer = "leader" }, { ["m P"] = "slides" })

return M
