-- Search the whole project, and replace by editing what was found.
--
--   space /             search the project for a regex as you type
--   space L             the same in this buffer, unsaved changes included
--   ctrl-e              in that picker: put the matches in a results panel
--   :grep PATTERN DIR?  put the matches in a results panel straight away
--
-- The results panel is a multibuffer: each matching line under its file's
-- name. Edit the lines with anything (s to select the matches and c to
-- change them all works well) and the files change as you type; :w saves
-- them, enter opens the match under the cursor, and q closes the panel.
--
-- Patterns are regexes; ones in lowercase ignore case. The project is the
-- folder holding .jj or .git (see core's project.luau).

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")
local multibuffer = require("@multibuffer")

type Found = { greed.GrepLine }

local function key(path: string, line: number): string
	return `{path}:{line + 1}`
end

local function grep(pattern: string, root: string): Found
	local found, err = greed.fs.grep(core.search.pattern(pattern), root)
	if found == nil then
		error(err, 0)
	end
	return found
end

-- Shows `found` in the results panel, each line under its file.
local function show(pattern: string, root: string, found: Found)
	if #found == 0 then
		greed.echo(`nothing matches {pattern}`)
		return
	end
	local excerpts: { multibuffer.Excerpt } = {}
	for _, f in found do
		local marks: { multibuffer.Mark } = {}
		for _, m in f.matches do
			table.insert(
				marks,
				{ line = f.line, from = m.from, to = m.to, style = "ui.search.match" }
			)
		end
		table.insert(excerpts, {
			path = core.project.resolve(f.path, root),
			from = f.line,
			label = f.path,
			marks = marks,
		})
	end
	local summary = if #found == 1
		then `1 line matches {pattern}`
		else `{#found} lines match {pattern}`
	multibuffer.show(multibuffer.open(excerpts, { summary = summary }), "Search")
	greed.echo(`{summary} - edits change the files, :w saves them`)
end

-- At most this many lines are listed while searching as you type; :grep
-- lists everything.
local LIVE_LIMIT = 1000

-- Where searching as you type looks: `find` gives the lines matching a
-- query, `go` goes to one and `preview` shows it. With `root`, which the
-- paths found are relative to, ctrl-e puts them in the results panel.
type Place = {
	title: string,
	find: (query: string) -> Found,
	go: (found: greed.GrepLine) -> (),
	preview: (found: greed.GrepLine) -> picker.Preview?,
	root: string?,
}

-- Searches `place` for a regex as you type, listing the matching lines.
local function search_as_you_type(place: Place)
	local pattern = ""
	local function lines(query: string): { picker.Item }
		pattern = query
		local items = {}
		for _, f in place.find(query) do
			local label = `{key(f.path, f.line)}: {string.match(f.text, "^%s*(.-)%s*$")}`
			table.insert(items, { label = label, value = f })
		end
		return items
	end
	local keys = {}
	local root = place.root
	if root then
		keys["ctrl-e"] = function(picked: { picker.Item })
			local found = {}
			for _, item in picked do
				table.insert(found, item.value)
			end
			show(pattern, root, found)
		end
	end
	picker.pick(place.title, {}, function(item)
		place.go(item.value :: greed.GrepLine)
	end, {
		source = lines,
		preview = function(item)
			return place.preview(item.value :: greed.GrepLine)
		end,
		keys = keys,
	})
end

-- The first `limit` lines of `buffer` matching `query`, as they are now,
-- unsaved changes included, found under `path`.
local function buffer_lines(buffer: greed.Buffer, query: string, path: string, limit: number): Found
	local found: Found = {}
	-- A half-typed pattern that doesn't parse yet finds nothing.
	local matches = buffer:find_all(core.search.pattern(query))
	if matches == nil then
		return found
	end
	for _, m in matches do
		local line = buffer:line_of(m.from)
		local last = found[#found]
		if last == nil or last.line ~= line then
			if #found == limit then
				break
			end
			last = { path = path, line = line, text = buffer:line_text(line), matches = {} }
			table.insert(found, last)
		end
		local start = buffer:line_start(line)
		table.insert(last.matches, { from = m.from - start, to = m.to - start })
	end
	return found
end

greed.command({
	name = "search-project",
	doc = "Search the project for a regex as you type, and go to a match",
	run = function()
		local root = core.project.root()
		search_as_you_type({
			title = "Search",
			root = root,
			find = function(query)
				-- A half-typed pattern that doesn't parse yet finds nothing.
				return greed.fs.grep(core.search.pattern(query), root, { limit = LIVE_LIMIT }) or {}
			end,
			go = function(f)
				core.file.open_at(core.project.resolve(f.path, root), f.line, f.matches[1].from)
			end,
			preview = function(f)
				local path = core.project.resolve(f.path, root)
				local text = greed.fs.read(path)
				if text == nil then
					return nil
				end
				return { text = text, language = greed.language_of(path), line = f.line }
			end,
		})
	end,
})

greed.command({
	name = "search-buffer",
	doc = "Search this buffer for a regex as you type, listing the lines that match",
	run = function(ctx)
		local buffer, view = ctx.buffer, ctx.view
		local file = buffer:path()
		local root = if file then core.project.root() else nil
		local path = if file then core.project.relative(file) else core.project.name(buffer)
		search_as_you_type({
			title = `Search {path}`,
			root = root,
			find = function(query)
				return buffer_lines(buffer, query, path, LIVE_LIMIT)
			end,
			go = function(f)
				local at = buffer:line_start(f.line) + f.matches[1].from
				view:set_selection({ ranges = { { anchor = at, head = at } }, primary = 1 })
			end,
			preview = function(f)
				return { text = buffer:text(), language = buffer:language(), line = f.line }
			end,
		})
	end,
})

greed.command({
	name = "grep",
	doc = "Put the lines matching a regex in a panel, to go to them or edit them",
	args = {
		{ name = "pattern", doc = "A regex; lowercase ignores case" },
		{ name = "dir", doc = "Where to search; the project by default", complete = "file" },
	},
	run = function(ctx)
		local pattern = ctx.args[1]
		if pattern == nil then
			error("grep needs a pattern, e.g. :grep todo", 0)
		end
		local root = ctx.args[2] or core.project.root()
		show(pattern, root, grep(pattern, root))
	end,
})

greed.command({
	name = "grep-close",
	doc = "Close the search results",
	run = multibuffer.close,
})

core.actions.action({
	kind = "folder",
	name = "grep here",
	doc = "Put the lines in it matching a regex in a panel",
	run = function(target)
		local pattern = core.prompt.ask(`grep in {core.project.short(target.value)}`)
		if pattern and pattern ~= "" then
			show(pattern, target.value, grep(pattern, target.value))
		end
	end,
})

greed.keymap.bind({ layer = "leader" }, { ["/"] = "search-project", L = "search-buffer" })

return {}
