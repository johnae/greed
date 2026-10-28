-- The manual, in the editor: the same Markdown pages the website is built
-- from, shipped with Greed, so they're the ones for the version you run.
--
--   space h d       go to a page or a heading in it, from a picker of them all
--   space h /       search the pages as you type
--   :docs [WORDS]   the heading with those words, or the picker
--
-- Pages open read-only, in the reading view: links go to other pages, and
-- esc shows the Markdown. A plugin's own `docs` folder joins them.

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")

local M = {}

--- A heading of a page: the page's title, the heading, how deep it is (1
--- for `#`), and the file and line (from 0) it's on.
export type Heading = { page: string, text: string, level: number, path: string, line: number }

--- Where the pages are: `docs` beside the plugins, in the runtime.
function M.folder(): string?
	local own = greed.plugin.dirs().docs
	if own == nil then
		return nil
	end
	return (string.gsub(own, "/plugins/docs/?$", "/docs"))
end

--- A page of the manual or of a plugin's docs: its title and file.
export type Page = { title: string, path: string }

-- A line a search found, in a page.
type Found = { path: string, line: number }

-- The pages in `folder`, in the order its contents (`SUMMARY.md`) lists
-- them, leaving out those that aren't there, like the reference pages the
-- website makes. Without contents, its Markdown files, README.md first,
-- each titled by its first heading.
local function pages_in(folder: string): { Page }
	local out: { Page } = {}
	local summary = greed.fs.read(`{folder}/SUMMARY.md`)
	if summary then
		for title, file in string.gmatch(summary, "%[([^%]]+)%]%(([^%)]+)%)") do
			local path = `{folder}/{file}`
			if greed.fs.read(path) then
				table.insert(out, { title = title, path = path })
			end
		end
		return out
	end
	local files: { string } = {}
	local entries = greed.fs.list(folder)
	if entries then
		for _, entry in entries do
			if not entry.dir and string.match(entry.name, "%.md$") then
				table.insert(files, entry.name)
			end
		end
	end
	table.sort(files, function(a: string, b: string): boolean
		if (a == "README.md") ~= (b == "README.md") then
			return a == "README.md"
		end
		return a < b
	end)
	for _, file in files do
		local path = `{folder}/{file}`
		local text = "\n" .. (greed.fs.read(path) or "")
		local title = string.match(text, "\n#%s+([^\n]-)%s*\n")
		table.insert(out, { title = title or (string.gsub(file, "%.md$", "")), path = path })
	end
	return out
end

--- The `docs` folder of each loaded plugin that has one, by plugin name.
function M.plugin_folders(): { [string]: string }
	local out: { [string]: string } = {}
	for name, dir in greed.plugin.dirs() do
		local info = greed.fs.stat(`{dir}/docs`)
		if info and info.kind == "dir" then
			out[name] = `{dir}/docs`
		end
	end
	return out
end

-- Where pages come from: the manual, then plugins' docs by plugin name,
-- with what a search lists their pages under.
local function folders(): { { dir: string, prefix: string } }
	local out: { { dir: string, prefix: string } } = {}
	local manual = M.folder()
	if manual then
		table.insert(out, { dir = manual, prefix = "" })
	end
	local own = M.plugin_folders()
	local names: { string } = {}
	for name in own do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		table.insert(out, { dir = own[name], prefix = `{name}/` })
	end
	return out
end

--- The manual's pages in the order its contents (`SUMMARY.md`) lists them,
--- then the pages in each plugin's own `docs` folder.
function M.pages(): { Page }
	local out: { Page } = {}
	for _, folder in folders() do
		for _, page in pages_in(folder.dir) do
			table.insert(out, page)
		end
	end
	return out
end

--- Every heading of every page, in order, outside code blocks.
function M.headings(): { Heading }
	local out: { Heading } = {}
	for _, page in M.pages() do
		local text = greed.fs.read(page.path) or ""
		local fence: string? = nil
		for n, line in string.split(text, "\n") do
			local ticks = string.match(line, "^%s*(```+)") or string.match(line, "^%s*(~~~+)")
			if ticks then
				if fence == nil then
					fence = ticks
				elseif string.sub(ticks, 1, #fence) == fence then
					fence = nil
				end
			elseif fence == nil then
				local hashes, heading = string.match(line, "^(#+)%s+(.-)%s*$")
				if hashes and heading then
					table.insert(out, {
						page = page.title,
						text = heading,
						level = #hashes,
						path = page.path,
						line = n - 1,
					})
				end
			end
		end
	end
	return out
end

-- How a heading is listed: its page's title, then the heading under it.
local function label(h: Heading): string
	return if h.level == 1 then h.page else `{h.page} › {h.text}`
end

--- Opens the page `path` at `line`, read-only, in the reading view.
function M.open(path: string, line: number?)
	core.file.open_at(path, line)
	local buffer = greed.view():buffer()
	buffer:set_readonly(true)
	if greed.mode.get() ~= "read" then
		greed.run("markdown-read")
	end
end

--- The heading best matching `words`: one whose page and heading have
--- them all, a page's own title first, then the shortest.
function M.find(words: string): Heading?
	local wanted: { string } = {}
	for word in string.gmatch(string.lower(words), "%S+") do
		table.insert(wanted, word)
	end
	local best: Heading? = nil
	local function score(h: Heading): number
		return (if h.level == 1 then 0 else 1000) + #label(h)
	end
	for _, h in M.headings() do
		local text = string.lower(label(h))
		local all = true
		for _, word in wanted do
			all = all and string.find(text, word, 1, true) ~= nil
		end
		if all and (best == nil or score(h) < score(best :: Heading)) then
			best = h
		end
	end
	return best
end

-- What a page shows beside the picker, at `line`.
local function preview(path: string, line: number): picker.Preview?
	local text = greed.fs.read(path)
	return if text then { text = text, language = "markdown", line = line } else nil
end

greed.command({
	name = "docs",
	doc = "Read the manual: go to the heading with these words, or pick one of them all",
	args = { { name = "words", doc = "Words of the page or heading, like watch or boards" } },
	run = function(ctx)
		if #ctx.args > 0 then
			local words = table.concat(ctx.args, " ")
			local found = M.find(words)
			if found == nil then
				greed.echo(`nothing in the manual is called {words}: space h / searches it`)
				return
			end
			M.open(found.path, found.line)
			return
		end
		local items: { picker.Item } = {}
		for _, h in M.headings() do
			table.insert(items, { label = label(h), value = h })
		end
		if #items == 0 then
			greed.echo("the manual isn't here")
			return
		end
		picker.pick("Manual", items, function(item)
			local h = item.value :: Heading
			M.open(h.path, h.line)
		end, {
			preview = function(item)
				local h = item.value :: Heading
				return preview(h.path, h.line)
			end,
		})
	end,
})

greed.command({
	name = "docs-search",
	doc = "Search the manual and plugins' docs as you type, and go to what's found",
	run = function()
		local roots = folders()
		if #roots == 0 then
			greed.echo("the manual isn't here")
			return
		end
		picker.pick("Search the manual", {}, function(item)
			local f = item.value :: Found
			M.open(f.path, f.line)
		end, {
			source = function(query: string): { picker.Item }
				local items: { picker.Item } = {}
				if query == "" then
					return items
				end
				local pattern = core.search.pattern(query)
				for _, root in roots do
					local found: { greed.GrepLine } = greed.fs.grep(
						pattern,
						root.dir,
						{ limit = 200 }
					) or {}
					for _, f in found do
						local page = root.prefix .. string.gsub(f.path, "%.md$", "")
						local text = string.match(f.text, "^%s*(.-)%s*$") or f.text
						local value: Found =
							{ path = core.project.resolve(f.path, root.dir), line = f.line }
						table.insert(items, { label = `{page}: {text}`, value = value })
					end
				end
				return items
			end,
			preview = function(item)
				local f = item.value :: Found
				return preview(f.path, f.line)
			end,
		})
	end,
})

-- A page however it's opened, a link followed too, is read-only: it's the
-- manual as Greed ships it.
greed.on("buffer.opened", function(event: greed.BufferChanged)
	local folder = M.folder()
	local path = event.buffer:path()
	if folder and path and string.sub(path, 1, #folder + 1) == folder .. "/" then
		event.buffer:set_readonly(true)
	end
end)

greed.keymap.bind({ layer = "leader" }, { ["h d"] = "docs", ["h /"] = "docs-search" })

return M
