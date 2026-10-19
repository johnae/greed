-- The query language every search and filter in Greed speaks: mail, notes
-- and todos, chat, the shell's filters and saved query blocks. Words and
-- phrases search text, `field:value` and comparisons filter, a space means
-- AND, `OR` and `NOT` (uppercase) and `-` combine, parentheses group:
--
--     from:anna is:unread date:2w..
--     is:todo -is:done due:..+7d in:(tag:garden) sort:due
--     invoice OR receipt has:attachment -from:noreply
--
-- `parse` turns the text into a tree, the same for every source, with what
-- it got wrong and where; `print` writes a tree back in its one canonical
-- form. What a field means is up to the source that runs the query (a
-- `Source`): `check` says what a query asks of it that it hasn't, and `run`
-- runs it over items in memory. Indexes run the same tree in Rust, and
-- test/query_cases.json holds what both must agree on.

local greed = require("@greed")
local dates = require("./dates")

local M = {}

--- Where something is in the query's text: from and to, as `string.find`
--- gives them.
export type At = { from: number, to: number }

--- A part of a query. `kind` says which:
---
--- - "word": `text` searched for, a `phrase` when it was quoted, by
---   `prefix` when it ends in `*`, or because it's the word being typed
---   (`live`, see `parse`'s `typing`).
--- - "field": `field`, `op` (":", "=", "~", "!=", "!~", "<", "<=", ">",
---   ">=") and either `value` (with `phrase`, `prefix` and `live` as a word
---   has them), a `range` (`date:2w..`: `low` and `high`, either missing),
---   a `regex`, or a subquery in `items[1]` (`in:(tag:garden)`).
--- - "regex": `text`, a pattern, matched against the text.
--- - "and", "or": `items`, all of them or any.
--- - "not": `items[1]`, which mustn't match.
export type Node = {
	kind: string,
	at: At,
	text: string?,
	phrase: boolean?,
	prefix: boolean?,
	live: boolean?,
	field: string?,
	op: string?,
	value: string?,
	low: string?,
	high: string?,
	regex: string?,
	items: { Node }?,
}

--- How results are shown, from `sort:`, `limit:`, `group:` and `show:`.
export type View = {
	sort: { { field: string, descending: boolean } },
	limit: number?,
	group: string?,
	show: { string }?,
}

--- Something wrong with a query, or worth saying about it (`hint`: it
--- still runs).
export type Problem = { message: string, at: At, hint: boolean? }

--- A parsed query: `query` is nil when there's nothing to filter by, or
--- when it has problems that aren't hints (`ok` is then false).
export type Parsed = { query: Node?, view: View, problems: { Problem }, ok: boolean }

-- How deep parentheses may nest.
local DEEPEST = 5

-- Operators, longest first so `<=` isn't read as `<`.
local OPS: { string } = { "!=", "!~", "<=", ">=", ":", "=", "~", "<", ">" }

-- The fields that say how results are shown rather than which.
local VIEW = { sort = true, limit = true, group = true, show = true }

type Token = { kind: string, text: string, from: number, to: number }

-- Splits `text` into tokens: "(", ")", "string" (a quoted phrase, its
-- text unescaped), "regex" (`/…/`, its pattern) and "bare" (anything
-- else, up to a space, a parenthesis or a quote).
local function tokens(text: string, problems: { Problem }): { Token }
	local out: { Token } = {}
	local i, n = 1, #text
	while i <= n do
		local c = string.sub(text, i, i)
		if string.match(c, "%s") then
			i += 1
		elseif c == "(" or c == ")" then
			table.insert(out, { kind = c :: string, text = c :: string, from = i, to = i })
			i += 1
		elseif
			c == '"'
			or (c == "/" and (i == 1 or string.match(string.sub(text, i - 1, i - 1), "[%s(]")))
		then
			-- A phrase or a regex, to its closing mark; a backslash keeps
			-- the next character.
			local parts: { string } = {}
			local j = i + 1
			local closed = false
			while j <= n do
				local d = string.sub(text, j, j)
				if d == "\\" and j < n then
					local next_char = string.sub(text, j + 1, j + 1)
					-- In a regex the backslash stays, unless it keeps a `/`.
					if c == "/" and next_char ~= "/" then
						table.insert(parts, d)
					end
					table.insert(parts, next_char)
					j += 2
				elseif d == c then
					closed = true
					break
				else
					table.insert(parts, d)
					j += 1
				end
			end
			if not closed then
				local what = if c == '"' then 'a "' else "a / starting a regex"
				table.insert(
					problems,
					{ message = `{what} without its closing one`, at = { from = i, to = i } }
				)
				j = n
			end
			table.insert(out, {
				kind = if c == '"' then "string" else "regex",
				text = table.concat(parts),
				from = i,
				to = j,
			})
			i = j + 1
		else
			local j = i
			while j <= n do
				local d = string.sub(text, j, j)
				if string.match(d, '[%s()"]') then
					break
				end
				j += 1
			end
			table.insert(
				out,
				{ kind = "bare", text = string.sub(text, i, j - 1), from = i, to = j - 1 }
			)
			i = j
		end
	end
	return out
end

-- `text` split as `field`, operator and the rest when it starts with a
-- field name and an operator ("from:anna", "size>1M", "due:<=eow").
local function split_field(text: string): (string?, string?, string?)
	local field = string.match(text, "^[%a_][%w_%.%-]*")
	if field == nil then
		return nil, nil, nil
	end
	local rest = string.sub(text, #field + 1)
	for _, op in OPS do
		if string.sub(rest, 1, #op) == op then
			local value = string.sub(rest, #op + 1)
			-- GitHub's `created:>2026-01-01`: the comparison after the colon.
			if op == ":" then
				for _, cmp in OPS do
					if
						cmp ~= ":"
						and cmp ~= "="
						and cmp ~= "~"
						and string.sub(value, 1, #cmp) == cmp
					then
						return field, cmp, string.sub(value, #cmp + 1)
					end
				end
			end
			return field, op, value
		end
	end
	return nil, nil, nil
end

local function is_op(text: string): boolean
	return text ~= ":" and table.find(OPS, text) ~= nil
end

--- Parses `text` into a query. With `typing`, the text is still being
--- typed: a word (or a field's value) at its very end matches by prefix,
--- marked `live`, so results show as you type; ending it with a space,
--- or a `*`, settles it.
function M.parse(text: string, opts: { typing: boolean? }?): Parsed
	local problems: { Problem } = {}
	local view: View = { sort = {} }
	local list = tokens(text, problems)
	local pos = 1
	local typing = opts ~= nil and opts.typing == true and not string.match(text, "%s$")

	local function problem(message: string, from: number, to: number, hint: boolean?)
		table.insert(problems, { message = message, at = { from = from, to = to }, hint = hint })
	end

	local function adjacent(token: Token, after: Token?): boolean
		return after ~= nil and after.from == token.to + 1
	end

	-- A word's or value's text, with `prefix` set by a `*` at its end.
	local function settle(node: Node, raw: string, token: Token)
		if #raw > 1 and string.sub(raw, -1) == "*" then
			node.prefix = true
			raw = string.sub(raw, 1, -2)
		elseif raw == "*" then
			problem(
				"a * goes at the end of a word, to find words starting with it",
				token.from,
				token.to
			)
		elseif typing and token == list[#list] then
			node.prefix = true
			node.live = true
		end
		if node.kind == "word" then
			node.text = raw
		else
			node.value = raw
		end
	end

	local and_list: (depth: number, top: boolean) -> { Node }

	-- The terms inside the parentheses `open` starts, and where its `)`
	-- ends (nil when it has none).
	local function group(open: Token, depth: number, unclosed: string): ({ Node }, number?)
		if depth + 1 > DEEPEST then
			problem(`( ) nest at most {DEEPEST} deep`, open.from, open.to)
		end
		local inner = and_list(depth + 1, false)
		local close = list[pos]
		if close and close.kind == ")" then
			pos += 1
			return inner, close.to
		end
		problem(unclosed, open.from, open.to)
		return inner, nil
	end

	-- A view term (`sort:due`, `limit:20`) into `view`; false when `field`
	-- isn't one.
	local function view_term(
		field: string,
		op: string,
		value: string,
		token: Token,
		top: boolean
	): boolean
		if not VIEW[field] or op ~= ":" then
			return false
		end
		if not top then
			problem(
				`{field}: says how results show, so it can't go inside OR, NOT or ( )`,
				token.from,
				token.to
			)
			return true
		end
		local parts = string.split(value, ",")
		if field == "sort" then
			for _, part in parts do
				local descending = string.sub(part, 1, 1) == "-"
				local name = if descending then string.sub(part, 2) else part
				if name == "" then
					problem(
						"sort: needs a field, like sort:date or sort:-date",
						token.from,
						token.to
					)
				else
					table.insert(view.sort, { field = name, descending = descending })
				end
			end
		elseif field == "limit" then
			local n = tonumber(value)
			if n == nil or n < 1 or n % 1 ~= 0 then
				problem("limit: needs a whole number, like limit:20", token.from, token.to)
			else
				view.limit = n
			end
		elseif field == "group" then
			view.group = value
		else
			view.show = parts
		end
		return true
	end

	-- The term a bare token starts: a field with its value, or a word.
	local function bare(token: Token, depth: number, top: boolean): Node?
		local raw = token.text
		local field, op, value = split_field(raw)
		-- `AGE < 1h`, with spaces around the operator, as `where` takes it.
		if field == nil and string.match(raw, "^[%a_][%w_%.%-]*$") then
			local spaced = list[pos]
			local after = list[pos + 1]
			if
				spaced
				and spaced.kind == "bare"
				and is_op(spaced.text)
				and after
				and after.kind ~= "("
			then
				pos += 2
				field, op, value = raw, spaced.text, after.text
				token = { kind = "bare", text = raw, from = token.from, to = after.to }
				if after.kind == "string" then
					return {
						kind = "field",
						field = field,
						op = op,
						value = value,
						phrase = true,
						at = { from = token.from, to = token.to },
					}
				end
			end
		end
		if field == nil then
			local node: Node = { kind = "word", at = { from = token.from, to = token.to } }
			settle(node, raw, token)
			return node
		end
		local f, o, v = field :: string, op :: string, value :: string
		local node: Node =
			{ kind = "field", field = f, op = o, at = { from = token.from, to = token.to } }
		if v == "" then
			local after = list[pos]
			if adjacent(token, after) and after.kind == "string" then
				pos += 1
				node.value = after.text
				node.phrase = true
				node.at.to = after.to
			elseif adjacent(token, after) and after.kind == "regex" then
				pos += 1
				node.regex = after.text
				node.at.to = after.to
			elseif adjacent(token, after) and after.kind == "(" then
				pos += 1
				local inner, to = group(after, depth, `a ( after {f}{o} without its )`)
				node.at.to = to or node.at.to
				node.items = { M.join("and", inner, node.at) }
			else
				problem(
					`{f}{o} needs a value right after it, like {f}{o}something`,
					token.from,
					token.to
				)
				return nil
			end
			return node
		end
		if view_term(f, o, v, token, top) then
			return nil
		end
		local low, high = string.match(v, "^(.-)%.%.(.*)$")
		if o == ":" and low ~= nil then
			node.low = if low ~= "" then low else nil
			node.high = if high ~= "" then high else nil
			if node.low == nil and node.high == nil then
				problem(`a range needs an end, like {f}:2w.. or {f}:..today`, token.from, token.to)
			end
		elseif #v > 1 and string.sub(v, 1, 1) == "/" and string.sub(v, -1) == "/" then
			node.regex = string.sub(v, 2, -2)
		else
			settle(node, v, token)
		end
		return node
	end

	local unary: (depth: number, top: boolean) -> Node?

	local function atom(depth: number, top: boolean): Node?
		local token = list[pos]
		pos += 1
		if token.kind == "(" then
			local inner, to = group(token, depth, "a ( without its )")
			local at: At = { from = token.from, to = to or token.to }
			if #inner == 0 then
				problem("( ) with nothing in them", at.from, at.to)
				return nil
			end
			return M.join("and", inner, at)
		elseif token.kind == ")" then
			problem("a ) without its (", token.from, token.to)
			return nil
		elseif token.kind == "string" then
			return {
				kind = "word",
				text = token.text,
				phrase = true,
				at = { from = token.from, to = token.to },
			}
		elseif token.kind == "regex" then
			return { kind = "regex", text = token.text, at = { from = token.from, to = token.to } }
		end
		return bare(token, depth, top)
	end

	function unary(depth: number, top: boolean): Node?
		local token = list[pos]
		local negated = false
		if token.kind == "bare" and token.text == "NOT" then
			pos += 1
			negated = true
		elseif token.kind == "bare" and token.text == "-" then
			pos += 1
			if not adjacent(token, list[pos]) and list[pos] then
				problem("- goes right before what it leaves out, like -word", token.from, token.to)
				return nil
			end
			negated = true
		elseif token.kind == "bare" and #token.text > 1 and string.sub(token.text, 1, 1) == "-" then
			-- `-from:x`: the rest of it, negated.
			list[pos] = {
				kind = "bare",
				text = string.sub(token.text, 2),
				from = token.from + 1,
				to = token.to,
			}
			negated = true
		end
		if negated then
			if list[pos] == nil or list[pos].kind == ")" then
				problem("NOT or - needs something after it", token.from, token.to)
				return nil
			end
			local item = unary(depth, false)
			if item == nil then
				return nil
			end
			return { kind = "not", items = { item }, at = { from = token.from, to = item.at.to } }
		end
		return atom(depth, top)
	end

	local function or_expr(depth: number, top: boolean): Node?
		local first = list[pos]
		if first.kind == "bare" and first.text == "OR" then
			pos += 1
			problem("OR needs something before it", first.from, first.to)
			return nil
		end
		local items: { Node } = {}
		local node = unary(depth, top)
		if node then
			table.insert(items, node)
		end
		while list[pos] and list[pos].kind == "bare" and list[pos].text == "OR" do
			local word = list[pos]
			pos += 1
			if list[pos] == nil or list[pos].kind == ")" then
				problem("OR needs something after it", word.from, word.to)
				break
			end
			local next_node = unary(depth, false)
			if next_node then
				table.insert(items, next_node)
			end
		end
		if #items <= 1 then
			return items[1]
		end
		return M.join("or", items, { from = items[1].at.from, to = items[#items].at.to })
	end

	function and_list(depth: number, top: boolean): { Node }
		local items: { Node } = {}
		while list[pos] and list[pos].kind ~= ")" do
			local token = list[pos]
			if token.kind == "bare" and token.text == "AND" then
				pos += 1
				continue
			end
			local lower = if token.kind == "bare" then token.text else nil
			if
				(lower == "or" or lower == "and" or lower == "not")
				and #items > 0
				and list[pos + 1]
			then
				problem(
					`searching for the word "{lower}"; did you mean {string.upper(lower)}?`,
					token.from,
					token.to,
					true
				)
			end
			local node = or_expr(depth, top)
			if node then
				table.insert(items, node)
			end
		end
		return items
	end

	local items: { Node } = {}
	while pos <= #list do
		for _, node in and_list(0, true) do
			table.insert(items, node)
		end
		if list[pos] and list[pos].kind == ")" then
			problem("a ) without its (", list[pos].from, list[pos].to)
			pos += 1
		end
	end
	local ok = true
	for _, p in problems do
		if not p.hint then
			ok = false
		end
	end
	local query = if ok and #items > 0
		then M.join("and", items, { from = items[1].at.from, to = items[#items].at.to })
		else nil
	return { query = query, view = view, problems = problems, ok = ok }
end

--- `items` joined as `kind` ("and" or "or"): the one item itself when
--- there's one, and an "and" in an "and" (or an "or" in an "or") flattened.
function M.join(kind: string, items: { Node }, at: At): Node
	if #items == 1 then
		return items[1]
	end
	local flat: { Node } = {}
	for _, item in items do
		if item.kind == kind then
			for _, inner in item.items :: { Node } do
				table.insert(flat, inner)
			end
		else
			table.insert(flat, item)
		end
	end
	return { kind = kind, items = flat, at = at }
end

-- Whether `text` must be quoted to read back as one word or value: it has
-- what would end it or change it (a space, a quote, a parenthesis, a `*`
-- at its end, `..`), starts like a negation, a regex or a comparison, is
-- an operator, or would read as a field (`a:b`).
local function needs_quotes(text: string): boolean
	return text == ""
		or string.match(text, '[%s()"\\]') ~= nil
		or string.find(text, "..", 1, true) ~= nil
		or text == "OR"
		or text == "AND"
		or text == "NOT"
		or string.match(text, "^[%-/!<>=~]") ~= nil
		or string.sub(text, -1) == "*"
		or split_field(text) ~= nil
end

local function quoted(text: string): string
	return '"' .. (string.gsub(text, '(["\\])', "\\%1")) .. '"'
end

-- A word's or value's text as it's written, quoted when it must be.
local function written(text: string, phrase: boolean?, prefix: boolean?, live: boolean?): string
	local out = if phrase or needs_quotes(text) then quoted(text) else text
	if prefix and not live then
		out ..= "*"
	end
	return out
end

local function written_regex(pattern: string): string
	return "/" .. (string.gsub(pattern, "/", "\\/")) .. "/"
end

local function print_node(node: Node, inside: string?): string
	local kind = node.kind
	if kind == "word" then
		return written(node.text :: string, node.phrase, node.prefix, node.live)
	elseif kind == "regex" then
		return written_regex(node.text :: string)
	elseif kind == "field" then
		local head = (node.field :: string) .. (node.op :: string)
		if node.items then
			return head .. "(" .. print_node((node.items :: { Node })[1]) .. ")"
		elseif node.regex then
			return head .. written_regex(node.regex :: string)
		elseif node.low or node.high then
			return head .. (node.low or "") .. ".." .. (node.high or "")
		end
		return head .. written(node.value :: string, node.phrase, node.prefix, node.live)
	elseif kind == "not" then
		local item = (node.items :: { Node })[1]
		return if item.kind == "and" or item.kind == "or"
			then "-(" .. print_node(item) .. ")"
			else "-" .. print_node(item)
	end
	local parts: { string } = {}
	for _, item in node.items :: { Node } do
		table.insert(parts, print_node(item, kind))
	end
	local joined = table.concat(parts, if kind == "or" then " OR " else " ")
	-- OR binds tighter than the space between terms, so only an "and" in
	-- an "or" needs its parentheses.
	if kind == "and" and inside == "or" then
		return "(" .. joined .. ")"
	end
	return joined
end

--- `parsed` written in its one canonical form: what a query block saves
--- and an agent sees. `parse(print(p))` gives the same tree.
function M.print(parsed: Parsed): string
	local parts: { string } = {}
	if parsed.query then
		table.insert(parts, print_node(parsed.query))
	end
	local view = parsed.view
	if #view.sort > 0 then
		local keys: { string } = {}
		for _, key in view.sort do
			table.insert(keys, (if key.descending then "-" else "") .. key.field)
		end
		table.insert(parts, "sort:" .. table.concat(keys, ","))
	end
	if view.limit then
		table.insert(parts, `limit:{view.limit}`)
	end
	if view.group then
		table.insert(parts, "group:" .. view.group)
	end
	if view.show then
		table.insert(parts, "show:" .. table.concat(view.show, ","))
	end
	return table.concat(parts, " ")
end

--- A field of the items a query runs over. `kind` says how its values
--- match: "text" by words, "exact" as whole values without minding case
--- (tags, states, names), "value" through `greed.compare` (numbers, sizes,
--- durations, levels), "date" as dates ("2026-10-14", or ISO 8601 with a
--- time). `get` gives an item's value or values, nil when it has none. A
--- date field `ahead` reads `2w` and `monday` as coming (a due date).
export type Field = {
	kind: string,
	get: (item: any) -> (string | { string })?,
	ahead: boolean?,
}

--- What a query runs over: the items' `fields` by name (in lower case),
--- their `flags` for `is:`, their `text` for words, and where they sit, for
--- `in:`, `under:` and `has:` (`parent`, `children`, and whether an item is
--- `named` something). Words match whole words, or with `words` "anywhere",
--- anywhere in the text, as the shell's filters do.
export type Source = {
	fields: { [string]: Field },
	flags: { [string]: (item: any) -> boolean }?,
	text: (item: any) -> string,
	words: string?,
	parent: ((item: any) -> any)?,
	children: ((item: any) -> { any })?,
	named: ((item: any, name: string) -> boolean)?,
}

-- Fields every source understands, beside its own.
local PLACES = { ["in"] = true, under = true, has = true }

-- The flags `is:` or `has:` names in `node`: the one by its name, or
-- every one it starts, by prefix (`is:unr` while it's typed).
local function flags_named(source: Source, node: Node): { (item: any) -> boolean }
	local name = string.lower(node.value or "")
	local out: { (item: any) -> boolean } = {}
	local all: { [string]: (item: any) -> boolean } = source.flags or {}
	for flag, test in all do
		if flag == name or (node.prefix and string.sub(flag, 1, #name) == name) then
			table.insert(out, test)
		end
	end
	return out
end

-- Whether `item` is any of the flags `node` names.
local function flagged(source: Source, node: Node, item: any): boolean
	for _, test in flags_named(source, node) do
		if test(item) then
			return true
		end
	end
	return false
end

-- How many edits apart `a` and `b` are, or `most` + 1 when their lengths
-- alone say they're further apart than that.
local function edits(a: string, b: string, most: number): number
	if math.abs(#a - #b) > most then
		return most + 1
	end
	-- `before[j + 1]`: how far the first i - 1 letters of `a` are from the
	-- first j of `b`.
	local before: { number } = {}
	for j = 1, #b + 1 do
		before[j] = j - 1
	end
	for i = 1, #a do
		local now: { number } = { i }
		for j = 1, #b do
			local same = if string.sub(a, i, i) == string.sub(b, j, j) then 0 else 1
			now[j + 1] = math.min(before[j + 1] + 1, now[j] + 1, before[j] + same)
		end
		before = now
	end
	return before[#b + 1]
end

-- The name among `names` closest to `name`, if one is near enough to be
-- what was meant.
local function closest(name: string, names: { string }): string?
	local best: string?, distance = nil, 3
	for _, other in names do
		local d = edits(name, other, 2)
		if d < distance then
			best, distance = other, d
		end
	end
	return best
end

local function sorted_keys(t: { [string]: any }): { string }
	local keys: { string } = {}
	for key in t do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

--- What's wrong with `parsed` for `source`: fields and flags it hasn't
--- (with the one likely meant), dates that aren't dates, regexes that
--- don't compile, places it can't look in. Empty when it can run.
function M.check(parsed: Parsed, source: Source): { Problem }
	local problems: { Problem } = {}
	local fields = sorted_keys(source.fields)
	local flags = sorted_keys(source.flags or {})
	local function problem(message: string, at: At)
		table.insert(problems, { message = message, at = at })
	end
	local function date_ok(field: Field, text: string?, at: At)
		if text and dates.span(text, field.ahead) == nil then
			problem(`{text} isn't a date; try today, 2w, monday, 2026-10 or this week`, at)
		end
	end
	local function regex_ok(pattern: string, at: At)
		local _, err = greed.text.matches("", pattern, 1)
		if err then
			problem(`a regex that doesn't work: {err}`, at)
		end
	end
	local function walk(node: Node)
		if node.kind == "regex" then
			regex_ok(node.text :: string, node.at)
			return
		elseif node.kind ~= "field" then
			local items: { Node } = node.items or {}
			for _, item in items do
				walk(item)
			end
			return
		end
		local name = string.lower(node.field :: string)
		-- `is:x`, and `has:x` without a subquery, name a flag.
		if name == "is" or (name == "has" and node.items == nil) then
			local flag = string.lower(node.value or "")
			if #flags_named(source, node) == 0 then
				local near = closest(flag, flags)
				problem(
					if near
						then `nothing here is {flag}; did you mean {name}:{near}?`
						else `nothing here is {flag}; it can be {table.concat(flags, ", ")}`,
					node.at
				)
			end
		end
		if name == "is" then
			return
		elseif PLACES[name] then
			if
				(name == "has" and source.children == nil)
				or (name ~= "has" and source.parent == nil)
			then
				problem(`{name}: needs items that sit in others, and these don't`, node.at)
			end
			if node.items then
				walk((node.items :: { Node })[1])
			end
			return
		end
		local field = source.fields[name]
		if field == nil then
			local near = closest(name, fields)
			problem(
				if near
					then `no field {name} here; did you mean {near}?`
					else `no field {name} here; the fields are {table.concat(fields, ", ")}`,
				node.at
			)
			return
		end
		if node.regex then
			regex_ok(node.regex :: string, node.at)
		elseif field.kind == "date" then
			date_ok(field, node.low, node.at)
			date_ok(field, node.high, node.at)
			date_ok(field, node.value, node.at)
		end
		if node.items then
			walk((node.items :: { Node })[1])
		end
	end
	if parsed.query then
		walk(parsed.query)
	end
	for _, key in parsed.view.sort do
		if source.fields[string.lower(key.field)] == nil then
			problem(`can't sort by {key.field}: there's no such field here`, { from = 1, to = 1 })
		end
	end
	return problems
end

-- `word` in lower case as a Lua pattern, matching itself.
local function literal(word: string): string
	return (string.gsub(word, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

-- Whether `text` (in lower case) has `word` (in lower case): as a whole
-- word, or one starting with it with `prefix`, or anywhere with
-- `anywhere`. Where a word starts or ends with something that isn't a
-- letter or digit ("c++"), that end matches wherever it is.
local function has_word(text: string, word: string, prefix: boolean?, anywhere: boolean?): boolean
	if anywhere or word == "" then
		return string.find(text, word, 1, true) ~= nil
	end
	local head = if string.match(word, "^%w") then "%f[%w]" else ""
	local tail = if prefix or not string.match(word, "%w$") then "" else "%f[%W]"
	return string.find(text, head .. literal(word) .. tail) ~= nil
end

-- Whether the regex `pattern` matches anywhere in `text`.
local function finds(text: string, pattern: string): boolean
	local found = greed.text.matches(text, pattern, 1)
	return found ~= nil and #found > 0
end

-- An item's values for `field`, as a list.
local function values_of(field: Field, item: any): { string }
	local got = field.get(item)
	if got == nil then
		return {}
	elseif type(got) == "string" then
		return { got }
	end
	return got :: { string }
end

-- Whether one value passes `op` against `want`, as `field`'s kind says.
local function passes(
	field: Field,
	have: string,
	op: string,
	want: string,
	prefix: boolean?
): boolean
	local kind = field.kind
	if kind == "date" then
		local day = string.sub(have, 1, 10)
		local from, to = dates.span(want, field.ahead)
		if from == nil or to == nil then
			return false
		elseif op == ":" or op == "=" then
			return day >= from and day <= to
		elseif op == "<" then
			return day < from
		elseif op == "<=" then
			return day <= to
		elseif op == ">" then
			return day > to
		elseif op == ">=" then
			return day >= from
		end
		return false
	elseif kind == "value" then
		return greed.compare.test(have, if op == ":" then "=" else op, want)
	end
	local text, wanted = string.lower(have), string.lower(want)
	if op == ":" and kind == "text" then
		return has_word(text, wanted, prefix)
	elseif op == ":" or op == "=" then
		return if prefix then string.sub(text, 1, #wanted) == wanted else text == wanted
	elseif op == "~" then
		return string.find(text, wanted, 1, true) ~= nil
	end
	return greed.compare.test(have, op, want)
end

local function in_range(field: Field, have: string, low: string?, high: string?): boolean
	if field.kind == "date" then
		local day = string.sub(have, 1, 10)
		-- From the first day of where it starts to the last of where it ends.
		if low then
			local from = dates.span(low, field.ahead)
			if from == nil or day < from then
				return false
			end
		end
		if high then
			local _, to = dates.span(high, field.ahead)
			if to == nil or day > to then
				return false
			end
		end
		return true
	end
	return (low == nil or greed.compare.order(have, low) >= 0)
		and (high == nil or greed.compare.order(have, high) <= 0)
end

-- Whether any of `have`, values of `field`, passes `op` against `want`.
local function any_passes(
	field: Field,
	have: { string },
	op: string,
	want: string,
	prefix: boolean?
): boolean
	for _, value in have do
		if passes(field, value, op, want, prefix) then
			return true
		end
	end
	return false
end

-- Whether `have`, the values of `field`, match `node` with its words read
-- as that field's values: the inside of `tag:(garden OR kitchen)`, where
-- `tag:(work money)` wants both.
local function within(field: Field, node: Node, have: { string }): boolean
	if node.kind == "word" then
		return any_passes(field, have, ":", node.text :: string, node.prefix)
	elseif node.kind == "and" or node.kind == "or" then
		local all = node.kind == "and"
		for _, item in node.items :: { Node } do
			if within(field, item, have) ~= all then
				return not all
			end
		end
		return all
	elseif node.kind == "not" then
		return not within(field, (node.items :: { Node })[1], have)
	end
	return false
end

-- Whether `field`'s values pass the field term `node`. A negative test
-- (`!=`, `!~`) passes when none of them is what it says, and when there
-- are none.
local function field_matches(field: Field, node: Node, item: any): boolean
	local have = values_of(field, item)
	local op = node.op :: string
	if op == "!=" or op == "!~" then
		return not any_passes(
			field,
			have,
			if op == "!=" then "=" else "~",
			node.value :: string,
			node.prefix
		)
	elseif node.items then
		return within(field, (node.items :: { Node })[1], have)
	end
	for _, value in have do
		local ok
		if node.regex then
			ok = finds(value, node.regex :: string)
		elseif node.low or node.high then
			ok = in_range(field, value, node.low, node.high)
		else
			ok = passes(field, value, op, node.value :: string, node.prefix)
		end
		if ok then
			return true
		end
	end
	return false
end

local matches: (node: Node, item: any, source: Source) -> boolean

-- Whether `item` is in, or under, what `node` names or matches.
local function placed(node: Node, item: any, source: Source, deep: boolean): boolean
	local parent = source.parent
	if parent == nil then
		return false
	end
	local up = parent(item)
	while up ~= nil do
		local ok
		if node.items then
			ok = matches((node.items :: { Node })[1], up, source)
		else
			ok = source.named ~= nil and source.named(up, node.value :: string)
		end
		if ok or not deep then
			return ok
		end
		up = parent(up)
	end
	return false
end

function matches(node: Node, item: any, source: Source): boolean
	local kind = node.kind
	if kind == "and" then
		for _, inner in node.items :: { Node } do
			if not matches(inner, item, source) then
				return false
			end
		end
		return true
	elseif kind == "or" then
		for _, inner in node.items :: { Node } do
			if matches(inner, item, source) then
				return true
			end
		end
		return false
	elseif kind == "not" then
		return not matches((node.items :: { Node })[1], item, source)
	elseif kind == "word" then
		return has_word(
			string.lower(source.text(item)),
			string.lower(node.text :: string),
			node.prefix,
			source.words == "anywhere"
		)
	elseif kind == "regex" then
		return finds(source.text(item), node.text :: string)
	end
	local name = string.lower(node.field :: string)
	if name == "is" then
		return flagged(source, node, item)
	elseif name == "in" or name == "under" then
		return placed(node, item, source, name == "under")
	elseif name == "has" then
		-- A child matching the subquery, or one that is what's named
		-- (`has:attachment` is a child that is:attachment).
		local children: { any } = if source.children then source.children(item) else {}
		for _, child in children do
			local ok = if node.items
				then matches((node.items :: { Node })[1], child, source)
				else flagged(source, node, child)
			if ok then
				return true
			end
		end
		return false
	end
	local field = source.fields[name]
	return field ~= nil and field_matches(field, node, item)
end

--- Whether `item` matches `parsed` (everything matches an empty query).
function M.matches(parsed: Parsed, item: any, source: Source): boolean
	return parsed.query == nil or matches(parsed.query :: Node, item, source)
end

--- The items of `items` that match `parsed`, sorted and cut to its limit as
--- its view says. Check it first (`check`): a query with problems matches
--- what it can.
function M.run(parsed: Parsed, items: { any }, source: Source): { any }
	local out: { any } = {}
	for _, item in items do
		if M.matches(parsed, item, source) then
			table.insert(out, item)
		end
	end
	local keys = parsed.view.sort
	if #keys > 0 then
		table.sort(out, function(a: any, b: any): boolean
			for _, key in keys do
				local field = source.fields[string.lower(key.field)]
				if field then
					local x, y = values_of(field, a)[1] or "", values_of(field, b)[1] or ""
					local order = if field.kind == "date"
						then (if x < y then -1 elseif x > y then 1 else 0)
						else greed.compare.order(x, y)
					if order ~= 0 then
						return if key.descending then order > 0 else order < 0
					end
				end
			end
			return false
		end)
	end
	local limit = parsed.view.limit
	if limit and #out > limit then
		local cut: { any } = table.move(out, 1, limit, 1, {})
		return cut
	end
	return out
end

return M
