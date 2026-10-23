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
require("@self/outline")
local choices = require("@self/choices")
local questions = require("@self/questions")
local tables = require("@self/tables")
local links = require("@self/links")
local structure = require("@self/structure")
local conceal = require("@self/conceal")
local values = require("@self/values")

local M = {}

--- Choices, `- ( )` and `- (x)`: reading them and hearing picks.
M.choices = choices

--- Named questions, their answers, and parts shown only for some answers.
M.questions = questions

--- Live values: `{{ formula }}`, `<!-- let name = formula -->` and fields.
M.values = values

--- Tables' text: their cells, layout, and grids to edit and write back.
M.tables = tables

--- Editing tables as they're drawn: cell to cell, rows and columns.
M.table_edit = require("@self/table_edit")

export type Structure = structure.Structure
export type Heading = structure.Heading
export type Code = structure.Code
export type Item = structure.Item
export type Table = structure.Table
export type Link = structure.Link
export type Concealer = conceal.Concealer
export type Group = choices.Group
export type Option = choices.Option
--- A table's data, its formulas worked out, from `values.data`.
export type Data = values.Data

--- The structure of a buffer (kept until it changes) or of a file's
--- text: its headings, code blocks, list items, tables and links.
M.structure = structure.of

--- Draws over the Markdown buffers a concealer wants, as they change, a
--- few lines at a time; see conceal.luau.
M.conceal = conceal.add

--- Draws all of a buffer again, every concealer's layer, as when something
--- its marks show changed outside its text (a data block's table read).
M.redraw = conceal.redraw

-- When hidden markup shows: as the mode says (see `core.reveal`), only while
-- typing (a table's borders), or never in the reading view.
type Reveal = "auto" | "never" | "typing"

greed.option.define({
	name = "markdown-look",
	doc = "Show Markdown with its markup hidden and its headings, code and quotes drawn as such",
	default = true,
})

--- What another plugin draws its own way in a buffer: "headings",
--- "bullets".
export type Parts = { [string]: boolean }

local claims: { (buffer: greed.Buffer) -> Parts? } = {}

-- Lines of each buffer, by its id, that aren't Markdown and show as they
-- are, from `M.plain`.
local plain_lines: { [number]: { [number]: boolean } } = {}

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
	shows: Reveal,
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

-- Whether emphasis from `from` to `to`, its markers `size` long, can be:
-- what's marked already, like `**`code`**`'s code, must be inside it whole.
local function around(line: Line, from: number, to: number, size: number): boolean
	for _, span in line.taken do
		local overlaps = from <= span[2] and to >= span[1]
		if overlaps and not (span[1] >= from + size and span[2] <= to - size) then
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
	for from, label, target, to in string.gmatch(text, "()%[([^%]]+)%]%(([^%)]*)%)()") do
		local first, last = from :: number, (to :: number) - 1
		if string.match(target :: string, "^field:") or string.match(target :: string, "^run:") then
			-- A field, which values.luau draws, or a command button, which
			-- the blocks plugin does.
			table.insert(line.taken, { first, last })
		elseif free(line, first, last) then
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
			if around(line, first, last, size) and not word and not string.match(body, "%s$") then
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
-- What `visible` gave for each text, reading and not: tables ask for every
-- cell's each time they're drawn. Emptied when it grows large.
local seen_visible: { [boolean]: { [string]: string } } = { [true] = {}, [false] = {} }
local seen_count = 0

local function shown_text(text: string, reading: boolean): string
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

visible = function(text: string, reading: boolean): string
	local known = seen_visible[reading][text]
	if known then
		return known
	end
	if seen_count >= 10000 then
		seen_visible = { [true] = {}, [false] = {} }
		seen_count = 0
	end
	local shown = shown_text(text, reading)
	seen_visible[reading][text] = shown
	seen_count += 1
	return shown
end

-- The marks for table `found` of `s` go in `out`. False if its rows don't
-- line up with its delimiter row after all. Cells a formula fills
-- (`worked`, values.luau) show what it worked out.
local function draw_table(
	s: Structure,
	found: structure.Table,
	out: { greed.Mark },
	shows: Reveal,
	read: boolean,
	worked: { [number]: { [number]: values.Worked } }?
): boolean
	local function text_of(line: number): string
		return s.lines[line + 1]
	end
	local n, last = found.first, found.last
	if last == n then
		return false
	end
	local header = tables.cells(text_of(n))
	local aligns = tables.aligns(text_of(n + 1))
	if header == nil or aligns == nil or #header ~= #aligns then
		return false
	end
	local lines, texts = { n }, { text_of(n) }
	for row = n + 2, last do
		table.insert(lines, row)
		table.insert(texts, text_of(row))
	end
	local function filled(r: number, c: number): values.Worked?
		local row = worked and worked[r]
		return if row then row[c] else nil
	end
	local widths, rows = tables.layout(texts, aligns, function(text, r, c)
		local cell = filled(r, c)
		return core.text.width(if cell then cell.text else visible(text, read))
	end)
	local function line_start(line: number): number
		return s.starts[line + 1]
	end
	local function line_end(line: number): number
		return s.starts[line + 1] + #s.lines[line + 1]
	end
	-- The borders show as written only while typing; the cells as the mode says.
	local borders: Reveal = if shows == "never" then "never" else "typing"
	local function line_of(number: number, text: string, how: Reveal?): Line
		local at = line_start(number)
		return { text = text, at = at, out = out, shows = how or shows, taken = {}, reading = read }
	end
	for r, row in rows do
		local line = line_of(lines[r], texts[r], borders)
		-- What a formula worked out for an empty cell goes in where the cell
		-- is, ahead of what's drawn for the gap after it, at the same place.
		for c, cell in row.cells do
			local fill = filled(r, c)
			if fill and cell.to < cell.from then
				table.insert(out, {
					from = line.at + cell.from - 1,
					to = line.at + cell.from - 1,
					style = if fill.failed then "markdown.value.error" else "markdown.value",
					text = fill.text,
				})
			end
		end
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
		for c, cell in row.cells do
			local inside = line_of(lines[r], string.sub(texts[r], cell.from, cell.to))
			inside.at += cell.from - 1
			local fill = filled(r, c)
			if fill then
				-- What the formula worked out, over what the file says there
				-- (an empty cell's went in above).
				if #inside.text > 0 then
					table.insert(out, {
						from = inside.at,
						to = inside.at + #inside.text,
						style = if fill.failed then "markdown.value.error" else "markdown.value",
						text = fill.text,
						conceal = true,
						reveal = shows,
					})
				end
				continue
			end
			paint(
				inside,
				1,
				#inside.text,
				if r == 1 then "markdown.table.header" else "markdown.table.cell"
			)
			inline(inside)
		end
	end
	local delimiter = line_of(n + 1, text_of(n + 1), borders)
	hide(
		delimiter,
		1,
		#delimiter.text,
		tables.border(widths, "├", "┼", "┤"),
		"markdown.table"
	)
	if n > 0 then
		table.insert(out, {
			from = line_start(n - 1),
			to = line_end(n - 1),
			style = "markdown.table",
			lines = { tables.border(widths, "┌", "┬", "┐") },
		})
	end
	-- Empty, so the border's style doesn't paint the last row.
	table.insert(out, {
		from = line_end(last),
		to = line_end(last),
		style = "markdown.table",
		lines = { tables.border(widths, "└", "┴", "┘") },
	})
	return true
end

--- An image for a mark's `image`: what it shows and the cells it covers.
export type Picture = { id: number, cols: number, rows: number, col: number?, row: number? }

--- The image file at `path`, for a mark in `buffer`: loaded once into
--- `images` (by path; false when it doesn't load, and the caller forgets
--- the rest when done), at its own size, `width` pixels wide when given,
--- or as wide as a view of the buffer if that's narrower. Nil if it
--- doesn't load.
function M.picture(
	buffer: greed.Buffer,
	path: string,
	images: { [string]: number | false },
	width: number?
): Picture?
	local cached = images[path]
	if cached == nil then
		local loaded = greed.image.load(path)
		if loaded == nil then
			images[path] = false
			return nil
		end
		images[path] = loaded
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
	local view = buffer:views()[1]
	local cols = (if view then select(2, view:size()) else nil) or 80
	if width then
		cols = math.min(cols, width / greed.image.cell_size())
	end
	local scale = math.min(1, cols / math.max(natural_cols, 1))
	return {
		id = id,
		cols = math.max(1, math.round(natural_cols * scale)),
		rows = math.max(1, math.round(natural_rows * scale)),
	}
end

-- The image `src` names, loaded for `read` (see `M.picture`).
local function picture(read: Reading, src: string): Picture?
	local path = links.path(read.buffer, src)
	return if path then M.picture(read.buffer, path, read.images) else nil
end

-- Obsidian's callouts, `> [!warning] Title` on a quote's first line: the
-- kinds it knows, by the look each has, and each look's sign. A kind it
-- doesn't know looks like a note.
local CALLOUTS: { [string]: string } = {
	note = "note",
	abstract = "note",
	summary = "note",
	tldr = "note",
	info = "note",
	todo = "note",
	tip = "tip",
	hint = "tip",
	important = "tip",
	success = "success",
	check = "success",
	done = "success",
	question = "question",
	help = "question",
	faq = "question",
	warning = "warning",
	caution = "warning",
	attention = "warning",
	failure = "danger",
	fail = "danger",
	missing = "danger",
	danger = "danger",
	error = "danger",
	bug = "danger",
	example = "example",
	quote = "quote",
	cite = "quote",
}
local CALLOUT_SIGNS: { [string]: string } = {
	note = "ℹ",
	tip = "✱",
	success = "✓",
	question = "?",
	warning = "!",
	danger = "✗",
	example = "≡",
	quote = "❝",
}

-- How the callout line `n` (0-based) is in looks, from the `[!kind]` on
-- its quote's first line; nil in a plain quote or outside one.
local function callout_of(s: Structure, n: number): string?
	for k = n, math.max(n - 200, 0), -1 do
		local text = s.lines[k + 1]
		local after = string.match(text, "^%s*>%s?()")
		if after == nil then
			return nil
		end
		local kind = string.match(text, "^%[!([%w%-]+)%]", after)
		if kind then
			return CALLOUTS[string.lower(kind)] or "note"
		end
	end
	return nil
end

-- The marks starting on lines `first` to `last` of `buffer`, whose
-- structure is `s`, in the reading view if `read` is given.
local function marks(
	buffer: greed.Buffer,
	s: Structure,
	first: number,
	last: number,
	read: Reading?
): { greed.Mark }
	local out: { greed.Mark } = {}
	local parts = claimed(buffer)
	local shows: Reveal = if read then "never" else "auto"
	local left_plain = plain_lines[buffer:id()]
	local n = first
	while n <= last do
		local at = s.starts[n + 1]
		local text = s.lines[n + 1]
		local line: Line =
			{ text = text, at = at, out = out, shows = shows, taken = {}, reading = read ~= nil }
		n += 1
		if left_plain and left_plain[n - 1] then
			-- Nor Markdown's colours: `~` around a path isn't strikethrough.
			table.insert(out, { from = at, to = at + #text, style = "text", plain = true })
			continue
		end
		local block = s.code_at[n - 1]
		if block then
			-- A block's output (```` ```result ````) looks a little apart
			-- from code.
			local style = if string.find(block.info, "^result")
				then "markdown.code.block.result"
				else "markdown.code.block"
			table.insert(out, { from = at, to = at + #text, style = style, line = true })
			if n - 1 == block.open or (n - 1 == block.close and block.closed) then
				if read then
					hide(line, 1, #text)
				else
					paint(line, 1, #text, "markdown.fence")
				end
			end
			continue
		end
		local found = s.table_at[n - 1]
		if
			found and draw_table(s, found, out, shows, read ~= nil, values.worked(buffer, s, found))
		then
			n = found.last + 1
			continue
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
		local heading = s.heading_at[n - 1]
		local item = s.item_at[n - 1]
		-- Where a quote's `>` is, and where its text starts.
		local bar, quote = string.match(text, "^%s*()>%s?()")
		local choice, picked = string.match(text, "^%s*()[-*+] %(([ xX])%) ")
		if choice and item then
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
		if heading and heading.underlined and not parts.headings then
			if n - 1 == heading.last then
				hide(line, 1, #text, string.rep("─", 40), "markdown.rule")
				continue
			end
			paint(
				line,
				1,
				#text,
				`markdown.heading.{heading.level}`,
				if heading.level == 1 then 2 else nil
			)
		elseif heading and not heading.underlined and not parts.headings then
			-- The #s and the space after them go.
			local start = heading.from - at + 1
			local words = string.find(text, "[^#%s]", start) or #text + 1
			hide(line, start, words - 1)
			paint(
				line,
				words,
				#text,
				`markdown.heading.{heading.level}`,
				if heading.level == 1 then 2 else nil
			)
		elseif structure.rule(text) and not heading then
			hide(line, 1, #text, string.rep("─", 40), "markdown.rule")
			continue
		elseif quote then
			local look = callout_of(s, n - 1)
			local style = if look then `markdown.callout.{look}` else "markdown.quote.bar"
			hide(line, bar :: number, (quote :: number) - 1, "▎ ", style)
			local kind, title = string.match(text, "^%[!([%w%-]+)%][+-]?%s*()", quote :: number)
			if look and kind and title then
				-- Its sign, and its title or else its kind's name.
				local named = if (title :: number) > #text
					then string.upper(string.sub(kind, 1, 1)) .. string.lower(string.sub(kind, 2))
					else ""
				hide(
					line,
					quote :: number,
					(title :: number) - 1,
					`{CALLOUT_SIGNS[look]} {named}`,
					style
				)
				paint(line, title :: number, #text, style)
			else
				paint(line, quote :: number, #text, "markdown.quote")
			end
		elseif item and not parts.bullets and string.find(item.bullet, "^[-*+]$") then
			local bullet = item.from - at + 1
			hide(line, bullet, bullet + 1, "• ", "markdown.bullet")
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

--- Whether `buffer` shows as a document: Markdown, with the look on or in
--- the reading view. For plugins drawing over it with `conceal`.
function M.drawn(buffer: greed.Buffer): boolean
	return is_markdown(buffer) and (reading[buffer:id()] ~= nil or look(buffer))
end

local redraw_document = conceal.add({
	ns = "markdown",
	wants = M.drawn,
	draw = function(
		buffer: greed.Buffer,
		s: Structure,
		first: number,
		last: number
	): { greed.Mark }
		return marks(buffer, s, first, last, reading[buffer:id()])
	end,
})

-- Comments hidden, and the parts whose conditions don't hold folded away
-- (questions.luau), wherever the rest shows as a document.
local redraw_questions = conceal.add({
	ns = "markdown-questions",
	wants = M.drawn,
	draw = questions.marks,
})

-- Whether each buffer has live values, so those without don't pay for
-- them; and what its formulas could name when it was last drawn.
local has_values: { [number]: boolean } = {}
local named_before: { [number]: string } = {}

-- Whether lines `first` to `last` of `s` have values.
local function valued(s: Structure, first: number, last: number): boolean
	for n = first, math.min(last, #s.lines - 1) do
		local line = s.lines[n + 1]
		if
			string.find(line, "{{", 1, true)
			or string.find(line, "field:", 1, true)
			or string.find(line, "<!%-%-%s*let%s")
			or string.find(line, "<!%-%-%s*formula:")
			or string.find(line, "<!%-%-%s*chart:")
		then
			return true
		end
	end
	return false
end

-- Live values (values.luau). After an edit only its lines are drawn again,
-- unless it changed what formulas name (a field, a `let`, a table): then
-- the whole file is, every layer, as values and tables anywhere in it can
-- change.
local redraw_values = conceal.add({
	ns = "markdown-values",
	wants = M.drawn,
	draw = function(
		buffer: greed.Buffer,
		s: Structure,
		first: number,
		last: number
	): { greed.Mark }
		local id = buffer:id()
		local whole = first == 0 and last >= #s.lines - 1
		has_values[id] = (has_values[id] and not whole) or valued(s, first, last)
		if not has_values[id] then
			return {}
		end
		local key = values.found(s).key
		local before = named_before[id]
		named_before[id] = key
		if not whole and before ~= nil and before ~= key then
			greed.spawn(function()
				conceal.redraw(buffer)
			end)
		end
		return values.marks(buffer, s, first, last)
	end,
})

greed.on("buffer.closed", function(event: greed.BufferClosed)
	has_values[event.id], named_before[event.id] = nil, nil
end)

-- A pick can show or hide parts anywhere in the file, and change values.
choices.on_pick(function(buffer)
	redraw_questions(buffer)
	redraw_values(buffer)
end)

-- Draws `buffer` (or every Markdown buffer) again as a document.
local function redraw(buffer: greed.Buffer?)
	redraw_document(buffer)
	redraw_questions(buffer)
	redraw_values(buffer)
end

--- Draws `buffer`, or every Markdown buffer, again: for a page a plugin
--- made and showed in a view that was already there, which is drawn
--- otherwise only once the view changes size.
function M.refresh(buffer: greed.Buffer?)
	redraw(buffer)
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
	greed.plugin.cleanup(undo)
	return undo
end

--- Says which lines of `buffer` (0-based) aren't Markdown, like a tool's
--- output in an agent's transcript: they show exactly as they are, their
--- stars and backticks untouched. Nil takes that back. Call it before
--- changing the text, so the redraw the change brings knows.
function M.plain(buffer: greed.Buffer, lines: { [number]: boolean }?)
	if lines then
		plain_lines[buffer:id()] = lines
	else
		plain_lines[buffer:id()] = nil
	end
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
		redraw(buffer)
		greed.echo(
			if on then "Markdown look on for this file" else "Markdown look off for this file"
		)
	end,
})

-- The reading view ----------------------------------------------------------

-- The mode to go back to from reading.
local back = core.style.home()

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
	redraw(buffer)
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
		redraw(read.buffer)
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
		local target, at = links.at(ctx.buffer, ctx.view:cursor())
		if target == nil or at == nil then
			greed.echo("no link here")
			return
		end
		local opened = links.follow(ctx.view, target)
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
	{ layer = "leader" },
	{ ["m l"] = "markdown-look-toggle", ["m v"] = "markdown-read", ["m f"] = "markdown-field-make" }
)
greed.keymap.bind(
	{ style = "vscode", role = "typing" },
	{ ["alt-V"] = "markdown-look-toggle", ["alt-v"] = "markdown-read" }
)

-- Each buffer's version when typing in it began, by buffer.
local typed_from: { [number]: number } = {}

greed.on("buffer.closed", function(event: greed.BufferClosed)
	typed_from[event.id] = nil
	looks[event.id] = nil
	plain_lines[event.id] = nil
	forget(event.id)
end)
greed.on("mode.changed", function(event: greed.ModeChanged)
	-- Back in a style's own mode some other way (another style, say), the
	-- reading is over.
	if event.to ~= "read" and core.style.is_home(event.to) then
		stop_reading()
	end
	-- Done typing in a table as it's drawn: its pipes line up again and a
	-- row typed short of cells gets the rest. Typing that changed nothing,
	-- like a search, leaves the table as it is.
	local view = greed.view()
	local buffer = view:buffer()
	local typing_from, typing_to = core.style.is_typing(event.from), core.style.is_typing(event.to)
	if typing_to and not typing_from then
		typed_from[buffer:id()] = buffer:version()
	elseif typing_from and not typing_to then
		local from = typed_from[buffer:id()]
		typed_from[buffer:id()] = nil
		if
			from ~= nil
			and from ~= buffer:version()
			and not buffer:readonly()
			and M.drawn(buffer)
		then
			M.table_edit.tidy(view)
		end
	end
end)
greed.on("option.changed", function(event)
	if event.name == "markdown-look" then
		M.refresh()
	end
end)
-- Images fit the view again when it's resized.
greed.on("view.resized", function(event: greed.ViewResized)
	local read = reading[event.view:buffer():id()]
	if read == nil then
		return
	end
	for _, image in read.images do
		if type(image) == "number" then
			redraw(event.view:buffer())
			return
		end
	end
end)

return M
