-- Lists of places across files: where the thing under the cursor is used,
-- and every problem servers found, open files or not. ctrl-e in either
-- list puts what it shows in a multibuffer, to read or edit all of it at
-- once.

local greed = require("@greed")
local picker = require("@picker")
local multibuffer = require("@multibuffer")
local common = require("./common")
local core = require("@core")

--- A place a server named, as it counts positions; `server` is the one
--- that named it, when it's known.
type Place = {
	path: string,
	position: greed.LspPosition,
	ending: greed.LspPosition,
	server: number?,
}

-- What a place adds to a multibuffer: a style for its range, a note.
type Shown = { style: string, note: string? }

-- Whether `server`, or else the server for files like `path`, counts
-- columns in bytes; the default is UTF-16 code units. Asks an open buffer
-- that has it, or one in the same language, since the file itself may not
-- be open.
local function counts_bytes(path: string, server: number?): boolean
	local language = greed.language_of(path)
	local fallback: boolean? = nil
	for _, buffer in greed.buffers() do
		for _, known in greed.lsp.servers_of(buffer) do
			local bytes = known.capabilities ~= nil
				and known.capabilities.positionEncoding == "utf-8"
			if known.id == server then
				return bytes
			elseif fallback == nil and buffer:language() == language then
				fallback = bytes
			end
		end
	end
	return fallback == true
end

-- The byte column in `line` of a server's column `character`.
local function byte_column(line: string, character: number, bytes: boolean): number
	if bytes then
		return math.min(character, #line)
	end
	local units = 0
	for at, code in utf8.codes(line) do
		if units >= character then
			return at - 1
		end
		units += if code > 0xFFFF then 2 else 1
	end
	return #line
end

-- Picks one of `places`, labelled by `label`, with a preview of its file,
-- and goes to it; ctrl-e puts the places shown in a multibuffer instead,
-- each styled and noted by `shown`, with `context` lines around it.
local function pick(
	title: string,
	places: { Place },
	label: (place: Place, line: string) -> string,
	shown: (place: Place) -> Shown,
	context: number
)
	local texts: { [string]: string } = {}
	local function text(path: string): string
		texts[path] = texts[path] or core.file.text(path) or ""
		return texts[path]
	end
	local function line_of(place: Place): string
		return string.split(text(place.path), "\n")[place.position.line + 1] or ""
	end
	local items = {}
	for _, place in places do
		table.insert(items, { label = label(place, line_of(place)), value = place })
	end
	picker.pick(title, items, function(item)
		local place: Place = item.value
		common.open_at(place.path, place.position, place.server)
	end, {
		preview = function(item)
			local place: Place = item.value
			return {
				text = text(place.path),
				language = greed.language_of(place.path),
				line = place.position.line,
			}
		end,
		keys = {
			["ctrl-e"] = function(picked)
				local bytes: { [string]: boolean } = {}
				local excerpts: { multibuffer.Excerpt } = {}
				for _, item in picked do
					local place: Place = item.value
					if bytes[place.path] == nil then
						bytes[place.path] = counts_bytes(place.path, place.server)
					end
					local line = line_of(place)
					local start, ending = place.position, place.ending
					local from = byte_column(line, start.character, bytes[place.path])
					local to = if ending.line == start.line
						then byte_column(line, ending.character, bytes[place.path])
						else #line
					local how = shown(place)
					table.insert(excerpts, {
						path = place.path,
						from = start.line,
						label = core.project.relative(place.path),
						note = how.note,
						marks = {
							{
								line = start.line,
								from = from,
								to = math.max(to, from + 1),
								style = how.style,
							},
						},
					})
				end
				local summary = `{#excerpts} {string.lower(title)}`
				multibuffer.show(
					multibuffer.open(excerpts, { summary = summary, context = context }),
					title
				)
			end,
		},
	})
end

local function by_place(a: Place, b: Place): boolean
	if a.path ~= b.path then
		return a.path < b.path
	end
	if a.position.line ~= b.position.line then
		return a.position.line < b.position.line
	end
	return a.position.character < b.position.character
end

-- The places the thing under the cursor is used, as LSP locations, and
-- the server that answered, or nil if the request failed (having said
-- why).
local function references(ctx: greed.Context): ({ any }?, number?)
	local buffer = ctx.buffer
	local ok, result, err, server = common.request(
		buffer,
		"textDocument/references",
		function(server)
			local params = common.at(buffer, ctx.view:cursor(), server)
			params.context = { includeDeclaration = true }
			return params
		end
	)
	if not ok then
		return nil, nil
	elseif err then
		greed.echo(`references: {err.message}`)
		return nil, nil
	end
	return result or {}, server
end

greed.command({
	name = "goto-references",
	doc = "Pick a place where the thing under the cursor is used, and go there",
	run = function(ctx)
		local found, server = references(ctx)
		if found == nil then
			return
		end
		local places: { Place } = {}
		for _, location in found do
			local path = greed.lsp.path(location.uri)
			if path then
				table.insert(places, {
					path = path,
					position = location.range.start,
					ending = location.range["end"],
					server = server,
				})
			end
		end
		if #places == 0 then
			greed.echo("no references found")
			return
		end
		table.sort(places, by_place)
		pick("References", places, function(place, line)
			local trimmed = string.match(line, "^%s*(.-)%s*$")
			return `{core.project.relative(place.path)}:{place.position.line + 1}: {trimmed}`
		end, function()
			return { style = "ui.search.match" }
		end, 1)
	end,
})

greed.command({
	name = "select-references",
	doc = "Select every place in this file where the thing under the cursor is used",
	run = function(ctx)
		local found, server = references(ctx)
		if found == nil then
			return
		end
		local buffer = ctx.buffer
		local ranges: { greed.Range } = {}
		for _, location in found do
			if greed.lsp.path(location.uri) == buffer:path() then
				table.insert(ranges, {
					anchor = greed.lsp.offset(buffer, location.range.start, server),
					head = greed.lsp.offset(buffer, location.range["end"], server),
				})
			end
		end
		if #ranges == 0 then
			greed.echo("no references in this file")
			return
		end
		table.sort(ranges, function(a: greed.Range, b: greed.Range)
			return a.anchor < b.anchor
		end)
		ctx.view:set_selection({ ranges = ranges, primary = 1 })
	end,
})

-- The kinds of symbol `pick-workspace-symbol` can keep to, each with the
-- kinds LSP has (`common.SYMBOL_KINDS`) that count as it.
local SYMBOL_GROUPS: { [string]: { string } } = {
	["function"] = { "function", "method", "constructor" },
	type = { "class", "struct", "enum", "interface" },
	module = { "module", "namespace", "package" },
	constant = { "constant", "enum member" },
	variable = { "variable", "field", "property" },
}

greed.command({
	name = "pick-workspace-symbol",
	doc = "Pick a function, type or other symbol anywhere in the project, as the language server knows them; with a kind, only those",
	args = {
		{
			name = "kind",
			type = "choice",
			choices = { "function", "type", "module", "constant", "variable" },
			optional = true,
			doc = "Only symbols of this kind, like function (methods too) or type",
		},
	},
	run = function(ctx)
		local buffer = ctx.buffer
		local kind: string? = ctx.values.kind
		-- With a kind, the kinds LSP has that count as it.
		local wanted: { [string]: boolean } = {}
		local group: { string } = if kind then SYMBOL_GROUPS[kind] else {}
		for _, name in group do
			wanted[name] = true
		end
		local title = if kind then `Symbols: {kind}` else "Symbols"
		picker.pick(title, {}, function(item)
			common.open_at(item.value.path, item.value.position, item.value.server)
		end, {
			source = function(query)
				local ok, result, _, server = common.request(buffer, "workspace/symbol", function()
					-- rust-analyzer searches only types unless asked for all
					-- (its own searchKind); other servers pass over it.
					local all = if kind and kind ~= "type" then "allSymbols" else nil
					return { query = query, searchKind = all }
				end)
				local found: { { name: string, kind: string, path: string, at: greed.LspPosition } } =
					{}
				local widest = 0
				for _, symbol in if ok then result or {} else {} do
					local location = symbol.location
					local path = location and greed.lsp.path(location.uri)
					local what = common.SYMBOL_KINDS[symbol.kind] or "symbol"
					if path and location.range and (kind == nil or wanted[what]) then
						table.insert(found, {
							name = symbol.name,
							kind = what,
							path = path,
							at = location.range.start,
						})
						widest = math.max(widest, #what)
					end
				end
				-- What each is, then where, lined up.
				local items = {}
				for _, f in found do
					local where = `{core.project.relative(f.path)}:{f.at.line + 1}`
					table.insert(items, {
						label = f.name,
						detail = `{f.kind}{string.rep(" ", widest - #f.kind + 2)}{where}`,
						value = { path = f.path, position = f.at, server = server },
					})
				end
				return items
			end,
		})
	end,
})

greed.command({
	name = "pick-problem",
	doc = "Pick a problem in any file, open or not, and go to it",
	run = function()
		local places: { Place } = {}
		local about: { [Place]: greed.LspProblem } = {}
		for _, problem in greed.lsp.problems() do
			local path = greed.lsp.path(problem.uri)
			if path then
				local place: Place =
					{ path = path, position = problem.range.start, ending = problem.range["end"] }
				about[place] = problem
				table.insert(places, place)
			end
		end
		if #places == 0 then
			greed.echo("no problems")
			return
		end
		-- Errors first, then by file and line.
		table.sort(places, function(a, b)
			local sa, sb = about[a].severity, about[b].severity
			if sa ~= sb then
				return sa < sb
			end
			return by_place(a, b)
		end)
		local function described(place: Place): string
			local first = string.split(about[place].message, "\n")[1]
			return common.describe({ severity = about[place].severity, message = first })
		end
		pick("Problems", places, function(place)
			return `{core.project.relative(place.path)}:{place.position.line + 1}: {described(place)}`
		end, function(place)
			return {
				style = `diagnostic.{common.severity(about[place].severity)}`,
				note = described(place),
			}
		end, 0)
	end,
})

greed.keymap.bind({ role = "command" }, { ["g r"] = "goto-references" })

greed.keymap.bind({ layer = "leader" }, {
	D = "pick-problem",
	-- Helix has this on space h, which is help here.
	H = "select-references",
	S = "pick-workspace-symbol",
})

return {}
