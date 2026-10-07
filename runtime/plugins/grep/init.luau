-- Search the whole project, and replace by editing what was found.
--
--   space /             search the project for a regex as you type
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
	local found, err = greed.fs.grep(core.search.smart_case(pattern), root)
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

greed.command({
	name = "search-project",
	doc = "Search the project for a regex as you type, and go to a match",
	run = function()
		local root = core.project.root()
		local pattern = ""
		local function lines(query: string): { picker.Item }
			pattern = query
			-- A half-typed pattern that doesn't parse yet finds nothing.
			local found: { greed.GrepLine } = greed.fs.grep(
				core.search.smart_case(query),
				root,
				{ limit = LIVE_LIMIT }
			) or {}
			local items = {}
			for _, f in found do
				local label = `{key(f.path, f.line)}: {string.match(f.text, "^%s*(.-)%s*$")}`
				table.insert(items, { label = label, value = f })
			end
			return items
		end
		picker.pick("Search", {}, function(item)
			local f = item.value :: greed.GrepLine
			core.file.open_at(core.project.resolve(f.path, root), f.line, f.matches[1].from)
		end, {
			source = lines,
			preview = function(item)
				local f = item.value :: greed.GrepLine
				local path = core.project.resolve(f.path, root)
				local text = greed.fs.read(path)
				if text == nil then
					return nil
				end
				return { text = text, language = greed.language_of(path), line = f.line }
			end,
			keys = {
				["ctrl-e"] = function(picked)
					local found = {}
					for _, item in picked do
						table.insert(found, item.value)
					end
					show(pattern, root, found)
				end,
			},
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

greed.keymap.bind("normal", { ["space /"] = "search-project" })

return {}
