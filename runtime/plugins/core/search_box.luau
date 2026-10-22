-- The box a query is typed in, the same wherever one is: mail's search,
-- Hoard's, the shell's filters. It shows the query in colours as it's
-- typed, a dimmed `*` after the word being typed (it matches by prefix
-- until it's settled), what's wrong under the part it's about, and how
-- many results there are; with none, which term leaves the most out.
-- `tab` completes fields, flags and values (through the lsp plugin's
-- completion, which asks `complete`), and `up` and `down` bring back
-- queries submitted before in boxes of the same history.

local greed = require("@greed")
local prompt = require("./prompt")
local query = require("./query")
local recall = require("./recall")
local style = require("./style")

local M = {}

--- The kind of a search box's buffer, for its keys.
M.KIND = "search-box"

-- The namespace of its colours and messages.
local NS = "search-box"

-- How many queries each history keeps.
local KEPT = 50

-- The most terms tried without, to say which leaves results out.
local WITHOUT = 8

-- What `complete` offers, as `core.CompletionItem` has it.
type Item = {
	label: string,
	detail: string?,
	badge: string?,
	kind: number?,
	text: string,
	from: number?,
	snippet: boolean?,
}

--- A word `tab` offers, and what it is.
export type Word = { word: string, what: string? }

export type Options = {
	title: string,
	--- What it starts with.
	text: string?,
	--- What the query runs over: its fields and flags are checked and
	--- completed.
	source: query.Source?,
	--- Words `tab` offers besides the source's, like the shell's `level=`.
	words: (() -> { Word })?,
	--- Values `tab` offers after `field:` (or `=`, `~`…).
	values: ((field: string) -> { string })?,
	--- A leading `/` makes the rest a regex, as the shell's filters take it.
	regex: boolean?,
	--- Which queries `up` brings back: those submitted in boxes of the same
	--- history.
	history: string?,
	--- How many results a query has, and how to say it ("11 of 144 rows";
	--- "N results" by default). Nil for the number when it isn't known,
	--- and both nil to say nothing.
	count: ((parsed: query.Parsed) -> (number?, string?))?,
	on_change: ((text: string, parsed: query.Parsed) -> ())?,
	on_submit: (text: string, parsed: query.Parsed) -> (),
	on_cancel: (() -> ())?,
}

-- An open box: what it was opened with, its view, where `up` has gone,
-- and whether `up` is putting a query in it.
type Box = { options: Options, view: greed.View, walk: recall.Walk?, stepping: boolean? }

-- The box open for each client, by its id.
local boxes: { [number]: Box } = {}

-- Queries submitted, newest first, by history.
local histories: { [string]: { string } } = {}

-- The style each part of a query (`query.paint`) is shown in.
local STYLES: { [string]: string } = {
	field = "attribute",
	operator = "keyword",
	value = "constant",
	phrase = "string",
	regex = "string.regexp",
	paren = "punctuation.bracket",
	view = "label",
}

--- `text` read as a box with `options` reads it, still being typed: a
--- query checked against the source, or after a leading `/` a regex.
function M.read(text: string, options: { regex: boolean?, source: query.Source? }): query.Parsed
	if options.regex and string.sub(text, 1, 1) == "/" then
		local pattern = string.sub(text, 2)
		local parsed: query.Parsed = { view = { sort = {} }, problems = {}, ok = true }
		local _, err = greed.text.matches("", pattern, 1)
		if err then
			parsed.ok = false
			table.insert(parsed.problems, {
				message = `a regex that doesn't work: {err}`,
				at = { from = 1, to = #text },
			})
		elseif pattern ~= "" then
			parsed.query = { kind = "regex", text = pattern, at = { from = 1, to = #text } }
		end
		return parsed
	end
	local parsed = query.parse(text, { typing = true })
	if parsed.ok and options.source then
		for _, problem in query.check(parsed, options.source) do
			table.insert(parsed.problems, problem)
			parsed.ok = false
		end
	end
	return parsed
end

-- The word being typed, marked `live` in `node`, if one is.
local function live_of(node: query.Node?): query.Node?
	if node == nil then
		return nil
	elseif node.live then
		return node
	end
	local items: { query.Node } = node.items or {}
	for _, item in items do
		local found = live_of(item)
		if found then
			return found
		end
	end
	return nil
end

-- `parsed` with only `node` as its query, for counting and printing it.
local function only(parsed: query.Parsed, node: query.Node?): query.Parsed
	return { query = node, view = parsed.view, problems = {}, ok = true }
end

--- What the title says of `parsed`'s results, as `count` gives them: how
--- many, and with none, the term whose leaving out finds the most
--- ("0 results · 40 without from:anna").
function M.status(
	parsed: query.Parsed,
	count: (parsed: query.Parsed) -> (number?, string?)
): string?
	local n, said = count(parsed)
	if n == nil and said == nil then
		return nil
	end
	local text = said or (if n == 1 then "1 result" else `{n} results`)
	local top = parsed.query
	if n ~= 0 or top == nil or top.kind ~= "and" then
		return text
	end
	local items = top.items :: { query.Node }
	local best: query.Node?, most = nil, 0
	for i = 1, math.min(#items, WITHOUT) do
		local rest = table.clone(items)
		table.remove(rest, i)
		local without = count(only(parsed, query.join("and", rest, top.at)))
		if without and without > most then
			best, most = items[i], without
		end
	end
	if best then
		text ..= ` · {most} without {query.print(only(parsed, best))}`
	end
	return text
end

-- Shows `text` in its colours, the `*` of the word being typed, and what's
-- wrong, underlined and said after it.
local function paint(box: Box, text: string, parsed: query.Parsed)
	local marks: { greed.Mark } = {}
	if box.options.regex and string.sub(text, 1, 1) == "/" then
		table.insert(marks, { from = 0, to = #text, style = "string.regexp" })
	else
		for _, part in query.paint(text) do
			local name = STYLES[part.kind]
			if name then
				table.insert(marks, { from = part.from - 1, to = part.to, style = name })
			end
		end
		local live = live_of(parsed.query)
		if live then
			table.insert(
				marks,
				{ from = live.at.to, to = live.at.to, text = "*", style = "comment" }
			)
		end
	end
	-- The first error is said, else the first hint.
	local said: query.Problem? = nil
	for _, problem in parsed.problems do
		local kind = if problem.hint then "hint" else "error"
		table.insert(marks, {
			from = problem.at.from - 1,
			to = math.min(problem.at.to, #text),
			style = `diagnostic.{kind}`,
		})
		if said == nil or (said.hint and not problem.hint) then
			said = problem
		end
	end
	if said then
		local kind = if said.hint then "hint" else "error"
		-- Anchored at the line's start: the end of the text is past the line.
		table.insert(marks, {
			from = 0,
			to = 0,
			text = "  " .. said.message,
			eol = true,
			style = `diagnostic.message.{kind}`,
		})
	end
	box.view:buffer():decorate(NS, marks)
end

-- Says how many results there are in the title, when the box counts them.
local function retitle(box: Box, parsed: query.Parsed)
	local count = box.options.count
	if count == nil or not box.view:valid() then
		return
	end
	local status = if parsed.ok then M.status(parsed, count) else nil
	local title = box.options.title
	box.view:configure({ title = if status then `{status} · {title}` else title })
end

local function text_of(view: greed.View): string
	return (string.gsub(view:buffer():text(), "\n", ""))
end

-- Keeps `text`, submitted in a box of `history`, for `up` to bring back.
local function remember(history: string?, text: string)
	if history == nil or text == "" then
		return
	end
	local list = histories[history] or {}
	histories[history] = list
	local at = table.find(list, text)
	if at then
		table.remove(list, at)
	end
	table.insert(list, 1, text)
	if #list > KEPT then
		table.remove(list)
	end
end

-- Puts the query `by` steps back (or forward) in the acting client's box.
local function step(by: number)
	local box = boxes[greed.client.id()]
	if box == nil or not box.view:valid() then
		return
	end
	local walk: recall.Walk = box.walk
		or recall.walk(text_of(box.view), histories[box.options.history or ""] or {})
	box.walk = walk
	local text = recall.step(walk, by)
	if text == nil then
		return
	end
	local buffer = box.view:buffer()
	box.stepping = true
	buffer:edit(function(e)
		e:replace(0, buffer:len(), text)
	end)
	box.stepping = false
	box.view:set_cursor(#text)
end

greed.command({
	name = "search-box-older",
	doc = "Put the query submitted before this one in the search box",
	run = function()
		step(1)
	end,
})

greed.command({
	name = "search-box-newer",
	doc = "Put the query submitted after this one in the search box",
	run = function()
		step(-1)
	end,
})

style.typing_kind(M.KIND)
style.label_kind(M.KIND, "search")
greed.keymap.bind({ kind = M.KIND }, {
	enter = "prompt-submit",
	esc = "prompt-cancel",
	["ctrl-c"] = "prompt-cancel",
	up = "search-box-older",
	down = "search-box-newer",
})

--- Opens a search box at the bottom of the screen, for the acting client.
--- Returns its view.
function M.open(options: Options): greed.View
	local client = greed.client.id()
	local box: Box? = nil
	-- Shows what's typed and says what it finds, after `on_change` (which
	-- may be what makes the results), unless it's what the box `opening`
	-- starts with.
	local function changed(b: Box, text: string, opening: boolean?)
		local parsed = M.read(text, options)
		paint(b, text, parsed)
		if options.on_change and not opening then
			options.on_change(text, parsed)
		end
		retitle(b, parsed)
	end
	local function done()
		if boxes[client] == box then
			boxes[client] = nil
		end
	end
	local view = prompt.open({
		title = options.title,
		text = options.text,
		kind = M.KIND,
		on_change = function(text: string)
			local b = box
			if b == nil then
				return
			end
			-- What `up` puts there keeps its walk going; typing starts anew.
			if not b.stepping then
				b.walk = nil
			end
			changed(b, text)
		end,
		on_submit = function(text: string)
			done()
			remember(options.history, text)
			options.on_submit(text, M.read(text, options))
		end,
		on_cancel = function()
			done()
			if options.on_cancel then
				options.on_cancel()
			end
		end,
	})
	local opened: Box = { options = options, view = view }
	box = opened
	boxes[client] = opened
	changed(opened, options.text or "", true)
	return view
end

-- `value` as it's written after a field: quoted when it has what would
-- end it.
local function written(value: string): string
	if value == "" or string.find(value, '[%s()"]') then
		local escaped = string.gsub(value, '(["\\])', "\\%1")
		return `"{escaped}"`
	end
	return value
end

--- What `tab` offers in `view`'s search box at its cursor: after
--- `field:`, the field's values (or after `is:` the flags); else fields,
--- flags and the box's words; those with what's typed in them when any
--- have it. Nil when `view` isn't a search box.
function M.complete(view: greed.View): { Item }?
	local box = boxes[greed.client.id()]
	if box == nil or view:buffer():kind() ~= M.KIND then
		return nil
	end
	local options = box.options
	local before = view:buffer():slice(0, view:cursor())
	if options.regex and string.sub(before, 1, 1) == "/" then
		return {}
	end
	local from = (string.find(before, "[^%s(]*$") or #before + 1) - 1
	if string.sub(before, from + 1, from + 1) == "-" then
		from += 1
	end
	local typed = string.sub(before, from + 1)
	local items: { Item } = {}
	local function offer(text: string, detail: string?)
		table.insert(items, { label = text, text = text, detail = detail, from = from })
	end
	local source = options.source
	local flags: { [string]: any } = (source and source.flags) or {}
	local field, op = string.match(typed, "^([%w_][%w_%.%-]*)([:=~<>!]+)")
	if field and op then
		local name = string.lower(field)
		local names = source and source.names
		if name == "is" or name == "has" then
			for flag in flags do
				offer(`{field}{op}{flag}`, "flag")
			end
		elseif (name == "in" or name == "under") and names then
			for _, place in names() do
				offer(`{field}{op}{written(place)}`, "place")
			end
		elseif options.values then
			for _, value in options.values(name) do
				offer(`{field}{op}{written(value)}`)
			end
		end
	else
		if source then
			for name, f in source.fields do
				offer(name .. ":", f.kind)
			end
			for flag in flags do
				offer("is:" .. flag, "flag")
			end
			if source.parent then
				offer("in:", "inside")
				offer("under:", "anywhere under")
			end
			if source.children then
				offer("has:", "holding")
			end
		end
		local words: { Word } = if options.words then options.words() else {}
		for _, word in words do
			offer(word.word, word.what)
		end
	end
	table.sort(items, function(a: Item, b: Item): boolean
		return a.label < b.label
	end)
	local folded = greed.query.fold(typed)
	local holding: { Item } = {}
	for _, item in items do
		if string.find(greed.query.fold(item.label), folded, 1, true) then
			table.insert(holding, item)
		end
	end
	return if #holding > 0 then holding else items
end

return M
