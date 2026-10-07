-- Markdown as a document: headings without their hashes (the top level
-- twice the size), **bold**, *italic*, ~~struck~~ and `code` without their
-- markers, links as their text, fenced code on a background of its own,
-- quotes with a bar, `---` as a line, list dashes as bullets and tables in
-- columns with borders (tables.luau). The file stays plain Markdown:
-- typing on a line shows it as written (see `core.reveal`). Turn it off
-- with `:set markdown-look false`, or for one file with
-- `markdown-look-toggle`. `tab` folds the section, list item or code block
-- around the cursor (folds.luau).
--
-- The reading view (`markdown-read`) shows the file read-only with no
-- markup at all, images in place and links to follow (links.luau), in the
-- "read" mode; esc goes back to editing at the same place.
--
-- Other plugins can draw some parts their own way: notes draws headings and
-- bullets as symbols, and claims them with `require("@markdown").claim`.

local greed = require("@greed")
local core = require("@core")
require("@self/folds")
local choices = require("@self/choices")
local tables = require("@self/tables")
local links = require("@self/links")

local M = {}

--- Choices, `- ( )` and `- (x)`: reading them and hearing picks.
M.choices = choices

greed.option.define({
	name = "markdown-look",
	doc = "Show Markdown with its markup hidden and its headings, code and quotes drawn as such",
	default = true,
})

--- What another plugin draws its own way in a buffer: "headings",
--- "bullets".
export type Parts = { [string]: boolean }

local claims: { (buffer: greed.Buffer) -> Parts? } = {}

-- What others claimed in `buffer`.
local function claimed(buffer: greed.Buffer): Parts
	local parts: Parts = {}
	for _, claim in claims do
		local theirs = claim(buffer)
		if theirs then
			for part, yes in theirs do
				parts[part] = parts[part] or yes
			end
		end
	end
	return parts
end

-- Each file's own say on the look, over the markdown-look option.
local looks: { [number]: boolean } = {}

-- A buffer in the reading view: how it was before, and the images it
-- shows by path (false for those that didn't load).
type Reading = {
	buffer: greed.Buffer,
	readonly: boolean,
	numbers: boolean,
	images: { [string]: number | false },
}

local reading: { [number]: Reading } = {}

-- A line's text from `at` and the marks it gets, with what's taken by code
-- spans and links so other markup isn't looked for inside them. Reading,
-- links are buttons that follow them.
type Line = {
	text: string,
	at: number,
	out: { greed.Mark },
	shows: "line" | "cursor" | "never",
	taken: { { number } },
	reading: boolean,
}

-- Hides `text`'s bytes `from` to `to` (1-based, inclusive), showing
-- `replacement` in their place if given.
local function hide(line: Line, from: number, to: number, replacement: string?, style: string?)
	table.insert(line.out, {
		from = line.at + from - 1,
		to = line.at + to,
		style = style or "markdown.marker",
		text = replacement,
		conceal = true,
		reveal = line.shows,
	})
end

local function paint(line: Line, from: number, to: number, style: string, scale: number?)
	if to >= from then
		table.insert(
			line.out,
			{ from = line.at + from - 1, to = line.at + to, style = style, scale = scale }
		)
	end
end

local function free(line: Line, from: number, to: number): boolean
	for _, span in line.taken do
		if from <= span[2] and to >= span[1] then
			return false
		end
	end
	return true
end

local visible: (text: string, reading: boolean) -> string

-- Inline markup in `line`: code spans first, then images and links, then
-- emphasis.
local function inline(line: Line)
	local text = line.text
	for from, to in string.gmatch(text, "()`[^`]+`()") do
		local first, last = from :: number, (to :: number) - 1
		hide(line, first, first)
		paint(line, first + 1, last - 1, "markdown.code")
		hide(line, last, last)
		table.insert(line.taken, { first, last })
	end
	-- An image amid text shows its description.
	for from, alt, to in string.gmatch(text, "()!%[([^%]]*)%]%([^%)]*%)()") do
		local first, last = from :: number, (to :: number) - 1
		if free(line, first, last) then
			local alt_end = first + 1 + #(alt :: string)
			hide(line, first, first + 1)
			paint(line, first + 2, alt_end, "markdown.image")
			hide(line, alt_end + 1, last)
			table.insert(line.taken, { first, last })
		end
	end
	for from, label, to in string.gmatch(text, "()%[([^%]]+)%]%([^%)]*%)()") do
		local first, last = from :: number, (to :: number) - 1
		if free(line, first, last) then
			local label_end = first + #(label :: string)
			if line.reading then
				table.insert(line.out, {
					from = line.at + first - 1,
					to = line.at + last,
					style = "markdown.link",
					text = visible(label :: string, true),
					conceal = true,
					reveal = line.shows,
					action = "markdown-follow",
				})
			else
				hide(line, first, first)
				paint(line, first + 1, label_end, "markdown.link")
				hide(line, label_end + 1, last)
			end
			table.insert(line.taken, { first, last })
		end
	end
	-- Longest markers first, so ** isn't read as two *.
	local kinds: { { marker: string, size: number, style: string } } = {
		{ marker = "%*%*", size = 2, style = "markdown.bold" },
		{ marker = "__", size = 2, style = "markdown.bold" },
		{ marker = "~~", size = 2, style = "markdown.strike" },
		{ marker = "%*", size = 1, style = "markdown.italic" },
		{ marker = "_", size = 1, style = "markdown.italic" },
	}
	for _, kind in kinds do
		local marker, size, style = kind.marker, kind.size, kind.style
		local pattern = `(){marker}([^%s].-){marker}()`
		local start = 1
		while true do
			local from, inner, to = string.match(string.sub(text, start), pattern)
			if from == nil then
				break
			end
			local first = start + (tonumber(from) :: number) - 1
			local last = start + (tonumber(to) :: number) - 2
			local body = inner :: string
			-- `_` inside words (snake_case) isn't emphasis.
			local word = marker == "_"
				and string.match(string.sub(text, first - 1, first - 1), "%w") ~= nil
			if free(line, first, last) and not word and not string.match(body, "%s$") then
				hide(line, first, first + size - 1)
				paint(line, first + size, last - size, style)
				hide(line, last - size + 1, last)
				table.insert(line.taken, { first, last })
				start = last + 1
			else
				-- Not this one: look again from just after where it began.
				start = first + 1
			end
		end
	end
end

-- `text` as it shows with its inline markup hidden.
visible = function(text: string, reading: boolean): string
	local line: Line =
		{ text = text, at = 0, out = {}, shows = "never", taken = {}, reading = reading }
	inline(line)
	local hidden: { greed.Mark } = {}
	for _, mark in line.out do
		if mark.conceal then
			table.insert(hidden, mark)
		end
	end
	table.sort(hidden, function(a: greed.Mark, b: greed.Mark)
		return a.from < b.from
	end)
	local parts: { string } = {}
	local at = 0
	for _, mark in hidden do
		if mark.from >= at then
			table.insert(parts, string.sub(text, at + 1, mark.from))
			table.insert(parts, mark.text or "")
			at = mark.to
		end
	end
	table.insert(parts, string.sub(text, at + 1))
	return table.concat(parts)
end

-- How many columns `text` takes: one per character.
local function columns(text: string): number
	return utf8.len(text) or #text
end

-- The table whose header is line `n` of `buffer`, if one is: its marks go
-- in `out`. Returns its last line.
local function table_at(
	buffer: greed.Buffer,
	n: number,
	out: { greed.Mark },
	shows: "line" | "cursor" | "never",
	read: boolean
): number?
	local function text_of(line: number): string
		return buffer:slice(buffer:line_start(line), buffer:line_end(line))
	end
	if n + 1 >= buffer:line_count() then
		return nil
	end
	local header = tables.cells(text_of(n))
	local aligns = tables.aligns(text_of(n + 1))
	if header == nil or aligns == nil or #header ~= #aligns then
		return nil
	end
	local lines, texts = { n }, { text_of(n) }
	local last = n + 1
	while last + 1 < buffer:line_count() do
		local text = text_of(last + 1)
		if string.match(text, "^%s*$") or tables.cells(text) == nil then
			break
		end
		last += 1
		table.insert(lines, last)
		table.insert(texts, text)
	end
	local widths, rows = tables.layout(texts, aligns, function(text)
		return columns(visible(text, read))
	end)
	local function line_of(number: number, text: string): Line
		local at = buffer:line_start(number)
		return { text = text, at = at, out = out, shows = shows, taken = {}, reading = read }
	end
	for r, row in rows do
		local line = line_of(lines[r], texts[r])
		for _, gap in row.gaps do
			if gap.to >= gap.from then
				hide(line, gap.from, gap.to, gap.text, "markdown.table")
			else
				table.insert(out, {
					from = line.at + gap.from - 1,
					to = line.at + gap.from - 1,
					style = "markdown.table",
					text = gap.text,
				})
			end
		end
		for _, cell in row.cells do
			local inside = line_of(lines[r], string.sub(texts[r], cell.from, cell.to))
			inside.at += cell.from - 1
			paint(
				inside,
				1,
				#inside.text,
				if r == 1 then "markdown.table.header" else "markdown.table.cell"
			)
			inline(inside)
		end
	end
	local delimiter = line_of(n + 1, text_of(n + 1))
	hide(
		delimiter,
		1,
		#delimiter.text,
		tables.border(widths, "├", "┼", "┤"),
		"markdown.table"
	)
	if n > 0 then
		table.insert(out, {
			from = buffer:line_start(n - 1),
			to = buffer:line_end(n - 1),
			style = "markdown.table",
			lines = { tables.border(widths, "┌", "┬", "┐") },
		})
	end
	table.insert(out, {
		from = buffer:line_start(last),
		to = buffer:line_end(last),
		style = "markdown.table",
		lines = { tables.border(widths, "└", "┴", "┘") },
	})
	return last
end

-- The image `src` names, loaded for `read`, at its own size or as wide as
-- a view of the buffer if that's narrower; nil if it doesn't load.
local function picture(
	read: Reading,
	src: string
): { id: number, cols: number, rows: number, col: number?, row: number? }?
	local path = links.path(read.buffer, src)
	if path == nil then
		return nil
	end
	local cached = read.images[path]
	if cached == nil then
		local loaded = greed.image.load(path)
		if loaded == nil then
			read.images[path] = false
			return nil
		end
		read.images[path] = loaded
		cached = loaded
	end
	if type(cached) ~= "number" then
		return nil
	end
	local id: number = cached
	local natural_cols, natural_rows = greed.image.cells(id)
	if not (natural_cols and natural_rows) then
		return nil
	end
	local view = read.buffer:views()[1]
	local cols = (if view then select(2, view:size()) else nil) or 80
	local scale = math.min(1, cols / math.max(natural_cols, 1))
	return {
		id = id,
		cols = math.max(1, math.round(natural_cols * scale)),
		rows = math.max(1, math.round(natural_rows * scale)),
	}
end

-- The marks for `buffer`, in the reading view if `read` is given.
local function marks(buffer: greed.Buffer, read: Reading?): { greed.Mark }
	local out: { greed.Mark } = {}
	local parts = claimed(buffer)
	local shows: "line" | "cursor" | "never" = if read then "never" else core.reveal()
	local fence: string? = nil
	-- Lines already drawn as part of a table.
	local done = -1
	-- What code blocks look like: a block's output (```` ```result ````) a
	-- little apart from code.
	local block_style = "markdown.code.block"
	for n = 0, buffer:line_count() - 1 do
		if n <= done then
			continue
		end
		local at = buffer:line_start(n)
		local text = buffer:slice(at, buffer:line_end(n))
		local line: Line =
			{ text = text, at = at, out = out, shows = shows, taken = {}, reading = read ~= nil }
		local ticks = string.match(text, "^%s*(```+)") or string.match(text, "^%s*(~~~+)")
		if fence == nil and ticks then
			block_style = if string.match(text, "^%s*[`~]+%s*result")
				then "markdown.code.block.result"
				else "markdown.code.block"
		end
		if fence or ticks then
			table.insert(out, { from = at, to = at + #text, style = block_style, line = true })
			local closes = fence
				and ticks
				and string.sub(ticks, 1, 1) == string.sub(fence, 1, 1)
				and #ticks >= #fence
			if fence == nil or closes then
				if read then
					hide(line, 1, #text)
				else
					paint(line, 1, #text, "markdown.fence")
				end
				fence = if fence == nil then ticks else nil
			end
			continue
		end
		if string.find(text, "|", 1, true) then
			local last = table_at(buffer, n, out, shows, read ~= nil)
			if last then
				done = last
				continue
			end
		end
		-- An image on a line of its own shows in place, reading.
		local alt, src = string.match(text, "^%s*!%[([^%]]*)%]%(%s*<?([^%s>%)]+)[^%)]*%)%s*$")
		local shown = if read and src then picture(read, src) else nil
		if shown then
			local room: { any } = table.create(shown.rows - 1, "")
			table.insert(out, {
				from = at,
				to = at + #text,
				style = "markdown.image",
				-- Where images can't show, the description does.
				text = alt,
				conceal = true,
				reveal = shows,
				image = shown,
				lines = room,
			})
			continue
		end
		-- Outside code, text is prose: in the window, in the prose font.
		paint(line, 1, #text, "markdown.text")
		local hashes, space = string.match(text, "^(#+)()%s")
		local quote = string.match(text, "^%s*>%s?()")
		local bullet = string.match(text, "^%s*()[-*+]%s")
		local choice, picked = string.match(text, "^%s*()[-*+] %(([ xX])%) ")
		if choice then
			-- A choice, `- ( )` or `- (x)`: a button that picks it.
			local chosen = picked ~= " "
			table.insert(out, {
				from = at + (choice :: number) - 1,
				to = at + (choice :: number) + 5,
				style = if chosen then "markdown.chosen" else "markdown.choice",
				text = if chosen then "◉ " else "◯ ",
				conceal = true,
				reveal = shows,
				action = "choice-pick",
			})
			inline(line)
			continue
		end
		if
			string.match(text, "^%s*([-*_])%s*%1%s*%1[%s%-*_]*$") and not string.match(text, "%w")
		then
			hide(line, 1, #text, string.rep("─", 40), "markdown.rule")
			continue
		elseif hashes and #hashes <= 6 and not parts.headings then
			local level = #hashes
			hide(line, 1, space :: number)
			paint(
				line,
				(space :: number) + 1,
				#text,
				`markdown.heading.{level}`,
				if level == 1 then 2 else nil
			)
		elseif quote then
			hide(line, 1, (quote :: number) - 1, "▎ ", "markdown.quote.bar")
			paint(line, quote :: number, #text, "markdown.quote")
		elseif bullet and not parts.bullets then
			hide(line, bullet :: number, (bullet :: number) + 1, "• ", "markdown.bullet")
		end
		inline(line)
	end
	return out
end

local function is_markdown(buffer: greed.Buffer): boolean
	return buffer:valid() and buffer:language() == "markdown"
end

-- Whether `buffer` gets the look: its own say, or the option's.
local function look(buffer: greed.Buffer): boolean
	local own = looks[buffer:id()]
	if own ~= nil then
		return own
	end
	return greed.option.get("markdown-look") == true
end

local function draw(buffer: greed.Buffer)
	local read = reading[buffer:id()]
	if not is_markdown(buffer) or not (read or look(buffer)) then
		if buffer:valid() then
			buffer:decorate("markdown", {})
		end
		return
	end
	buffer:decorate("markdown", marks(buffer, read))
end

--- Draws every Markdown buffer again.
function M.refresh()
	for _, buffer in greed.buffers() do
		draw(buffer)
	end
end

--- Lets `claim` say, for each buffer, which parts it draws its own way;
--- Markdown leaves those alone there. It's undone when the plugin that
--- called this goes, or when what it returns is called.
function M.claim(claim: (buffer: greed.Buffer) -> Parts?): () -> ()
	local take = core.registry.put(claims, claim)
	M.refresh()
	local function undo()
		take()
		M.refresh()
	end
	greed.plugin.tie(undo)
	return undo
end

--- Whether `buffer` is in the reading view.
function M.reading(buffer: greed.Buffer): boolean
	return reading[buffer:id()] ~= nil
end

-- The status line says when a Markdown file shows as written.
core.features.add("plain", function(buffer)
	return is_markdown(buffer) and not look(buffer) and reading[buffer:id()] == nil
end, "markdown")

greed.command({
	name = "markdown-look-toggle",
	doc = "Show this Markdown file as a document or as written, whatever markdown-look says",
	run = function(ctx)
		local buffer = ctx.buffer
		if not is_markdown(buffer) then
			greed.echo("not a Markdown file")
			return
		end
		local on = not look(buffer)
		-- Matching the option again, the file follows it again.
		if on == (greed.option.get("markdown-look") == true) then
			looks[buffer:id()] = nil
		else
			looks[buffer:id()] = on
		end
		draw(buffer)
		greed.echo(
			if on then "Markdown look on for this file" else "Markdown look off for this file"
		)
	end,
})

-- The reading view ----------------------------------------------------------

-- The mode to go back to from reading.
local back = "normal"

local function start_reading(buffer: greed.Buffer)
	if reading[buffer:id()] then
		return
	end
	reading[buffer:id()] = {
		buffer = buffer,
		readonly = buffer:readonly(),
		numbers = buffer:line_numbers(),
		images = {},
	}
	buffer:set_readonly(true)
	buffer:set_line_numbers(false)
	draw(buffer)
end

-- Stops reading buffer `id`, letting its images go.
local function forget(id: number): Reading?
	local read = reading[id]
	reading[id] = nil
	if read then
		for _, image in read.images do
			if type(image) == "number" then
				greed.image.forget(image)
			end
		end
	end
	return read
end

-- Every buffer back to editing, as it was.
local function stop_reading()
	local ids: { number } = {}
	for id in reading do
		table.insert(ids, id)
	end
	for _, id in ids do
		local read = forget(id) :: Reading
		read.buffer:set_readonly(read.readonly)
		read.buffer:set_line_numbers(read.numbers)
		draw(read.buffer)
	end
end

greed.command({
	name = "markdown-read",
	doc = "Read this Markdown file as a document, with images and links to follow; again or esc to edit",
	run = function(ctx)
		local mode = greed.mode.get()
		if mode == "read" then
			stop_reading()
			greed.mode.set(back)
			return
		end
		if not is_markdown(ctx.buffer) then
			greed.echo("not a Markdown file")
			return
		end
		back = if core.style.is_home(mode) then mode else core.style.home()
		start_reading(ctx.buffer)
		greed.mode.set("read")
	end,
})

greed.command({
	name = "markdown-follow",
	doc = "Follow the Markdown link under the cursor: to a heading, another file or a web page",
	run = function(ctx)
		local selection = ctx.view:selection()
		local target, at = links.at(ctx.buffer, selection.ranges[selection.primary].head)
		if target == nil or at == nil then
			greed.echo("no link here")
			return
		end
		local opened = links.follow(ctx.view, target, at)
		-- A Markdown file opened from the reading view is read too.
		if opened and greed.mode.get() == "read" then
			if is_markdown(opened) then
				start_reading(opened)
			else
				stop_reading()
				greed.mode.set(back)
			end
		end
	end,
})

-- Reading is moving around, so the keys are a pager's, the same in every
-- style.
greed.keymap.bind("read", {
	esc = "markdown-read",
	q = "markdown-read",
	["space m v"] = "markdown-read",
	["alt-v"] = "markdown-read",
	enter = "press-button",
	j = "move-down",
	k = "move-up",
	h = "move-left",
	l = "move-right",
	down = "move-down",
	up = "move-up",
	left = "move-left",
	right = "move-right",
	pagedown = "page-down",
	pageup = "page-up",
	["ctrl-f"] = "page-down",
	["ctrl-b"] = "page-up",
	["ctrl-d"] = "half-page-down",
	["ctrl-u"] = "half-page-up",
	["/"] = "search",
	n = "search-next",
	N = "search-prev",
	[":"] = "command-line",
})

greed.keymap.bind(
	"normal",
	{ ["space m l"] = "markdown-look-toggle", ["space m v"] = "markdown-read" }
)
greed.keymap.bind("edit", { ["alt-V"] = "markdown-look-toggle", ["alt-v"] = "markdown-read" })

local function on_buffer(event: greed.BufferChanged)
	draw(event.buffer)
end

greed.on("buffer.opened", on_buffer)
greed.on("buffer.changed", on_buffer)
greed.on("buffer.closed", function(event: greed.BufferClosed)
	looks[event.id] = nil
	forget(event.id)
end)
-- Typing shows markup as written, so it's drawn again as modes change.
greed.on("mode.changed", function(event: greed.ModeChanged)
	-- Back in a style's own mode some other way (another style, say), the
	-- reading is over.
	if event.to ~= "read" and core.style.is_home(event.to) then
		stop_reading()
	end
	M.refresh()
end)
greed.on("option.changed", function(event)
	if event.name == "markdown-look" then
		M.refresh()
	end
end)
-- Images fit the view again when it's resized.
greed.on("view.resized", function(event: greed.ViewResized)
	if reading[event.view:buffer():id()] then
		draw(event.view:buffer())
	end
end)

return M
