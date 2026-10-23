-- Search, like Helix: / and ? search forward and back as you type, n and N
-- go to the next and previous match, and * searches for the selection.
-- Patterns are regexes. How a search you type minds case is `search-case`,
-- unless its kind has its own say, as notes and `:s` do (`kind`).

local greed = require("@greed")
local prompt = require("./prompt")
local registers = require("./registers")
local registry = require("./registry")
local style = require("./style")
local span = require("./text").span

-- The last pattern searched for, and which way.
local last: string? = nil
local backward = false

local function primary(view: greed.View): greed.Range
	local selection = view:selection()
	return selection.ranges[selection.primary]
end

export type Case = "smart" | "ignore" | "match"

greed.option.define({
	name = "search-case",
	doc = 'How searches you type mind case, unless their kind says otherwise: "smart" (only when what you type has a capital letter), "ignore" or "match"',
	default = "smart",
	choices = { "smart", "ignore", "match" },
})

-- The value `option` has when it's a case, else nil.
local function case_of(option: string): Case?
	local value = greed.option.get(option)
	return if value == "smart" or value == "ignore" or value == "match" then value else nil
end

-- How searches of `kind` mind case: as `KIND-search-case` says, or else
-- `search-case`.
local function case(kind: string?): Case
	return (if kind then case_of(`{kind}-search-case`) else nil)
		or case_of("search-case")
		or "smart"
end

-- Makes `KIND-search-case`, how one kind of search minds case, as `default`
-- unless set otherwise; "default" leaves it to `search-case`. It goes when
-- the plugin that made it does.
local function kind(name: string, default: Case | "default", what: string)
	greed.option.define({
		name = `{name}-search-case`,
		doc = `How {what} minds case: "smart" (only when what you type has a capital letter), "ignore", "match", or "default" for as search-case says`,
		default = default,
		choices = { "default", "smart", "ignore", "match" },
	})
end

-- `pattern`, a regex someone typed to search with, minding case as its
-- `kind` says: smart, as Helix does, ignores it unless the pattern has a
-- capital letter.
local function typed(pattern: string, kind: string?): string
	local how = case(kind)
	local ignore = how == "ignore" or (how == "smart" and not string.find(pattern, "%u"))
	return if ignore then "(?i)" .. pattern else pattern
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
	local from, to = buffer:find(typed(pattern), start, { backward = back, wrap = true })
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
		local found: { { from: number, to: number } } = buffer:find_all(typed(pattern)) or {}
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
			local found, _, err = buffer:find(typed(pattern))
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

greed.command({
	name = "search-clear",
	doc = "Take away the search's match highlights, as Vim's :noh does",
	run = function(ctx)
		ctx.buffer:decorate("search", {})
	end,
})

local function word_char(c: string?): boolean
	return c ~= nil and string.match(c, "^[%w_]$") ~= nil
end

-- `text` with a backslash before what regexes take as more than itself.
local function escape(text: string): string
	return (string.gsub(text, "[%^%$%(%)%%%.%[%]%*%+%-%?{}|\\]", "\\%0"))
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
	local pattern = escape(text)
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

-- VS Code's find and replace. ctrl-f opens a bar that finds the text as
-- typed, in any case, and counts the matches; enter and shift-enter go to
-- the next and previous one with the bar open, and esc closes it, leaving
-- the match selected and n (f3) going on from there. ctrl-h asks what to
-- find, lighting the matches, then what to put instead, and replaces them
-- all as one change.

-- `text` as a regex that finds it as written, in any case.
local function plain(text: string): string
	return "(?i)" .. escape(text)
end

-- How the matches of `regex` stand: "3 of 12" when `range` is one of them,
-- else how many there are, or "No results".
local function count(buffer: greed.Buffer, regex: string, range: greed.Range?): string
	local found: { { from: number, to: number } } = buffer:find_all(regex) or {}
	if #found == 0 then
		return "No results"
	end
	if range then
		local from, to = span(range)
		for i, m in found do
			if m.from == from and m.to == to then
				return `{i} of {#found}`
			end
		end
	end
	return if #found == 1 then "1 match" else `{#found} matches`
end

-- The selected text, to start finding with, when it's on one line.
local function selected_text(view: greed.View): string?
	local from, to = span(primary(view))
	local text = view:buffer():slice(from, to)
	return if text ~= "" and not string.find(text, "\n", 1, true) then text else nil
end

local function select_range(view: greed.View, from: number, to: number)
	view:set_selection({ ranges = { { anchor = from, head = to } }, primary = 1 })
end

-- The find bar open for each client, by its id: the view it finds in, what
-- it finds, and the bar.
type Finding = { view: greed.View, regex: string, bar: greed.View }
local finding: { [number]: Finding } = {}

local function show_count(f: Finding)
	f.bar:configure({
		label = if f.regex == "" then "" else count(f.view:buffer(), f.regex, primary(f.view)),
	})
end

greed.command({
	name = "find",
	doc = "Find text in the file as you type, as VS Code's ctrl-f does: "
		.. "enter and shift-enter go to the next and previous match, esc closes",
	run = function(ctx)
		local view, buffer = ctx.view, ctx.buffer
		local client = greed.client.id()
		local start = span(primary(view))
		local f: Finding = { view = view, regex = "", bar = nil :: any }
		local function close()
			buffer:decorate("search", {})
			if finding[client] == f then
				finding[client] = nil
			end
			if f.regex ~= "" then
				last, backward = f.regex, false
				registers.set("/", { f.regex })
			end
		end
		-- Each change finds from where the bar opened, so typing on keeps the
		-- same match while it still matches.
		local function changed(text: string)
			f.regex = if text == "" then "" else plain(text)
			highlight(buffer, f.regex)
			if f.regex ~= "" then
				local from, to = buffer:find(f.regex, start, { wrap = true })
				if from and to then
					select_range(view, from, to)
				end
			end
			show_count(f)
		end
		local text = selected_text(view)
		f.bar = prompt.open({
			title = "find",
			text = text,
			selected = true,
			kind = "find",
			on_change = changed,
			on_submit = close,
			on_cancel = close,
		})
		finding[client] = f
		if text then
			changed(text)
		end
	end,
})

-- Goes to the next match (or the previous, `back`) with the find bar open.
local function find_again(back: boolean)
	local f = finding[greed.client.id()]
	if f == nil or f.regex == "" then
		return
	end
	local from, to = next_match(f.view:buffer(), f.regex, primary(f.view), back)
	if from and to then
		select_range(f.view, from, to)
	end
	show_count(f)
end

greed.command({
	name = "find-next",
	doc = "Go to the next match with the find bar open",
	run = function()
		find_again(false)
	end,
})

greed.command({
	name = "find-prev",
	doc = "Go to the previous match with the find bar open",
	run = function()
		find_again(true)
	end,
})

style.typing_kind("find")
style.label_kind("find", "find")
greed.keymap.bind({ kind = "find" }, {
	enter = "find-next",
	["shift-enter"] = "find-prev",
	f3 = "find-next",
	["shift-f3"] = "find-prev",
	esc = "prompt-cancel",
	["ctrl-c"] = "prompt-cancel",
})

greed.command({
	name = "replace-in-file",
	doc = "Replace text everywhere in the file, as VS Code's ctrl-h does: "
		.. "what to find, with its matches lit and counted, then what to put instead",
	run = function(ctx)
		local view, buffer = ctx.view, ctx.buffer
		local regex = ""
		local function clear()
			buffer:decorate("search", {})
		end
		local bar: greed.View
		local function changed(text: string)
			regex = if text == "" then "" else plain(text)
			highlight(buffer, regex)
			bar:configure({ label = if regex == "" then "" else count(buffer, regex) })
		end
		local function replace_with(replacement: string)
			clear()
			local found: { { from: number, to: number } } = buffer:find_all(regex) or {}
			buffer:edit(function(e)
				for _, m in found do
					e:replace(m.from, m.to, replacement)
				end
			end)
			greed.echo(if #found == 1 then "replaced 1 match" else `replaced {#found} matches`)
		end
		local text = selected_text(view)
		bar = prompt.open({
			title = "replace",
			text = text,
			selected = true,
			on_change = changed,
			on_cancel = clear,
			on_submit = function(typed)
				local found = buffer:find_all(regex) or {}
				if typed == "" or #found == 0 then
					clear()
					if typed ~= "" then
						greed.echo(`no match for {typed}`)
					end
					return
				end
				prompt.open({
					title = `replace {count(buffer, regex)} of {typed} with`,
					on_submit = replace_with,
					on_cancel = clear,
				})
			end,
		})
		if text then
			changed(text)
		end
	end,
})

return {
	--- `pattern`, a regex someone typed, minding case as searches of `kind`
	--- (made with `kind`) do, or else as `search-case` says.
	pattern = typed,
	--- How searches of `kind` mind case: "smart", "ignore" or "match", as
	--- `greed.fuzzy` takes it; without a kind, as `search-case` says.
	case = case,
	--- Makes `KIND-search-case`, so one kind of search (notes, `:s`) minds
	--- case its own way: `default` unless set otherwise, and "default" for
	--- as `search-case` says. `what` names it in the option's doc, like
	--- "searching notes".
	kind = kind,
	--- Modes where a search puts the cursor at the match's start instead of
	--- selecting it; set with `start_at_match`.
	at_start = at_start,
	--- Makes a search in `mode` put the cursor at the match's start instead
	--- of selecting it, like Vim's normal mode, until the plugin that called
	--- this goes.
	start_at_match = function(mode: string)
		greed.plugin.cleanup(registry.set(at_start, mode, true))
	end,
	--- The last pattern searched for, if any.
	last = function(): string?
		return last
	end,
}
