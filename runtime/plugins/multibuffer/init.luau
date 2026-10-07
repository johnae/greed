-- Multibuffers: one buffer made of excerpts from many files, edited in
-- place. Typing in an excerpt edits its file as you go (the file opens in
-- Greed the first time one of its excerpts changes), and a change made to
-- the file anywhere else shows in the excerpt. :w saves every file changed
-- this way, enter goes to the line under the cursor and q closes the view.
--
-- Search results open in one. A plugin makes its own with
--
--     require("@multibuffer").open({ { path = "/src/main.rs", from = 9, to = 12 } },
--         { summary = "1 place" })
--
-- Each file's name shows above its excerpts and its line numbers beside
-- them; neither is text you can edit. Excerpts that overlap or touch are
-- joined.

local greed = require("@greed")
local core = require("@core")

export type Excerpt = {
	--- The file; a relative path is from the project's root.
	path: string,
	--- Its first line, 0-based.
	from: number,
	--- Its last line, included; `from` if left out.
	to: number?,
	--- What to show above it; the path, relative to the project's root, if
	--- left out.
	label: string?,
	--- More to show above it, after the line number, like the problem a
	--- line has.
	note: string?,
	--- Parts to draw in a style, by 0-based line in the file and byte
	--- columns, like the matches of a search. `whole` styles the whole line,
	--- and `lines` shows lines that aren't in the file under it, like ones
	--- a change removed.
	marks: { Mark }?,
}

export type Mark = {
	line: number,
	from: number,
	to: number,
	style: string,
	whole: boolean?,
	lines: { greed.MarkLine }?,
}

export type Options = {
	--- The first line, above the excerpts, e.g. "12 lines match foo".
	summary: string,
	--- How many lines around each excerpt show with it.
	context: number?,
	--- The text a file is compared against, for excerpts made by `diff`:
	--- `space g r` puts the change under the cursor back to it.
	base: ((path: string) -> string?)?,
	--- Shows the view again after a change was put back.
	refresh: (() -> ())?,
}

-- One excerpt, as shown.
type Part = {
	path: string,
	label: string,
	-- Shown after the label and line number; the notes of joined excerpts.
	note: string?,
	-- Where its text is in the multibuffer.
	shown: greed.Tracked,
	-- Its first line in the file, while the file isn't open.
	start: number,
	-- Its text when it was last the same as the file's.
	text: string,
	-- The file's buffer once open, and where the excerpt is in it.
	source: greed.Buffer?,
	place: greed.Tracked?,
}

type State = { buffer: greed.Buffer, parts: { Part }, options: Options }

local M = {}

local states: { [number]: State } = {}

-- While the plugin edits buffers itself, so their change events don't
-- echo back.
local syncing = false

-- `text` split into lines that keep their line breaks.
local function lines_of(text: string): { string }
	local lines = {}
	for line in string.gmatch(text, "[^\n]*\n?") do
		if line ~= "" then
			table.insert(lines, line)
		end
	end
	return lines
end

-- Byte offsets of lines `from`..`to` of `buffer`.
local function line_span(buffer: greed.Buffer, from: number, to: number): (number, number)
	local stop = if to + 1 < buffer:line_count() then buffer:line_start(to + 1) else buffer:len()
	return buffer:line_start(from), stop
end

-- Tracks `from`..`to` of `buffer`, whole lines, so that text typed at its
-- start goes in and text typed at its end, the start of the next line,
-- stays out.
local function track(buffer: greed.Buffer, from: number, to: number): greed.Tracked
	return buffer:track_range(from, to, { from = "left", to = "left" })
end

-- The text `tracked` covers in `buffer` and where it starts; nil once the
-- text went.
local function marked(buffer: greed.Buffer, tracked: greed.Tracked?): (string?, number)
	if tracked == nil then
		return nil, 0
	end
	local from, to = tracked:range()
	if from == nil or to == nil then
		return nil, 0
	end
	return buffer:slice(from, to), from
end

-- Whether byte `i` of `text` continues a character rather than starting one.
local function continues(text: string, i: number): boolean
	local byte = string.byte(text, i)
	return byte ~= nil and byte >= 0x80 and byte < 0xC0
end

-- Makes `old`, the text at `start` in `buffer`, read `new`, replacing only
-- what lies between the start and end they share, so cursors elsewhere in
-- it stay put.
local function rewrite(buffer: greed.Buffer, start: number, old: string, new: string)
	if old == new then
		return
	end
	local shortest = math.min(#old, #new)
	local same_start = 0
	while
		same_start < shortest
		and string.byte(old, same_start + 1) == string.byte(new, same_start + 1)
	do
		same_start += 1
	end
	while same_start > 0 and continues(old, same_start + 1) do
		same_start -= 1
	end
	local same_end = 0
	while
		same_end < shortest - same_start
		and string.byte(old, #old - same_end) == string.byte(new, #new - same_end)
	do
		same_end += 1
	end
	while same_end > 0 and continues(old, #old - same_end + 1) do
		same_end -= 1
	end
	local from, to = same_start, #old - same_end
	local text = string.sub(new, same_start + 1, #new - same_end)
	syncing = true
	local ok: boolean, err: unknown = pcall(buffer.edit, buffer, function(e: greed.Edits)
		e:replace(start + from, start + to, text)
	end)
	syncing = false
	if not ok then
		error(err, 0)
	end
end

-- Tracks `text` at `start` in `buffer` afresh after the plugin rewrote it,
-- rather than trusting edits at its edges to land inside. Tracking only
-- needs to follow edits made by others. Nil when there's no text.
local function retrack(
	buffer: greed.Buffer,
	old: greed.Tracked?,
	start: number,
	text: string
): greed.Tracked?
	if old then
		old:forget()
	end
	return if text ~= "" then track(buffer, start, start + #text) else nil
end

-- The text of the multibuffer's excerpt as the file should have it: the
-- multibuffer ends each excerpt with a line break, which a file's last line
-- may not have.
local function as_file(part: Part, shown: string): string
	if string.sub(part.text, -1) ~= "\n" and string.sub(shown, -1) == "\n" then
		return string.sub(shown, 1, -2)
	end
	return shown
end

local function as_shown(text: string): string
	return if string.sub(text, -1) == "\n" then text else text .. "\n"
end

-- Starts keeping `part` in step with `buffer`, its file's.
local function attach(part: Part, buffer: greed.Buffer, from: number, to: number)
	local start, stop = line_span(buffer, from, to)
	part.source, part.place = buffer, track(buffer, start, stop)
end

-- Opens `part`'s file the first time its excerpt changes, if the file
-- still reads as it did. Returns false if it doesn't.
local function ensure_source(part: Part): boolean
	if part.source then
		return true
	end
	local buffer = greed.load(part.path)
	local to = part.start + #lines_of(part.text) - 1
	if to >= buffer:line_count() then
		return false
	end
	if buffer:slice(line_span(buffer, part.start, to)) ~= part.text then
		return false
	end
	attach(part, buffer, part.start, to)
	return true
end

-- The line of `part` in its file where the excerpt starts now.
local function first_line(part: Part): number
	local source, place = part.source, part.place
	local start = place and place:range()
	if source and start then
		return source:line_of(start)
	end
	return part.start
end

-- The line above `part`: its file and line, then its note.
local function header(part: Part, line: number): { { text: string, style: string } }
	local pieces = { { text = `{part.label}:{line + 1}`, style = "ui.multibuffer.file" } }
	local note = part.note
	if note then
		table.insert(pieces, { text = `  {note}`, style = "ui.multibuffer.note" })
	end
	return pieces
end

-- Draws each file's name above its excerpts and the files' line numbers
-- beside them, as they are now.
local function redraw(state: State)
	local buffer = state.buffer
	local headers: { greed.Mark }, numbers: { greed.Mark } = {}, {}
	local width = 1
	for _, part in state.parts do
		width = math.max(width, #tostring(first_line(part) + #lines_of(part.text)))
	end
	for _, part in state.parts do
		local text, start = marked(buffer, part.shown)
		if text then
			local above = buffer:line_of(start - 1)
			local line = first_line(part)
			-- A blank line, then the file's name.
			local lines: { any } = { "", header(part, line) }
			table.insert(headers, {
				from = buffer:line_start(above),
				to = buffer:line_end(above),
				style = "multibuffer.excerpt",
				lines = lines,
			})
			for i = 0, #lines_of(text) - 1 do
				local at = buffer:line_start(buffer:line_of(start) + i)
				local number = string.format(`%{width}d `, line + i + 1)
				table.insert(numbers, { from = at, to = at, text = number, style = "ui.gutter" })
			end
		end
	end
	buffer:decorate("multibuffer.headers", headers)
	buffer:decorate("multibuffer.numbers", numbers)
end

-- Excerpts joined where they overlap or touch, each file's in order.
local function joined(excerpts: { Excerpt }, context: number): { Excerpt }
	local sorted = {}
	for _, excerpt in excerpts do
		table.insert(sorted, {
			path = core.project.resolve(excerpt.path),
			from = math.max(0, excerpt.from - context),
			to = (excerpt.to or excerpt.from) + context,
			label = excerpt.label,
			note = excerpt.note,
			marks = table.clone(excerpt.marks or {} :: { any }),
		})
	end
	table.sort(sorted, function(a: Excerpt, b: Excerpt)
		return if a.path == b.path then a.from < b.from else a.path < b.path
	end)
	local out: { Excerpt } = {}
	for _, excerpt in sorted do
		local last = out[#out]
		if last and last.path == excerpt.path and excerpt.from <= (last.to :: number) + 1 then
			last.to = math.max(last.to :: number, excerpt.to :: number)
			if excerpt.note then
				last.note = if last.note then `{last.note}; {excerpt.note}` else excerpt.note
			end
			for _, mark in excerpt.marks :: { any } do
				table.insert(last.marks :: { any }, mark)
			end
		else
			table.insert(out, excerpt)
		end
	end
	return out
end

-- The lines of each file, read once, from its buffer if it's open.
local function file_lines(path: string, cache: { [string]: { string } }): { string }
	if cache[path] == nil then
		cache[path] = lines_of(core.file.text(path) or "")
	end
	return cache[path]
end

--- A multibuffer of `excerpts`, not shown yet: show it with `greed.panel`,
--- `greed.float` or a view's `show`.
function M.open(excerpts: { Excerpt }, options: Options): greed.Buffer
	local cache = {}
	local pieces = { options.summary, "\n" }
	local length = #options.summary + 1
	-- Each excerpt shown, its text and where that is in the multibuffer.
	local shown_at: { { excerpt: Excerpt, text: string, from: number, to: number } } = {}
	local found: { greed.Mark } = {}
	for _, excerpt in joined(excerpts, options.context or 0) do
		local lines = file_lines(excerpt.path, cache)
		local to = math.min(excerpt.to :: number, #lines - 1)
		if excerpt.from <= to then
			local text = table.concat(lines, "", excerpt.from + 1, to + 1)
			local shown = as_shown(text)
			table.insert(
				shown_at,
				{ excerpt = excerpt, text = text, from = length, to = length + #shown }
			)
			-- Where each of the excerpt's lines starts in the multibuffer.
			local starts, at = {}, length
			for line = excerpt.from, to do
				starts[line] = at
				at += #lines[line + 1]
			end
			for _, m in excerpt.marks :: { Mark } do
				local start = starts[m.line]
				if start then
					table.insert(found, {
						from = start + m.from,
						to = start + m.to,
						style = m.style,
						line = m.whole,
						lines = m.lines,
					})
				end
			end
			table.insert(pieces, shown)
			length += #shown
		end
	end
	local buffer = greed.create_buffer("multibuffer", table.concat(pieces))
	buffer:set_line_numbers(false)
	local parts: { Part } = {}
	for _, at in shown_at do
		local excerpt = at.excerpt
		table.insert(parts, {
			path = excerpt.path,
			label = excerpt.label or core.project.relative(excerpt.path),
			note = excerpt.note,
			shown = track(buffer, at.from, at.to),
			start = excerpt.from,
			text = at.text,
		})
	end
	buffer:decorate("multibuffer.found", found)
	local state = { buffer = buffer, parts = parts, options = options }
	states[buffer:id()] = state
	-- Files already open are kept in step from the start.
	for _, part in parts do
		local source = greed.buffer_for(part.path)
		if source then
			attach(part, source, part.start, part.start + #lines_of(part.text) - 1)
		end
	end
	redraw(state)
	return buffer
end

-- Carries edits made in the multibuffer to the files.
local function to_files(state: State)
	local problems = {}
	local kept = {}
	for _, part in state.parts do
		local shown = marked(state.buffer, part.shown)
		local new = as_file(part, shown or "")
		if new == part.text then
			table.insert(kept, part)
		elseif not ensure_source(part) then
			table.insert(problems, part.label)
			table.insert(kept, part)
		else
			local source = part.source :: greed.Buffer
			local old, start = marked(source, part.place)
			if old then
				rewrite(source, start, old, new)
				part.place = retrack(source, part.place, start, new)
			end
			part.text = new
			if shown then
				table.insert(kept, part)
			else
				part.shown:forget()
				if part.place then
					part.place:forget()
				end
			end
		end
	end
	state.parts = kept
	redraw(state)
	if #problems > 0 then
		greed.echo(`changed since it was found, so left alone: {table.concat(problems, ", ")}`)
	end
end

-- Carries edits made to a file elsewhere into the multibuffers showing it.
local function from_file(buffer: greed.Buffer)
	for _, state in states do
		local changed = false
		for _, part in state.parts do
			local source = part.source
			if source and source == buffer then
				local now = marked(source, part.place)
				if now and now ~= part.text then
					local shown, start = marked(state.buffer, part.shown)
					if shown then
						rewrite(state.buffer, start, shown, as_shown(now))
						part.shown =
							retrack(state.buffer, part.shown, start, as_shown(now)) :: greed.Tracked
					end
					part.text = now
					changed = true
				end
			end
		end
		if changed then
			redraw(state)
		end
	end
end

greed.on("buffer.changed", function(event: greed.BufferChanged)
	if syncing then
		return
	end
	local state = states[event.buffer:id()]
	if state then
		to_files(state)
	else
		from_file(event.buffer)
	end
end)

greed.on("buffer.closed", function(event: greed.BufferClosed)
	local state = states[event.id]
	if state then
		states[event.id] = nil
		for _, part in state.parts do
			if part.place then
				part.place:forget()
			end
		end
	end
end)

-- :w saves the files the multibuffer changed.
core.file.on_save("multibuffer", function(buffer: greed.Buffer)
	local state = states[buffer:id()]
	if state == nil then
		return
	end
	local saved, done = 0, {}
	for _, part in state.parts do
		local source = part.source
		if source and not done[source:id()] and source:modified() then
			done[source:id()] = true
			source:save()
			saved += 1
		end
	end
	greed.echo(`saved {saved} files`)
end)

--- Where `pos` in a multibuffer is in its files: the path, and the 0-based
--- line and byte column; nil outside the excerpts.
function M.location(buffer: greed.Buffer, pos: number): (string?, number, number)
	local state = states[buffer:id()]
	if state == nil then
		return nil, 0, 0
	end
	for _, part in state.parts do
		local text, start = marked(buffer, part.shown)
		if text and pos >= start and pos <= start + #text then
			local line = buffer:line_of(pos)
			local offset = line - buffer:line_of(start)
			return part.path, first_line(part) + offset, pos - buffer:line_start(line)
		end
	end
	return nil, 0, 0
end

-- Where each line of `text` starts, by 0-based line + 1.
local function line_starts(text: string): { number }
	local starts = { 0 }
	for at in string.gmatch(text, "\n()") do
		table.insert(starts, (at :: number) - 1)
	end
	return starts
end

-- The 0-based line `pos` is on, from `starts`.
local function line_at(starts: { number }, pos: number): number
	local low, high = 1, #starts
	while low < high do
		local mid = (low + high + 1) // 2
		if starts[mid] <= pos then
			low = mid
		else
			high = mid - 1
		end
	end
	return low - 1
end

type Hunk = {
	-- Where its new text is in the file now, and the old text it replaced,
	-- which started at `at` in the base.
	from: number,
	to: number,
	old: string,
	at: number,
	-- The lines it covers now; `first` is the one removed lines show under
	-- when it only removes.
	first: number,
	last: number,
}

-- The changes from `base` to `text`, where they are in `text`.
local function hunks(base: string, text: string): { Hunk }
	local out: { Hunk } = {}
	local starts = line_starts(text)
	-- Diffs are in the old text; `shift` turns their places into the new one's.
	local shift = 0
	for _, hunk in greed.diff(base, text) do
		local from = hunk.from + shift
		local old = string.sub(base, hunk.from + 1, hunk.to)
		shift += #hunk.text - #old
		local first = line_at(starts, from)
		local last = if hunk.text ~= "" then line_at(starts, from + #hunk.text - 1) else first
		table.insert(out, {
			from = from,
			to = from + #hunk.text,
			old = old,
			at = hunk.from,
			first = first,
			last = last,
		})
	end
	return out
end

--- An excerpt for each change from `base` to `text`, the file at `path`:
--- lines added are marked, and lines removed show where they were. Open
--- them with `base` in the options to let `space g r` put changes back.
function M.diff(path: string, label: string?, base: string, text: string): { Excerpt }
	local out: { Excerpt } = {}
	for _, hunk in hunks(base, text) do
		local removed: { greed.MarkLine } = {}
		for _, line in string.split(hunk.old, "\n") do
			table.insert(removed, line)
		end
		if removed[#removed] == "" then
			table.remove(removed)
		end
		local first, last = hunk.first, hunk.last
		local added = if hunk.to > hunk.from then last - first + 1 else 0
		local marks: { Mark } = {}
		for line = first, first + added - 1 do
			table.insert(
				marks,
				{ line = line, from = 0, to = 0, style = "diff.plus", whole = true }
			)
		end
		if #removed > 0 then
			-- Under the line before where they were; at the top, under the first.
			local under = math.max(first - 1, 0)
			table.insert(
				marks,
				{ line = under, from = 0, to = 0, style = "diff.minus", lines = removed }
			)
			first = under
		end
		table.insert(out, {
			path = path,
			from = first,
			to = last,
			label = label,
			note = `+{added} -{#removed}`,
			marks = marks,
		})
	end
	return out
end

-- The change under `pos` in a multibuffer made by `diff`: its file's
-- buffer, the file's base, and the hunk.
local function hunk_at(buffer: greed.Buffer, pos: number): (greed.Buffer?, string?, Hunk?)
	local state = states[buffer:id()]
	local base_of = state and state.options.base
	local path, line = M.location(buffer, pos)
	local base = if base_of and path then base_of(path) else nil
	if path == nil or base == nil then
		return nil, nil, nil
	end
	local file = greed.load(path)
	local text = base :: string
	for _, hunk in hunks(text, file:text()) do
		-- Lines only removed show under the line before where they were.
		local first = if hunk.to == hunk.from then math.max(hunk.first - 1, 0) else hunk.first
		if first <= line and line <= hunk.last then
			return file, text, hunk
		end
	end
	return nil, nil, nil
end

--- Puts the change under `pos` back to the multibuffer's `base`, in its
--- file, and shows the view again. Returns false and why when there's no
--- change there to put back.
function M.revert(buffer: greed.Buffer, pos: number): (boolean, string?)
	local file, _, hunk = hunk_at(buffer, pos)
	if file == nil or hunk == nil then
		return false, "no change here"
	end
	file:edit(function(e)
		e:replace(hunk.from, hunk.to, hunk.old)
	end)
	local refresh = states[buffer:id()].options.refresh
	if refresh then
		refresh()
	end
	return true, nil
end

--- The change under `pos` in a multibuffer made by `diff`: its file's path,
--- and the file's base with only that change made, e.g. to stage just it.
--- Nil when there's no change there.
function M.change_at(buffer: greed.Buffer, pos: number): (string?, string?)
	local file, base, hunk = hunk_at(buffer, pos)
	if file == nil or base == nil or hunk == nil then
		return nil, nil
	end
	local new = string.sub(file:text(), hunk.from + 1, hunk.to)
	return file:path(),
		string.sub(base, 1, hunk.at) .. new .. string.sub(base, hunk.at + #hunk.old + 1)
end

-- Each project's results panel, while it's open.
local panels: { [number]: greed.View } = {}

--- Shows `buffer` in the project's results panel on the right, in place of
--- what it showed, or in a new one titled `title`, and focuses it.
function M.show(buffer: greed.Buffer, title: string): greed.View
	local project = greed.project.current().id
	local current = panels[project]
	if current and current:valid() then
		current:show(buffer)
		current:focus()
		return current
	end
	local view = greed.panel(buffer, { side = "right", width = "45%", title = title })
	panels[project] = view
	return view
end

--- Closes the project's results panel, if it's open.
function M.close()
	local project = greed.project.current().id
	local view = panels[project]
	panels[project] = nil
	if view then
		view:close()
	end
end

greed.command({
	name = "multibuffer-open",
	doc = "Go to the line under the cursor in its file",
	run = function(ctx)
		local path, line, column = M.location(ctx.buffer, ctx.view:cursor())
		if path == nil then
			return
		end
		core.file.open_at(path, line, column)
	end,
})

greed.command({
	name = "multibuffer-close",
	doc = "Close the view showing the multibuffer",
	run = function(ctx)
		ctx.view:close()
	end,
})

greed.command({
	name = "multibuffer-revert",
	doc = "Put the change under the cursor back the way it was, in a view of changes",
	run = function(ctx)
		local ok, why = M.revert(ctx.buffer, ctx.view:cursor())
		if not ok then
			greed.echo(why :: string)
		end
	end,
})

greed.keymap.bind({ mode = "normal", kind = "multibuffer" }, {
	enter = "multibuffer-open",
	q = "multibuffer-close",
	["space g r"] = "multibuffer-revert",
})

return M
