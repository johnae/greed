-- Lists of places across files: where the thing under the cursor is used,
-- and every problem servers found, open files or not.

local kern = require("@kern")
local picker = require("@picker")
local common = require("./common")

type Place = { path: string, position: kern.LspPosition }

-- Picks one of `places`, labelled by `label`, with a preview of its file,
-- and goes to it.
local function pick(title: string, places: { Place }, label: (place: Place, line: string) -> string)
	local texts: { [string]: string } = {}
	local function text(path: string): string
		texts[path] = texts[path] or common.file_text(path) or ""
		return texts[path]
	end
	local items = {}
	for _, place in places do
		local line = string.split(text(place.path), "\n")[place.position.line + 1] or ""
		table.insert(items, { label = label(place, line), value = place })
	end
	picker.pick(title, items, function(item)
		local place: Place = item.value
		common.open_at(place.path, place.position)
	end, {
		preview = function(item)
			local place: Place = item.value
			return {
				text = text(place.path),
				language = kern.language_of(place.path),
				line = place.position.line,
			}
		end,
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

kern.command({
	name = "goto-references",
	doc = "Pick a place where the thing under the cursor is used, and go there",
	run = function(ctx)
		local buffer = ctx.buffer
		local ok, result, err = common.request(buffer, "textDocument/references", function()
			local params = common.at(buffer, common.head(ctx.view))
			params.context = { includeDeclaration = true }
			return params
		end)
		if not ok then
			return
		elseif err then
			kern.echo(`references: {err.message}`)
			return
		end
		local places: { Place } = {}
		for _, location in result or {} do
			local path = kern.lsp.path(location.uri)
			if path then
				table.insert(places, { path = path, position = location.range.start })
			end
		end
		if #places == 0 then
			kern.echo("no references found")
			return
		end
		table.sort(places, by_place)
		pick("References", places, function(place, line)
			local trimmed = string.match(line, "^%s*(.-)%s*$")
			return `{common.shown_path(place.path)}:{place.position.line + 1}: {trimmed}`
		end)
	end,
})

kern.command({
	name = "pick-problem",
	doc = "Pick a problem in any file, open or not, and go to it",
	run = function()
		local places: { Place } = {}
		local about: { [Place]: kern.LspProblem } = {}
		for _, problem in kern.lsp.problems() do
			local path = kern.lsp.path(problem.uri)
			if path then
				local place = { path = path, position = problem.range.start }
				about[place] = problem
				table.insert(places, place)
			end
		end
		if #places == 0 then
			kern.echo("no problems")
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
		pick("Problems", places, function(place)
			local first = string.split(about[place].message, "\n")[1]
			local problem = { severity = about[place].severity, message = first }
			local where = `{common.shown_path(place.path)}:{place.position.line + 1}`
			return `{where}: {common.describe(problem)}`
		end)
	end,
})

kern.keymap.bind("normal", {
	["g r"] = "goto-references",
	["space D"] = "pick-problem",
})

return {}
