-- Multibuffers: one buffer made of excerpts from many files, edited in
-- place. Typing in an excerpt edits its file as you go (the file opens in
-- Kern the first time one of its excerpts changes), and a change made to
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

local kern = require("@kern")
local core = require("@core")

export type Excerpt = {
	--- The file.
	path: string,
	--- Its first line, 0-based.
	from: number,
	--- Its last line, included; `from` if left out.
	to: number?,
	--- What to show above it; the path, relative to the folder Kern runs
	--- in, if left out.
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
	lines: { string }?,
}

export type Options = {
	--- The first line, above the excerpts, e.g. "12 lines match foo".
	summary: string,
	--- How many lines around each excerpt show with it.
	context: number?,
}

-- One excerpt, as shown.
type Part = {
	path: string,
	label: string,
	-- Shown after the label and line number; the notes of joined excerpts.
	note: string?,
	-- The namespace of its mark in the multibuffer, and in its file's buffer
	-- once that's open.
	ns: string,
	-- Its first line in the file, while the file isn't open.
	start: number,
	-- Its text when it was last the same as the file's.
	text: string,
	-- The file's buffer, once open, and whether the mark there starts with
	-- the line break before the excerpt.
	source: kern.Buffer?,
	lead: boolean,
}

type State = { buffer: kern.Buffer, parts: { Part } }

local M = {}

local states: { [number]: State } = {}

-- While the plugin edits buffers itself, so their change events don't
-- echo back.
local syncing = false

local next_id = 0

local function open_buffer(path: string): kern.Buffer?
	for _, buffer in kern.buffers() do
		if buffer:path() == path then
			return buffer
		end
	end
	return nil
end

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

local function relative(path: string): string
	local cwd = kern.fs.cwd() .. "/"
	return if string.sub(path, 1, #cwd) == cwd then string.sub(path, #cwd + 1) else path
end

-- Byte offsets of lines `from`..`to` of `buffer`, as a mark that also takes
-- the line break before them when there is one, so text typed at the
-- excerpt's start falls inside it.
local function line_mark(buffer: kern.Buffer, from: number, to: number): (kern.Mark, boolean)
	local start = buffer:line_start(from)
	local stop = if to + 1 < buffer:line_count() then buffer:line_start(to + 1) else buffer:len()
	local lead = from > 0
	return { from = if lead then start - 1 else start, to = stop, style = "multibuffer.excerpt" },
		lead
end

-- The text the mark `ns` covers in `buffer`, without the line break before
-- it, and where that text starts; nil if the mark went with its text.
local function marked(buffer: kern.Buffer, ns: string, lead: boolean): (string?, number)
	local mark = buffer:decorations(ns)[1]
	if mark == nil then
		return nil, 0
	end
	local start = mark.from + (if lead then 1 else 0)
	return buffer:slice(start, mark.to), start
end

-- Whether byte `i` of `text` continues a character rather than starting one.
local function continues(text: string, i: number): boolean
	local byte = string.byte(text, i)
	return byte ~= nil and byte >= 0x80 and byte < 0xC0
end

-- Makes `old`, the text at `start` in `buffer`, read `new`, replacing only
-- what lies between the start and end they share. Replacing all of a
-- mark's text would take the mark away with it.
local function rewrite(buffer: kern.Buffer, start: number, old: string, new: string)
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
	-- Text added at the very end would land on the mark's edge and fall
	-- outside it; replacing the last character keeps it in.
	if from == #old and from > 0 then
		from -= 1
		text = string.sub(old, -1) .. text
	end
	syncing = true
	local ok, err = pcall(buffer.edit, buffer, function(e: kern.Edits)
		e:replace(start + from, start + to, text)
	end)
	syncing = false
	if not ok then
		error(err, 0)
	end
end

-- Puts the mark `ns` back over `text` at `start` after the plugin rewrote
-- it, rather than trusting edits at its edges to land inside it. Marks only
-- need to follow edits made by others.
local function place(buffer: kern.Buffer, ns: string, start: number, text: string, lead: boolean)
	if text ~= "" then
		local from = if lead then start - 1 else start
		buffer:decorate(ns, { { from = from, to = start + #text, style = "multibuffer.excerpt" } })
	end
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
local function attach(part: Part, buffer: kern.Buffer, from: number, to: number)
	local mark, lead = line_mark(buffer, from, to)
	buffer:decorate(part.ns, { mark })
	part.source, part.lead = buffer, lead
end

-- Opens `part`'s file the first time its excerpt changes, if the file
-- still reads as it did. Returns false if it doesn't.
local function ensure_source(part: Part): boolean
	if part.source then
		return true
	end
	local buffer = open_buffer(part.path) or kern.load(part.path)
	local to = part.start + #lines_of(part.text) - 1
	if to >= buffer:line_count() then
		return false
	end
	local mark, lead = line_mark(buffer, part.start, to)
	local start = mark.from + (if lead then 1 else 0)
	if buffer:slice(start, mark.to) ~= part.text then
		return false
	end
	attach(part, buffer, part.start, to)
	return true
end

-- The line of `part` in its file where the excerpt starts now.
local function first_line(part: Part): number
	local source = part.source
	if source then
		local _, start = marked(source, part.ns, part.lead)
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
	local headers, numbers = {}, {}
	local width = 1
	for _, part in state.parts do
		width = math.max(width, #tostring(first_line(part) + #lines_of(part.text)))
	end
	for _, part in state.parts do
		local text, start = marked(buffer, part.ns, true)
		if text then
			local above = buffer:line_of(start - 1)
			local line = first_line(part)
			table.insert(headers, {
				from = buffer:line_start(above),
				to = buffer:line_end(above),
				style = "multibuffer.excerpt",
				lines = {
					"",
					header(part, line),
				},
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
			path = excerpt.path,
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
		local buffer = open_buffer(path)
		local text = if buffer then buffer:text() else kern.fs.read(path)
		cache[path] = lines_of(text or "")
	end
	return cache[path]
end

--- A multibuffer of `excerpts`, not shown yet: show it with `kern.panel`,
--- `kern.float` or a view's `show`.
function M.open(excerpts: { Excerpt }, options: Options): kern.Buffer
	next_id += 1
	local id = next_id
	local cache = {}
	local pieces = { options.summary, "\n" }
	local length = #options.summary + 1
	local parts: { Part } = {}
	local ranges: { { ns: string, from: number, to: number } } = {}
	local found: { kern.Mark } = {}
	for i, excerpt in joined(excerpts, options.context or 0) do
		local lines = file_lines(excerpt.path, cache)
		local to = math.min(excerpt.to :: number, #lines - 1)
		if excerpt.from <= to then
			local text = table.concat(lines, "", excerpt.from + 1, to + 1)
			local part: Part = {
				path = excerpt.path,
				label = excerpt.label or relative(excerpt.path),
				note = excerpt.note,
				ns = `multibuffer.{id}.{i}`,
				start = excerpt.from,
				text = text,
				lead = false,
			}
			local shown = as_shown(text)
			table.insert(ranges, { ns = part.ns, from = length - 1, to = length + #shown })
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
			table.insert(parts, part)
		end
	end
	local buffer = kern.create_buffer("multibuffer", table.concat(pieces))
	buffer:set_line_numbers(false)
	for _, range in ranges do
		buffer:decorate(
			range.ns,
			{ { from = range.from, to = range.to, style = "multibuffer.excerpt" } }
		)
	end
	buffer:decorate("multibuffer.found", found)
	local state = { buffer = buffer, parts = parts }
	states[buffer:id()] = state
	-- Files already open are kept in step from the start.
	for _, part in parts do
		local source = open_buffer(part.path)
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
		local shown = marked(state.buffer, part.ns, true)
		local new = as_file(part, shown or "")
		if new == part.text then
			table.insert(kept, part)
		elseif not ensure_source(part) then
			table.insert(problems, part.label)
			table.insert(kept, part)
		else
			local source = part.source :: kern.Buffer
			local old, start = marked(source, part.ns, part.lead)
			if old then
				rewrite(source, start, old, new)
				place(source, part.ns, start, new, part.lead)
			end
			part.text = new
			if shown then
				table.insert(kept, part)
			else
				source:decorate(part.ns, {})
			end
		end
	end
	state.parts = kept
	redraw(state)
	if #problems > 0 then
		kern.echo(`changed since it was found, so left alone: {table.concat(problems, ", ")}`)
	end
end

-- Carries edits made to a file elsewhere into the multibuffers showing it.
local function from_file(buffer: kern.Buffer)
	for _, state in states do
		local changed = false
		for _, part in state.parts do
			local source = part.source
			if source and source:id() == buffer:id() then
				local now = marked(source, part.ns, part.lead)
				if now and now ~= part.text then
					local shown, start = marked(state.buffer, part.ns, true)
					if shown then
						rewrite(state.buffer, start, shown, as_shown(now))
						place(state.buffer, part.ns, start, as_shown(now), true)
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

kern.on("buffer.changed", function(event: kern.BufferChanged)
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

kern.on("buffer.closed", function(event: kern.BufferClosed)
	local state = states[event.id]
	if state then
		states[event.id] = nil
		for _, part in state.parts do
			local source = part.source
			if source then
				pcall(source.decorate, source, part.ns, {})
			end
		end
	end
end)

-- :w saves the files the multibuffer changed.
core.file.on_save("multibuffer", function(buffer: kern.Buffer)
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
	kern.echo(`saved {saved} files`)
end)

--- Where `pos` in a multibuffer is in its files: the path, and the 0-based
--- line and byte column; nil outside the excerpts.
function M.location(buffer: kern.Buffer, pos: number): (string?, number, number)
	local state = states[buffer:id()]
	if state == nil then
		return nil, 0, 0
	end
	for _, part in state.parts do
		local text, start = marked(buffer, part.ns, true)
		if text and pos >= start and pos <= start + #text then
			local line = buffer:line_of(pos)
			local offset = line - buffer:line_of(start)
			return part.path, first_line(part) + offset, pos - buffer:line_start(line)
		end
	end
	return nil, 0, 0
end

-- Each project's results panel, while it's open.
local panels: { [number]: kern.View } = {}

kern.on("view.closed", function(event)
	for project, view in panels do
		if view:id() == event.view then
			panels[project] = nil
		end
	end
end)

--- Shows `buffer` in the project's results panel on the right, in place of
--- what it showed, or in a new one titled `title`, and focuses it.
function M.show(buffer: kern.Buffer, title: string): kern.View
	local project = kern.project.current().id
	local current = panels[project]
	if current then
		current:show(buffer)
		current:focus()
		return current
	end
	local view = kern.panel(buffer, { side = "right", width = "45%", title = title })
	panels[project] = view
	return view
end

--- Closes the project's results panel, if it's open.
function M.close()
	local project = kern.project.current().id
	local view = panels[project]
	panels[project] = nil
	if view then
		view:close()
	end
end

kern.command({
	name = "multibuffer-open",
	doc = "Go to the line under the cursor in its file",
	run = function(ctx)
		local selection = ctx.view:selection()
		local path, line, column = M.location(ctx.buffer, selection.ranges[selection.primary].head)
		if path == nil then
			return
		end
		kern.open(path)
		local view = kern.view()
		local buffer = view:buffer()
		local start = buffer:line_start(math.clamp(line, 0, buffer:line_count() - 1))
		local at = math.min(start + column, buffer:line_end(buffer:line_of(start)))
		view:set_selection({ ranges = { { anchor = at, head = at } }, primary = 1 })
	end,
})

kern.command({
	name = "multibuffer-close",
	doc = "Close the view showing the multibuffer",
	run = function(ctx)
		ctx.view:close()
	end,
})

kern.keymap.bind(
	{ mode = "normal", kind = "multibuffer" },
	{ enter = "multibuffer-open", q = "multibuffer-close" }
)

return M
