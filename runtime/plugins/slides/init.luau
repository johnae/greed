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

-- A slide show: the view showing it, its file, where the slide on screen
-- starts, followed through edits, and the client showing it, with whether
-- that one had its status line before, and the images its pictures
-- loaded, by file (false for one that didn't load).
type Show = {
	view: greed.View,
	buffer: greed.Buffer,
	at: greed.Anchor,
	client: number,
	status_line: boolean,
	images: { [string]: number | false },
}

-- Slide shows by their view's id.
local shows: { [number]: Show } = {}

-- The slide `show` is on, by its number, and every slide.
local function current(show: Show): (number, { Slide })
	local list = M.slides(show.buffer)
	local line = show.buffer:line_of(show.at:pos() or 0)
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

-- The room the slides have inside their border, the screen of the client
-- showing them, and whether that one draws scaled text bigger.
local function room(show: Show): (number, number, boolean)
	for _, client in greed.client.list() do
		local size = client.size
		if client.id == show.client and size then
			return size.width - 2, size.height - 2, client.scaled_text
		end
	end
	local rows, cols = show.view:size()
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
local function pictures(show: Show, slide: Slide, cols: number, rows: number): { [number]: Picture }
	local buffer = show.buffer
	local out: { [number]: Picture } = {}
	local spare = math.max(1, rows - (slide.last - slide.first))
	for line = slide.first, slide.last do
		local alt, path = markdown.image_on_line(buffer, buffer:line_text(line))
		local id = if path then markdown.image(path, show.images) else nil
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

-- Lays `slide` out in `show` as the deck's settings say: its text scaled,
-- its pictures shown, and centered with margins around it.
local function lay_out(show: Show, slide: Slide)
	local view, buffer = show.view, show.buffer
	local s = markdown.structure(buffer)
	local margin = math.max(0, tonumber(setting(s, "slides-margin")) or 0)
	local width, height, scales = room(show)
	-- The room inside the margins.
	local cols, rows = width - 2 * margin, height - 2 * margin
	-- Measured without what this lays out.
	view:decorate("slides.scale", {})
	view:decorate("slides.center", {})
	view:decorate("slides.pictures", {})
	local shown = pictures(show, slide, cols, rows)
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

-- Shows slide `n` of `list` in `show`; with `go`, the cursor goes to it.
local function draw(show: Show, n: number, list: { Slide }, go: boolean?)
	local slide = list[n]
	if slide == nil or not show.view:valid() then
		return
	end
	local buffer = show.buffer
	local block = first_block(buffer, slide)
	if go then
		local start = buffer:line_start(slide.first)
		show.at:forget()
		show.at = buffer:track(start)
		show.view:set_cursor(block or start)
	end
	-- The cursor shows where it does something: on a block, to run.
	show.view:hide_cursor(block == nil)
	show.view:narrow(slide.first, slide.last)
	show.view:configure({ label = `{n}/{#list}` })
	lay_out(show, slide)
end

-- Forgets `show` and its images, giving its client back the status line
-- it had.
local function forget(show: Show)
	shows[show.view:id()] = nil
	show.at:forget()
	for _, id in show.images do
		if type(id) == "number" then
			greed.image.forget(id)
		end
	end
	-- The client may have gone meanwhile.
	pcall(greed.client.set_status_line, show.status_line, show.client)
end

-- Ends `show`, closing its view.
local function stop(show: Show)
	forget(show)
	if show.view:valid() then
		show.view:close()
	end
end

-- The slide show in the focused view, if it is one.
local function focused(ctx: greed.Context): Show?
	return shows[ctx.view:id()]
end

-- A command moving the slide show in the focused view to the slide `to`
-- picks, from the one it's on (`n`) of `count`.
local function moving(name: string, doc: string, to: (n: number, count: number) -> number)
	greed.command({
		name = name,
		doc = doc,
		run = function(ctx)
			local show = focused(ctx)
			if show then
				local n, list = current(show)
				draw(show, math.clamp(to(n, #list), 1, math.max(#list, 1)), list, true)
			end
		end,
	})
end

moving("slide-next", "Go to the next slide", function(n)
	return n + 1
end)
moving("slide-prev", "Go to the slide before", function(n)
	return n - 1
end)
moving("slide-first", "Go to the first slide", function()
	return 1
end)
moving("slide-last", "Go to the last slide", function(_, count)
	return count
end)

greed.command({
	name = "slides-stop",
	doc = "Stop showing slides and go back to the file",
	run = function(ctx)
		local show = focused(ctx)
		if show then
			stop(show)
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

greed.command({
	name = "slides",
	doc = "Show this Markdown file as slides, from the one the cursor is on",
	run = function(ctx)
		local buffer = ctx.buffer
		if buffer:language() ~= "markdown" then
			greed.echo("slides come from a Markdown file")
			return
		end
		local list = M.slides(buffer)
		if #list == 0 then
			greed.echo("there's nothing on any slide here")
			return
		end
		local view = greed.float(buffer, {
			width = "100%",
			height = "100%",
			title = core.project.basename(buffer:path() or "") or "slides",
			footer = "← → slides · r runs · q back",
		})
		local client = greed.client.current()
		local show: Show = {
			view = view,
			buffer = buffer,
			at = buffer:track(ctx.view:cursor()),
			client = client.id,
			status_line = client.status_line,
			images = {},
		}
		shows[view:id()] = show
		view:set_keys(KEYS)
		-- Problems a language server found, like a prose checker's, aren't
		-- part of the talk, nor is the status line.
		view:hide_marks({ "diagnostics", "lsp" })
		greed.client.set_status_line(false)
		local n = current(show)
		draw(show, n, list, true)
	end,
})

-- What a slide shows changes as its file does, like a block's result
-- coming in: it's narrowed to the slide again.
greed.on("buffer.changed", function(event: greed.BufferChanged)
	for _, show in shows do
		if show.buffer == event.buffer then
			local n, list = current(show)
			draw(show, n, list)
		end
	end
end)

-- Centered slides are laid out for the room they have.
greed.on("view.resized", function(event: greed.ViewResized)
	local show = shows[event.view:id()]
	if show then
		local n, list = current(show)
		draw(show, n, list)
	end
end)

greed.on("view.closed", function(event: greed.ViewClosed)
	local show = shows[event.view]
	if show then
		forget(show)
	end
end)

greed.keymap.bind({ layer = "leader" }, { ["m P"] = "slides" })

return M
