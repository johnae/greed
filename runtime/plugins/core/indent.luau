-- Indentation for new lines: enter, `o` and `O` start the line at the
-- indent the code around it calls for.
--
-- With a language's "indents" query (`queries/<language>/indents.scm`), a
-- new line goes one level in from the line where the innermost node
-- captured as `@indent` around it starts, like a block or an argument
-- list. When the text moving onto it starts with an `@outdent` node, like
-- `}` or `end`, it lines up with that line instead, and so does a line
-- holding just such a closer when enter is pressed on it. Without a query,
-- or where the code doesn't parse yet, a new line keeps the indent of the
-- line it came from, one level more after a line matching the language's
-- `openers` (an opening bracket, by default). A plugin can indent a
-- language its own way with `provider`.

local greed = require("@greed")
local motions = require("./motions")
local registry = require("./registry")
local syntax = require("./syntax")
local text = require("./text")

type Buffer = greed.Buffer

local M = {}

--- The indent for a new line starting at `pos`, where a line break goes
--- in, and whether the text moving onto it closes a block (so it lines up
--- with the block's first line).
export type Provider = (buffer: Buffer, pos: number) -> (string, boolean)

--- Providers by language, used instead of the query and the fallback; set
--- with `provider`.
M.providers = {} :: { [string]: Provider }

--- Indents `language` with `provider`, until the plugin that set it goes.
function M.provider(language: string, provider: Provider)
	greed.plugin.cleanup(registry.set(M.providers, language, provider))
end

--- One level of indent in each language, e.g. "  " or "\t", as the
--- languages plugin sets it with `set`.
M.units = {} :: { [string]: string? }

--- One level of indent in `buffer`: its language's, or the "indent" option.
function M.unit(buffer: Buffer): string
	local language = buffer:language()
	return language and M.units[language] or greed.option.get("indent") :: string
end

--- The indent `line` starts with.
function M.of(buffer: Buffer, line: number): string
	return string.match(buffer:line_text(line), "^[ \t]*") :: string
end

-- Whether `node` is open at `pos`: it holds it, or ends there missing its
-- closing token, as while typing a block.
local function open_at(node: greed.Node, pos: number): boolean
	if node.from >= pos then
		return false
	elseif pos < node.to then
		return true
	end
	local children = node:children()
	local last = children[#children]
	return last ~= nil and last.error and last.from == last.to
end

local function from_query(buffer: Buffer, pos: number, source: string): (string, boolean)
	local finish = buffer:line_end(buffer:line_of(pos))
	local rest = buffer:slice(pos, finish)
	local closer = pos + #(string.match(rest, "^[ \t]*") :: string)
	local inner: greed.Node? = nil
	local closes = false
	-- From just before `pos`, so a block ending there missing its closer counts.
	for _, match in buffer:query(source, { from = math.max(pos - 1, 0), to = finish }) do
		local node = match.indent
		if node and open_at(node, pos) and (inner == nil or node.from >= inner.from) then
			inner = node
		end
		local outdent = match.outdent
		if outdent and outdent.from == closer then
			closes = true
		end
	end
	if inner == nil then
		return "", closes
	end
	local base = M.of(buffer, buffer:line_of(inner.from))
	return if closes then base else base .. M.unit(buffer), closes
end

--- Luau patterns by language for a line after which the next goes a level
--- in, matched against the line up to the break without trailing spaces,
--- e.g. `{ "[%(%[{:]$" }` for Python. Used without an indents query, and
--- with one where the code around the break doesn't parse yet, like a
--- Ruby `def` before its `end` is typed.
M.openers = {} :: { [string]: { string }? }

--- Luau patterns by language for text that goes a level out when it
--- starts a line, like Ruby's `end` or `else`, matched against what comes
--- after the break without leading spaces. Used where `openers` are.
M.closers = {} :: { [string]: { string }? }

--- How many columns apart tab stops are in each language, where it isn't
--- the "tab-width" option.
M.tab_widths = {} :: { [string]: number? }

--- How a language indents: one level (`unit`), its `openers` and
--- `closers` (see above), and how wide a tab shows (`tab_width`).
export type Indents = {
	unit: string?,
	openers: { string }?,
	closers: { string }?,
	tab_width: number?,
}

--- Sets how `language` indents, replacing what it had: those left out are
--- cleared. It goes when the plugin that set it does.
function M.set(language: string, how: Indents)
	M.units[language] = how.unit
	M.openers[language] = how.openers
	M.closers[language] = how.closers
	M.tab_widths[language] = how.tab_width
	M.apply_tab_widths()
	greed.plugin.cleanup(function()
		if M.tab_widths[language] == how.tab_width then
			M.tab_widths[language] = nil
			M.apply_tab_widths()
		end
		if M.units[language] == how.unit then
			M.units[language] = nil
		end
		if M.openers[language] == how.openers then
			M.openers[language] = nil
		end
		if M.closers[language] == how.closers then
			M.closers[language] = nil
		end
	end)
end

local OPENERS = { "[%(%[{]$" }
local CLOSERS = { "^[%)%]}]" }

local function matches(text: string, patterns: { string }): boolean
	for _, pattern in patterns do
		if string.match(text, pattern) then
			return true
		end
	end
	return false
end

-- `indent` one level less.
local function outdented(buffer: Buffer, indent: string): string
	local unit = M.unit(buffer)
	if string.sub(indent, -#unit) == unit then
		return string.sub(indent, 1, -#unit - 1)
	end
	return string.sub(indent, 1, -2)
end

-- By the text: the indent of the last line with text before `pos`, one
-- level more after a line matching `openers`, and one less before text
-- matching `closers` (unless right after an opener, as in `{}`).
local function from_line(
	buffer: Buffer,
	pos: number,
	openers: { string },
	closers: { string }
): (string, boolean)
	local line = buffer:line_of(pos)
	local after = string.match(buffer:slice(pos, buffer:line_end(line)), "^%s*(.*)$") :: string
	local before = buffer:slice(buffer:line_start(line), pos)
	-- On a line with nothing before `pos`, the lines above say.
	while not string.match(before, "%S") and line > 0 do
		line -= 1
		before = buffer:line_text(line)
	end
	before = string.match(before, "^(.-)%s*$") :: string
	local base = if string.match(before, "%S") then M.of(buffer, line) else ""
	local opens, closes = matches(before, openers), matches(after, closers)
	if opens and not closes then
		return base .. M.unit(buffer), false
	elseif closes and not opens then
		return outdented(buffer, base), true
	end
	return base, closes
end

-- Whether the syntax tree has an error around `pos`.
local function broken(buffer: Buffer, pos: number): boolean
	local node = buffer:node_at(math.max(pos - 1, 0))
	while node do
		if node.error then
			return true
		end
		node = node:parent()
	end
	return false
end

--- The indent for a new line starting at `pos`, and whether the text
--- moving onto it closes a block.
function M.at(buffer: Buffer, pos: number): (string, boolean)
	local language = buffer:language()
	local provider = language and M.providers[language]
	if provider then
		return provider(buffer, pos)
	end
	local openers = language and M.openers[language]
	local source = syntax.query(buffer, "indents")
	if source and buffer:tree() and not (openers and broken(buffer, pos)) then
		return from_query(buffer, pos, source)
	end
	return from_line(buffer, pos, openers or OPENERS, language and M.closers[language] or CLOSERS)
end

--- Whether the character just typed starts its line at some cursor: only
--- blanks before it. A closing bracket typed there lines up with its
--- block; anywhere else there's nothing to work out.
function M.typed_first(view: greed.View): boolean
	local buffer = view:buffer()
	for _, range in view:selection().ranges do
		local start = buffer:line_start(buffer:line_of(range.head))
		local typed = buffer:prev_char(range.head)
		if typed >= start and string.match(buffer:slice(start, typed), "^[ \t]*$") then
			return true
		end
	end
	return false
end

--- Lines up each cursor's line with its block when what's on it before
--- the cursor closes one, like `end` or `}` typed at its start.
function M.reindent(view: greed.View)
	local buffer = view:buffer()
	local changes = {}
	for _, range in view:selection().ranges do
		local line = buffer:line_of(range.head)
		local start = buffer:line_start(line)
		local current = M.of(buffer, line)
		if start + #current < range.head then
			local wanted, closes = M.at(buffer, start + #current)
			if closes and wanted ~= current then
				table.insert(changes, { from = start, to = start + #current, text = wanted })
			end
		end
	end
	-- An edit that changes nothing would still be an undo step.
	if #changes == 0 then
		return
	end
	buffer:edit(function(e)
		for _, change in changes do
			e:replace(change.from, change.to, change.text)
		end
	end)
end

-- Breaks the line at each cursor, as `M.break_lines` says; the cursors in
-- `above` instead get a line put in above the first one.
local function break_lines(view: greed.View, above: { [number]: boolean })
	local buffer = view:buffer()
	local br = text.line_break(buffer)
	motions.replace_each(view, function(i, range)
		local pos = range.head
		if above[i] then
			return { text = br, place = "start", from = pos, to = pos }
		end
		local line = buffer:line_of(pos)
		local start = buffer:line_start(line)
		local before = buffer:slice(start, pos)
		local after = buffer:slice(pos, buffer:line_end(line))
		local indent, closes = M.at(buffer, pos)
		local from = if string.match(before, "^[ \t]+$") then start else pos
		local to = pos + #(string.match(after, "^[ \t]*") :: string)
		if closes and string.match(before, "[%(%[{][ \t]*$") then
			local unit = M.unit(buffer)
			return {
				text = br .. indent .. unit .. br .. indent,
				place = #br + #indent + #unit,
				from = from,
				to = to,
			}
		end
		return { text = br .. indent, place = "end", from = from, to = to }
	end)
end

--- Breaks the line at each cursor and starts the new line at its indent,
--- leaving the cursor there. Spaces right after the cursor go, and so does
--- the indent of a line left blank. Between brackets, the closing one gets
--- a line of its own below.
function M.break_lines(view: greed.View)
	M.reindent(view)
	break_lines(view, {})
end

--- Opens a line below (or above) each cursor's line at the indent it calls
--- for, with the cursor on it.
function M.open(view: greed.View, below: boolean)
	local buffer = view:buffer()
	local selection = view:selection()
	local above = {}
	for i, range in selection.ranges do
		local line = buffer:line_of(range.head)
		-- A line above is a line below the one before, except at the top.
		local at = if below
			then buffer:line_end(line)
			elseif line > 0 then buffer:line_end(line - 1)
			else 0
		above[i] = not below and line == 0
		selection.ranges[i] = { anchor = at, head = at }
	end
	view:set_selection(selection)
	break_lines(view, above)
end

greed.option.define({
	name = "tab-width",
	doc = "How many columns apart tab stops are, in languages that don't set their own",
	default = 4,
})

--- Shows `buffer`'s tabs as wide as its language says, or the "tab-width"
--- option; again after its language changes.
function M.apply_tab_width(buffer: Buffer)
	local language = buffer:language()
	local width = language and M.tab_widths[language] or greed.option.get("tab-width") :: number
	buffer:set_tab_width(math.max(1, math.floor(width)))
end

--- Applies `apply_tab_width` to every open buffer.
function M.apply_tab_widths()
	for _, buffer in greed.buffers() do
		M.apply_tab_width(buffer)
	end
end

greed.on("buffer.opened", function(event: greed.BufferChanged)
	M.apply_tab_width(event.buffer)
end)

greed.on("option.changed", function(event)
	if event.name == "tab-width" then
		M.apply_tab_widths()
	end
end)

return M
