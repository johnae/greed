-- Lists of places across files: where the thing under the cursor is used,
-- and every problem servers found, open files or not. ctrl-e in either
-- list puts what it shows in a multibuffer, to read or edit all of it at
-- once.

local greed = require("@greed")
local picker = require("@picker")
local multibuffer = require("@multibuffer")
local common = require("./common")

type Place = { path: string, position: greed.LspPosition, ending: greed.LspPosition }

-- What a place adds to a multibuffer: a style for its range, a note.
type Shown = { style: string, note: string? }

-- Whether the server for files like `path` counts columns in bytes; the
-- default is UTF-16 code units. Asks a server of an open buffer in the same
-- language, since the file itself may not be open.
local function counts_bytes(path: string): boolean
	local language = greed.language_of(path)
	for _, buffer in greed.buffers() do
		if buffer:language() == language then
			local capabilities = greed.lsp.capabilities(buffer)
			if capabilities then
				return capabilities.positionEncoding == "utf-8"
			end
		end
	end
	return false
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
		texts[path] = texts[path] or common.file_text(path) or ""
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
		common.open_at(place.path, place.position)
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
						bytes[place.path] = counts_bytes(place.path)
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
						label = common.shown_path(place.path),
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

-- The places the thing under the cursor is used, as LSP locations, or nil
-- if the request failed (having said why).
local function references(ctx: greed.Context): { any }?
	local buffer = ctx.buffer
	local ok, result, err = common.request(buffer, "textDocument/references", function()
		local params = common.at(buffer, common.head(ctx.view))
		params.context = { includeDeclaration = true }
		return params
	end)
	if not ok then
		return nil
	elseif err then
		greed.echo(`references: {err.message}`)
		return nil
	end
	return result or {}
end

greed.command({
	name = "goto-references",
	doc = "Pick a place where the thing under the cursor is used, and go there",
	run = function(ctx)
		local found = references(ctx)
		if found == nil then
			return
		end
		local places: { Place } = {}
		for _, location in found do
			local path = greed.lsp.path(location.uri)
			if path then
				table.insert(
					places,
					{ path = path, position = location.range.start, ending = location.range["end"] }
				)
			end
		end
		if #places == 0 then
			greed.echo("no references found")
			return
		end
		table.sort(places, by_place)
		pick("References", places, function(place, line)
			local trimmed = string.match(line, "^%s*(.-)%s*$")
			return `{common.shown_path(place.path)}:{place.position.line + 1}: {trimmed}`
		end, function()
			return { style = "ui.search.match" }
		end, 1)
	end,
})

greed.command({
	name = "select-references",
	doc = "Select every place in this file where the thing under the cursor is used",
	run = function(ctx)
		local found = references(ctx)
		if found == nil then
			return
		end
		local buffer = ctx.buffer
		local ranges: { greed.Range } = {}
		for _, location in found do
			if greed.lsp.path(location.uri) == buffer:path() then
				table.insert(ranges, {
					anchor = greed.lsp.offset(buffer, location.range.start),
					head = greed.lsp.offset(buffer, location.range["end"]),
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

greed.command({
	name = "pick-workspace-symbol",
	doc = "Pick a function, type or other symbol anywhere in the project, as the language server knows them",
	run = function(ctx)
		local buffer = ctx.buffer
		picker.pick("Symbols", {}, function(item)
			common.open_at(item.value.path, item.value.position)
		end, {
			source = function(query)
				local ok, result = common.request(buffer, "workspace/symbol", function()
					return { query = query }
				end)
				local items = {}
				for _, symbol in if ok then result or {} else {} do
					local location = symbol.location
					local path = location and greed.lsp.path(location.uri)
					if path and location.range then
						table.insert(items, {
							label = `{symbol.name}  {common.shown_path(path)}:{location.range.start.line + 1}`,
							value = { path = path, position = location.range.start },
						})
					end
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
				local place =
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
			return `{common.shown_path(place.path)}:{place.position.line + 1}: {described(place)}`
		end, function(place)
			return {
				style = `diagnostic.{common.severity(about[place].severity)}`,
				note = described(place),
			}
		end, 0)
	end,
})

greed.keymap.bind("normal", {
	["g r"] = "goto-references",
	["space D"] = "pick-problem",
	-- Helix has this on space h, which is help here.
	["space H"] = "select-references",
	["space S"] = "pick-workspace-symbol",
})

return {}
