-- Search, like Helix: / and ? search forward and back as you type, n and N
-- go to the next and previous match, and * searches for the selection.
-- Patterns are regexes; ones in lowercase ignore case.

local greed = require("@greed")
local prompt = require("./prompt")
local registers = require("./registers")
local registry = require("./registry")

-- The last pattern searched for, and which way.
local last: string? = nil
local backward = false

local function primary(view: greed.View): greed.Range
	local selection = view:selection()
	return selection.ranges[selection.primary]
end

local function span(range: greed.Range): (number, number)
	return math.min(range.anchor, range.head), math.max(range.anchor, range.head)
end

-- Lowercase patterns ignore case, like Helix's smart case.
local function smart_case(pattern: string): string
	return if string.find(pattern, "%u") then pattern else "(?i)" .. pattern
end

-- Where a search for the next match starts: after the selection, or after
-- the character under a cursor.
local function after(buffer: greed.Buffer, range: greed.Range): number
	local from, to = span(range)
	return if to > from then to else buffer:next_char(from)
end

-- The match of `pattern` after `range` (or before it, going back), round
-- the ends.
local function next_match(
	buffer: greed.Buffer,
	pattern: string,
	range: greed.Range,
	back: boolean
): (number?, number?)
	local start = if back then span(range) else after(buffer, range)
	local from, to = buffer:find(smart_case(pattern), start, { backward = back, wrap = true })
	if from == nil then
		return nil, nil
	end
	return from, to
end

-- Modes where a search puts the cursor at the start of the match rather
-- than selecting it, like Vim's normal mode.
local at_start: { [string]: boolean } = {}

-- Selects the match of `pattern` after `range` (or before it, going back),
-- round the ends, or puts the cursor at its start in a mode in `at_start`.
-- Returns whether there was one.
local function jump(
	view: greed.View,
	pattern: string,
	range: greed.Range,
	back: boolean,
	mode: string
): boolean
	local from, to = next_match(view:buffer(), pattern, range, back)
	if from and to then
		local head = if at_start[mode] then from else to
		view:set_selection({ ranges = { { anchor = from, head = head } }, primary = 1 })
		return true
	end
	return false
end

local function highlight(buffer: greed.Buffer, pattern: string)
	local marks: { greed.Mark } = {}
	if pattern ~= "" then
		local found: { { from: number, to: number } } = buffer:find_all(smart_case(pattern)) or {}
		for _, m in found do
			if m.to > m.from then
				table.insert(marks, { from = m.from, to = m.to, style = "ui.search.match" })
			end
		end
	end
	buffer:decorate("search", marks)
end

local function search(ctx: greed.Context, back: boolean)
	local view, buffer = ctx.view, ctx.buffer
	local origin = view:selection()
	local start = primary(view)
	local mode = greed.mode.get()
	prompt.open({
		title = if back then "search back" else "search",
		on_change = function(pattern)
			highlight(buffer, pattern)
			view:set_selection(origin)
			if pattern ~= "" then
				jump(view, pattern, start, back, mode)
			end
		end,
		on_submit = function(pattern)
			buffer:decorate("search", {})
			if pattern == "" then
				return
			end
			-- Nil, nil and the error for a bad pattern.
			local found, _, err = buffer:find(smart_case(pattern))
			if found == nil and err then
				greed.echo(`bad pattern {pattern}: {err}`)
				return
			end
			last, backward = pattern, back
			registers.set("/", { pattern })
			if found == nil then
				greed.echo(`no match for {pattern}`)
			end
		end,
		on_cancel = function()
			buffer:decorate("search", {})
			view:set_selection(origin)
		end,
	})
end

-- Adds the next match of the last search as a selection of its own, and
-- makes it the primary one.
local function add_next(ctx: greed.Context, reverse: boolean)
	if last == nil then
		greed.echo("nothing searched for yet")
		return
	end
	local selection = ctx.view:selection()
	local from, to = next_match(ctx.buffer, last, primary(ctx.view), backward ~= reverse)
	if from == nil or to == nil then
		greed.echo(`no match for {last}`)
		return
	end
	for _, range in selection.ranges do
		local a, b = span(range)
		if a < to and from < b then
			greed.echo("no more matches")
			return
		end
	end
	table.insert(selection.ranges, { anchor = from, head = to })
	table.sort(selection.ranges, function(a: greed.Range, b: greed.Range)
		return span(a) < span(b)
	end)
	for i, range in selection.ranges do
		if span(range) == from then
			selection.primary = i
		end
	end
	ctx.view:set_selection(selection)
end

-- Goes to the next match of the last search, the same way it went (or the
-- other way, with `reverse`).
local function again(ctx: greed.Context, reverse: boolean)
	if last == nil then
		greed.echo("nothing searched for yet")
		return
	end
	if not jump(ctx.view, last, primary(ctx.view), backward ~= reverse, greed.mode.get()) then
		greed.echo(`no match for {last}`)
	end
end

greed.command({
	name = "search",
	doc = "Search forward for a regex as you type",
	run = function(ctx)
		search(ctx, false)
	end,
})

greed.command({
	name = "search-back",
	doc = "Search backward for a regex as you type",
	run = function(ctx)
		search(ctx, true)
	end,
})

greed.command({
	name = "search-next",
	doc = "Select the next match of the last search",
	run = function(ctx)
		again(ctx, false)
	end,
})

greed.command({
	name = "search-prev",
	doc = "Select the previous match of the last search",
	run = function(ctx)
		again(ctx, true)
	end,
})

greed.command({
	name = "search-next-add",
	doc = "Add the next match of the last search as another selection",
	run = function(ctx)
		add_next(ctx, false)
	end,
})

greed.command({
	name = "search-prev-add",
	doc = "Add the previous match of the last search as another selection",
	run = function(ctx)
		add_next(ctx, true)
	end,
})

local function word_char(c: string?): boolean
	return c ~= nil and string.match(c, "^[%w_]$") ~= nil
end

-- Searches for the primary selection's text, as plain text in the same
-- case. With `words`, a selection that starts or ends a word only matches
-- there, so a whole word doesn't match inside a longer one.
local function search_selection(ctx: greed.Context, words: boolean)
	local buffer = ctx.buffer
	local from, to = span(primary(ctx.view))
	local text = buffer:slice(from, to)
	if text == "" then
		greed.echo("nothing selected to search for")
		return
	end
	local pattern = (string.gsub(text, "[%^%$%(%)%%%.%[%]%*%+%-%?{}|\\]", "\\%0"))
	if words then
		local before = if from > 0 then buffer:char_at(buffer:prev_char(from)) else nil
		if word_char(buffer:char_at(from)) and not word_char(before) then
			pattern = "\\b" .. pattern
		end
		local last_char = buffer:char_at(buffer:prev_char(to))
		if word_char(last_char) and not word_char(buffer:char_at(to)) then
			pattern ..= "\\b"
		end
	end
	pattern = "(?-i)" .. pattern
	last, backward = pattern, false
	registers.set("/", { pattern })
	greed.echo(`searching for {text}`)
end

greed.command({
	name = "search-selection",
	doc = "Search for the selected text, as whole words where it starts or ends one",
	run = function(ctx)
		search_selection(ctx, true)
	end,
})

greed.command({
	name = "search-selection-anywhere",
	doc = "Search for the selected text, also inside longer words",
	run = function(ctx)
		search_selection(ctx, false)
	end,
})

return {
	smart_case = smart_case,
	--- Modes where a search puts the cursor at the match's start instead of
	--- selecting it; set with `start_at_match`.
	at_start = at_start,
	--- Makes a search in `mode` put the cursor at the match's start instead
	--- of selecting it, like Vim's normal mode, until the plugin that called
	--- this goes.
	start_at_match = function(mode: string)
		greed.plugin.tie(registry.set(at_start, mode, true))
	end,
	--- The last pattern searched for, if any.
	last = function(): string?
		return last
	end,
}
