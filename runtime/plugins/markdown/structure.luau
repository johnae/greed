-- A Markdown file's structure: its headings, code blocks, list items,
-- tables and links, worked out once per version of a buffer and shared by
-- everything that reads Markdown (the look, folds, notes, blocks, prose).
-- Blocks come from the syntax tree, so a `# comment` in a code block isn't
-- a heading; without a tree (a file's text, a buffer too big to parse, or
-- just after an edit while parsing catches up) lines are read one by one.
-- Lines are 0-based and bytes 0-based, end exclusive, as everywhere.

local greed = require("@greed")
local tables = require("./tables")

local M = {}

--- A heading: `#` to `######`, or text underlined with `===` (level 1)
--- or `---` (level 2). `line` to `last` are its lines (two or more only
--- when underlined), `text` its words without the markup, `from` where
--- it starts (after a quote's `>`).
export type Heading = {
	level: number,
	text: string,
	line: number,
	last: number,
	underlined: boolean,
	from: number,
}

--- A fenced code block, ```` ```sh ```` to its closing fence: `open` and
--- `close` are the fences' lines (`close` the last line of the file when
--- it's never closed), `from` to `to` the bytes from the opening fence to
--- the end of the closing one, `code_from` to `code_to` the code between.
export type Code = {
	info: string,
	lang: string,
	fence: string,
	open: number,
	close: number,
	closed: boolean,
	from: number,
	to: number,
	code_from: number,
	code_to: number,
}

--- A list item: its bullet ("-", "+", "*", or "1." and "1)" for numbered
--- ones), its box if it's a todo (" ", "x" or "X"), and its lines, those of
--- items under it included. `from` is where the bullet is.
export type Item = {
	bullet: string,
	check: string?,
	line: number,
	last: number,
	indent: number,
	from: number,
}

--- A table, from its header row to its last row.
export type Table = { first: number, last: number }

--- A link, `[text](target)`, or an image, `![text](target)`, outside code:
--- `from` to `to` all of it, `target_from` where its target starts.
export type Link = {
	line: number,
	from: number,
	to: number,
	text: string,
	target: string,
	target_from: number,
	image: boolean,
}

export type Structure = {
	--- The buffer's version it was worked out for.
	version: number,
	--- Each line's text and where it starts.
	lines: { string },
	starts: { number },
	--- The last line of the front matter, `---` lines around YAML at the
	--- top, if there is some.
	front: number?,
	headings: { Heading },
	code: { Code },
	items: { Item },
	tables: { Table },
	links: { Link },
	--- What's on each line: the heading, the code block, the list item
	--- that starts there, the table.
	heading_at: { [number]: Heading },
	code_at: { [number]: Code },
	item_at: { [number]: Item },
	table_at: { [number]: Table },
	--- The lines a code block, a table or a list item spans.
	inside: { [number]: boolean },
}

-- `text`'s lines, without their line breaks, and where each starts.
local function split(text: string): ({ string }, { number })
	local lines, starts = {}, {}
	local at = 1
	while true do
		local nl = string.find(text, "\n", at, true)
		local line = string.sub(text, at, (nl or #text + 1) - 1)
		if string.sub(line, -1) == "\r" then
			line = string.sub(line, 1, -2)
		end
		table.insert(lines, line)
		table.insert(starts, at - 1)
		if nl == nil then
			break
		end
		at = nl + 1
	end
	return lines, starts
end

local function blank(text: string): boolean
	return string.find(text, "^%s*$") ~= nil
end

--- A fence line's ticks or tildes and what follows them, inside quotes
--- and list items too.
function M.fence(text: string): (string?, string)
	local ticks, rest = string.match(text, "^[%s>]*(```+)(.*)$")
	if ticks == nil then
		ticks, rest = string.match(text, "^[%s>]*(~~~+)(.*)$")
	end
	return ticks, rest or ""
end

-- Whether `text` closes a fence opened by `ticks`.
local function closes(text: string, ticks: string): boolean
	local found, rest = M.fence(text)
	return found ~= nil
		and string.sub(found, 1, 1) == string.sub(ticks, 1, 1)
		and #found >= #ticks
		and blank(rest)
end

-- An ATX heading's level and words, or nil.
local function atx(text: string): (number?, string)
	local hashes, rest = string.match(text, "^ ? ? ?(#+)(.*)$")
	if
		hashes == nil
		or rest == nil
		or #hashes > 6
		or not (rest == "" or string.find(rest, "^%s"))
	then
		return nil, ""
	end
	local words = string.match(rest, "^%s*(.-)%s*$") or ""
	-- A closing run of #s goes, if a space comes before it.
	words = string.gsub(words, "^#+$", "") :: string
	words = string.gsub(words, "%s+#+$", "") :: string
	return #hashes, words
end

-- A list item's indent, bullet and what's after it, or nil.
local function bullet_of(text: string): (string?, string?, string)
	local spaces, bullet, rest = string.match(text, "^(%s*)([-*+])(.*)$")
	if spaces == nil then
		spaces, bullet, rest = string.match(text, "^(%s*)(%d%d?%d?%d?%d?%d?%d?%d?%d?[.)])(.*)$")
	end
	if spaces == nil or not (rest == "" or string.find(rest :: string, "^%s")) then
		return nil, nil, ""
	end
	return spaces, bullet, rest :: string
end

--- Whether `text` is a rule: three or more `-`, `*` or `_`, all the same,
--- maybe with spaces between.
function M.rule(text: string): boolean
	local marks = string.gsub(text, "%s", "") :: string
	return #marks >= 3
		and string.find(text, "^ ? ? ?[-*_]") ~= nil
		and (
			string.find(marks, "^%-+$") ~= nil
			or string.find(marks, "^%*+$") ~= nil
			or string.find(marks, "^_+$") ~= nil
		)
end
local rule = M.rule

-- A list item on `line`, starting at byte `col` (1-based) of its text, to
-- its last non-blank line `last`.
local function item(s: Structure, line: number, col: number, last: number): Item?
	local text = s.lines[line + 1]
	local _, bullet, rest = bullet_of(string.sub(text, col))
	if bullet == nil then
		return nil
	end
	while last > line and blank(s.lines[last + 1]) do
		last -= 1
	end
	return {
		bullet = bullet,
		check = string.match(rest, "^%s+%[([ xX])%]"),
		line = line,
		last = last,
		indent = col - 1,
		from = s.starts[line + 1] + col - 1,
	}
end

-- The code block between fences on lines `open` and `close`.
local function code(s: Structure, open: number, close: number): Code
	local ticks, info = M.fence(s.lines[open + 1])
	local fence = ticks or "```"
	local closed = close > open and closes(s.lines[close + 1], fence)
	local function line_end(n: number): number
		return s.starts[n + 1] + #s.lines[n + 1]
	end
	local trimmed = string.match(info, "^%s*(.-)%s*$") :: string
	local body_last = if closed then close - 1 else close
	return {
		info = trimmed,
		lang = string.match(trimmed, "^[^%s]+") or "",
		fence = fence,
		open = open,
		close = close,
		closed = closed,
		from = s.starts[open + 1] + #(string.match(s.lines[open + 1], "^[%s>]*") :: string),
		to = line_end(close),
		code_from = if open < #s.lines - 1 then s.starts[open + 2] else line_end(open),
		code_to = if body_last > open
			then line_end(body_last)
			else math.max(s.starts[close + 1], s.starts[open + 1] + #s.lines[open + 1]),
	}
end

-- Adds the heading `#`s start at byte `col` (1-based) of line `n`.
local function heading(s: Structure, n: number, col: number, level: number, words: string)
	table.insert(s.headings, {
		level = level,
		text = words,
		line = n,
		last = n,
		underlined = false,
		from = s.starts[n + 1] + col - 1,
	})
end

-- Adds the heading made of lines `first` to `last - 1` from byte `col`
-- (1-based) on, underlined by line `last`.
local function underlined(s: Structure, first: number, last: number, col: number)
	local parts = {}
	for k = first, last - 1 do
		table.insert(parts, (string.match(string.sub(s.lines[k + 1], col), "^[%s>]*(.-)%s*$")))
	end
	table.insert(s.headings, {
		level = if string.find(s.lines[last + 1], "=", 1, true) then 1 else 2,
		text = table.concat(parts, " "),
		line = first,
		last = last,
		underlined = true,
		from = s.starts[first + 1] + col - 1,
	})
end

-- The table whose header is line `n`, if one is.
local function table_at(s: Structure, n: number): Table?
	local lines = s.lines
	if n + 1 >= #lines then
		return nil
	end
	local header = tables.cells(lines[n + 1])
	local aligns = tables.aligns(lines[n + 2])
	if header == nil or aligns == nil or #header ~= #aligns then
		return nil
	end
	local last = n + 1
	while last + 1 < #lines and not blank(lines[last + 2]) and tables.cells(lines[last + 2]) do
		last += 1
	end
	return { first = n, last = last }
end

-- The blocks, read line by line: CommonMark's main rules, enough where
-- there's no syntax tree. From line `from` (default 0) until `stop` says to,
-- given the line and the last line a block found so far reaches; returns
-- the line it stopped at.
local function scan(
	s: Structure,
	from: number?,
	stop: ((n: number, reach: number) -> boolean)?
): number
	local lines = s.lines
	local count = #lines
	-- Where the paragraph being read began, for underlined headings.
	local paragraph: number? = nil
	local reach = -1
	local n = from or 0
	while n < count do
		if stop and stop(n, reach) then
			return n
		end
		local text = lines[n + 1]
		-- Most lines are prose: one starting with a letter, without a pipe,
		-- only goes on with a paragraph.
		if string.find(text, "^%s*%a") and not string.find(text, "|", 1, true) then
			paragraph = paragraph or n
			n += 1
			continue
		end
		local ticks = M.fence(text)
		if ticks then
			local close = n + 1
			while close < count and not closes(lines[close + 1], ticks) do
				close += 1
			end
			table.insert(s.code, code(s, n, math.min(close, count - 1)))
			reach = math.max(reach, close)
			paragraph, n = nil, close + 1
			continue
		end
		-- In a quote too, after its `>`.
		local body = string.match(text, "^ ? ? ?>%s?()") or 1
		local level, words = atx(string.sub(text, body))
		local underline = paragraph
			and (string.match(text, "^ ? ? ?(=+)%s*$") or string.match(text, "^ ? ? ?(%-+)%s*$"))
		if level then
			heading(
				s,
				n,
				body + #(string.match(string.sub(text, body), "^ *") :: string),
				level,
				words
			)
			paragraph = nil
		elseif underline and paragraph then
			underlined(s, paragraph, n, 1)
			paragraph = nil
		elseif blank(text) then
			paragraph = nil
		else
			local found = if string.find(text, "|", 1, true) then table_at(s, n) else nil
			if found then
				table.insert(s.tables, found)
				reach = math.max(reach, found.last)
				paragraph, n = nil, found.last + 1
				continue
			end
			local spaces, bullet = bullet_of(text)
			if bullet and spaces and not rule(text) then
				-- To the last line indented under it, before one that isn't.
				local depth = #spaces
				local last = n
				for k = n + 1, count - 1 do
					local indent = string.match(lines[k + 1], "^(%s*)%S")
					if indent and #indent <= depth then
						break
					end
					last = k
				end
				local found_item = item(s, n, depth + 1, last)
				if found_item then
					table.insert(s.items, found_item)
					reach = math.max(reach, found_item.last)
				end
				paragraph = nil
			elseif paragraph == nil and not rule(text) then
				paragraph = n
			end
		end
		n += 1
	end
	return math.min(n, count)
end

-- The line `pos` is on, by `starts`.
local function line_of(starts: { number }, pos: number): number
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

local QUERY = "[(atx_heading) (setext_heading) (fenced_code_block) (list_item) (pipe_table)] @n"

-- The blocks, from `buffer`'s syntax tree. False without one.
local function from_tree(s: Structure, buffer: greed.Buffer): boolean
	if buffer:language() ~= "markdown" or buffer:tree() == nil then
		return false
	end
	local starts = s.starts
	for _, match in buffer:query(QUERY) do
		local node = match.n
		local first = line_of(starts, node.from)
		-- Nodes end after their last line break.
		local last = line_of(starts, math.max(node.from, node.to - 1))
		local kind = node.kind
		local col = node.from - starts[first + 1] + 1
		if kind == "atx_heading" then
			local level, words = atx(string.sub(s.lines[first + 1], col))
			heading(s, first, col, level or 1, words)
		elseif kind == "setext_heading" then
			underlined(s, first, last, col)
		elseif kind == "fenced_code_block" then
			local block = code(s, first, last)
			-- One never closed goes on to the end, the last empty line too.
			if not block.closed and node.to >= starts[#starts] then
				block = code(s, first, #starts - 1)
			end
			table.insert(s.code, block)
		elseif kind == "list_item" then
			local found = item(s, first, col, last)
			if found then
				table.insert(s.items, found)
			end
		else
			while last > first and blank(s.lines[last + 1]) do
				last -= 1
			end
			table.insert(s.tables, { first = first, last = last })
		end
	end
	-- Matches come in the tree's order, nested ones after their parents.
	table.sort(s.items, function(a: Item, b: Item)
		return a.from < b.from
	end)
	table.sort(s.code, function(a: Code, b: Code)
		return a.open < b.open
	end)
	return true
end

-- The links on lines `first` to `last` outside code, leaving out those in
-- code spans.
local function find_links(s: Structure, first: number, last: number)
	for n = first + 1, last + 1 do
		local text = s.lines[n]
		if s.code_at[n - 1] or not string.find(text, "](", 1, true) then
			continue
		end
		local spans: { { number } } = {}
		for from, to in string.gmatch(text, "()`[^`]+`()") do
			table.insert(spans, { from :: number, (to :: number) - 1 })
		end
		for from, bang, label, inside, target, to in
			string.gmatch(text, "()(!?)%[([^%]]*)%]%(()([^%)]*)%)()")
		do
			local start, stop = from :: number, (to :: number) - 1
			local free = true
			for _, span in spans do
				if start <= span[2] and stop >= span[1] then
					free = false
				end
			end
			local lead, url = string.match(target :: string, "^(%s*<?)([^%s>]+)")
			if free and url and lead then
				local at = s.starts[n]
				table.insert(s.links, {
					line = n - 1,
					from = at + start - 1,
					to = at + stop,
					text = label :: string,
					target = url,
					target_from = at + (inside :: number) - 1 + #(lead :: string),
					image = bang == "!",
				})
			end
		end
	end
end

-- The last line of the front matter, `---` lines around YAML at the top,
-- if there is some.
local function front_matter(lines: { string }): number?
	if not string.find(lines[1], "^%-%-%-%s*$") or not string.find(lines[2] or "", "^[%w_-]+:") then
		return nil
	end
	for n = 2, math.min(#lines, 100) do
		if string.find(lines[n], "^%-%-%-%s*$") or string.find(lines[n], "^%.%.%.%s*$") then
			return n - 1
		end
	end
	return nil
end

-- An empty structure for `lines`.
local function empty(lines: { string }, starts: { number }, version: number): Structure
	return {
		version = version,
		lines = lines,
		starts = starts,
		front = front_matter(lines),
		headings = {},
		code = {},
		items = {},
		tables = {},
		links = {},
		heading_at = {},
		code_at = {},
		item_at = {},
		table_at = {},
		inside = {},
	}
end

-- Fills in what's on each line.
local function index(s: Structure)
	for _, heading in s.headings do
		for n = heading.line, heading.last do
			s.heading_at[n] = heading
		end
	end
	for _, block in s.code do
		for n = block.open, block.close do
			s.code_at[n] = block
			s.inside[n] = true
		end
	end
	for _, found in s.items do
		s.item_at[found.line] = s.item_at[found.line] or found
		for n = found.line, found.last do
			s.inside[n] = true
		end
	end
	for _, found in s.tables do
		for n = found.first, found.last do
			s.table_at[n] = found
			s.inside[n] = true
		end
	end
end

-- The structure of `text`, from `buffer`'s tree if it's given and has one.
local function build(text: string, buffer: greed.Buffer?, version: number): Structure
	local lines, starts = split(text)
	local s = empty(lines, starts, version)
	if not (buffer and from_tree(s, buffer)) then
		scan(s)
	end
	-- Front matter, between `---` lines at the top, is neither.
	local front = s.front
	if front then
		local function after(list: { any }, key: string): { any }
			local kept = {}
			for _, entry in list do
				if entry[key] > front then
					table.insert(kept, entry)
				end
			end
			return kept
		end
		s.headings = after(s.headings, "line")
		s.code = after(s.code, "open")
		s.items = after(s.items, "line")
		s.tables = after(s.tables, "first")
	end
	index(s)
	find_links(s, 0, #lines - 1)
	return s
end

-- `old`'s entries in `list` that start at or before line `before`, then
-- `window`'s, then `old`'s that start at or after line `after`, moved by
-- `moved`.
local function join<T>(
	list: { T },
	window: { T },
	line: (T) -> number,
	before: number,
	after: number?,
	moved: (T) -> T
): { T }
	local out: { T } = {}
	for _, entry in list do
		if line(entry) <= before then
			table.insert(out, entry)
		end
	end
	table.move(window, 1, #window, #out + 1, out)
	if after then
		for _, entry in list do
			if line(entry) >= after then
				table.insert(out, moved(entry))
			end
		end
	end
	return out
end

-- The structure of `text`, which was `old` until lines `from` to `to` (as
-- they are now) changed: lines are read again from a blank line before them
-- that no block spans to one after them where old and new agree again, and
-- the rest is moved. Nil when that can't be told, near front matter say.
local function splice(
	text: string,
	old: Structure,
	from: number,
	to: number,
	version: number
): Structure?
	local lines, starts = split(text)
	local s = empty(lines, starts, version)
	if s.front ~= old.front then
		return nil
	end
	local start = math.min(from, #old.lines) - 1
	while start > 0 and not (blank(old.lines[start + 1]) and not old.inside[start]) do
		start -= 1
	end
	if start <= 0 or (s.front and start <= s.front) then
		return nil
	end
	local count, delta = #lines, #lines - #old.lines
	local stop = scan(s, start + 1, function(n: number, reach: number): boolean
		local was = n - delta
		return n > to
			and reach < n
			and blank(lines[n + 1])
			and was >= 0
			and blank(old.lines[was + 1])
			and not old.inside[was]
	end)
	local after = if stop < count then stop - delta else nil
	local bytes = #text - (old.starts[#old.starts] + #old.lines[#old.lines])
	s.headings = join(
		old.headings,
		s.headings,
		function(h: Heading)
			return h.line
		end,
		start,
		after,
		function(h: Heading): Heading
			return {
				level = h.level,
				text = h.text,
				line = h.line + delta,
				last = h.last + delta,
				underlined = h.underlined,
				from = h.from + bytes,
			}
		end
	)
	s.code = join(
		old.code,
		s.code,
		function(c: Code)
			return c.open
		end,
		start,
		after,
		function(c: Code): Code
			return {
				info = c.info,
				lang = c.lang,
				fence = c.fence,
				open = c.open + delta,
				close = c.close + delta,
				closed = c.closed,
				from = c.from + bytes,
				to = c.to + bytes,
				code_from = c.code_from + bytes,
				code_to = c.code_to + bytes,
			}
		end
	)
	s.items = join(
		old.items,
		s.items,
		function(i: Item)
			return i.line
		end,
		start,
		after,
		function(i: Item): Item
			return {
				bullet = i.bullet,
				check = i.check,
				line = i.line + delta,
				last = i.last + delta,
				indent = i.indent,
				from = i.from + bytes,
			}
		end
	)
	s.tables = join(
		old.tables,
		s.tables,
		function(t: Table)
			return t.first
		end,
		start,
		after,
		function(t: Table): Table
			return { first = t.first + delta, last = t.last + delta }
		end
	)
	index(s)
	find_links(s, start + 1, stop - 1)
	s.links = join(
		old.links,
		s.links,
		function(l: Link)
			return l.line
		end,
		start,
		after,
		function(l: Link): Link
			return {
				line = l.line + delta,
				from = l.from + bytes,
				to = l.to + bytes,
				text = l.text,
				target = l.target,
				target_from = l.target_from + bytes,
				image = l.image,
			}
		end
	)
	return s
end

local cache: { [number]: Structure } = {}

--- The structure of `source`: a buffer's, kept until it changes, or a
--- file's text.
function M.of(source: greed.Buffer | string): Structure
	if type(source) == "string" then
		return build(source, nil, 0)
	end
	local buffer = source :: greed.Buffer
	local version = buffer:version()
	local cached = cache[buffer:id()]
	if cached and cached.version == version then
		return cached
	end
	local s = build(buffer:text(), buffer, version)
	cache[buffer:id()] = s
	return s
end

--- The structure of `buffer`, which was `old` until lines `from` to `to`
--- (as they are now) changed: like `of`, reading only what's around them
--- again.
function M.update(buffer: greed.Buffer, old: Structure, from: number, to: number): Structure
	local version = buffer:version()
	local cached = cache[buffer:id()]
	if cached and cached.version == version then
		return cached
	end
	local s = splice(buffer:text(), old, from, to, version) or build(buffer:text(), buffer, version)
	cache[buffer:id()] = s
	return s
end

function M.forget(id: number)
	cache[id] = nil
end

-- What else, besides the changed lines themselves, is drawn again when
-- they change: blocks spanning lines, whose look depends on all of them.
-- A table's border goes on the line above it.
type Span = { first: number, last: number, key: string }

local function spans(s: Structure): { Span }
	local out: { Span } = {}
	for _, block in s.code do
		table.insert(out, {
			first = block.open,
			last = block.close,
			key = `code {block.closed} {block.info}`,
		})
	end
	for _, found in s.tables do
		table.insert(
			out,
			{ first = math.max(found.first - 1, 0), last = found.last, key = "table" }
		)
	end
	for _, heading in s.headings do
		if heading.underlined then
			table.insert(out, { first = heading.line, last = heading.last, key = "heading" })
		end
	end
	return out
end

--- The lines to draw again in a buffer whose structure went from `old` to
--- `new` when lines `from` to `to` (as they are now) changed: those, a line
--- either side, and every block spanning lines that changed, moved or
--- appeared, like the rest of a file after a code block's fence opens it.
function M.affected(old: Structure, new: Structure, from: number, to: number): (number, number)
	local count = #new.lines
	local delta = count - #old.lines
	local old_to = to - delta
	local first, last = math.max(from - 1, 0), math.min(to + 1, count - 1)
	local now = spans(new)
	local function cover(a: number, b: number)
		first, last = math.min(first, a), math.max(last, b)
	end
	-- The blocks away from the change, as they'd be if nothing else moved.
	local kept: { [string]: Span } = {}
	for _, span in spans(old) do
		local a, b = span.first, span.last
		if b < from then
			-- Above the change: where it was.
		elseif a > old_to then
			a, b = a + delta, b + delta
		else
			cover(math.min(a, from), if b > old_to then b + delta else to)
			continue
		end
		kept[`{a} {b} {span.key}`] = { first = a, last = b, key = span.key }
	end
	for _, span in now do
		local key = `{span.first} {span.last} {span.key}`
		if span.last >= from and span.first <= to then
			cover(span.first, span.last)
		elseif kept[key] then
			kept[key] = nil
		else
			cover(span.first, span.last)
		end
	end
	for _, span in kept do
		cover(span.first, span.last)
	end
	-- Blocks are drawn whole, so those reaching into the lines are too.
	local grown = true
	while grown do
		grown = false
		for _, span in now do
			if
				span.last >= first
				and span.first <= last
				and (span.first < first or span.last > last)
			then
				cover(span.first, span.last)
				grown = true
			end
		end
	end
	return math.max(first, 0), math.min(last, count - 1)
end

return M
