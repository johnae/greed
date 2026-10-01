-- Search the whole project, and replace by editing what was found.
--
--   space /             search the project for a regex as you type
--   ctrl-e              in that picker: put the matches in a results panel
--   :grep PATTERN DIR?  put the matches in a results panel straight away
--
-- The results panel has one line per match, `path:line: text`. Edit the
-- text with anything: s to select the matches and c to change them all
-- works well. :w writes the changed lines back to their files, enter opens
-- the match under the cursor, and q closes the panel.
--
-- Patterns are regexes; ones in lowercase ignore case. The project is the
-- folder holding .jj or .git (see core's project.luau).

local kern = require("@kern")
local core = require("@core")
local picker = require("@picker")

type Found = { kern.GrepLine }

type Results = {
	root: string,
	-- Each line's text when it was found, or last written, by "path:line".
	original: { [string]: string },
	-- Where each line's first match starts, by "path:line".
	column: { [string]: number },
}

-- The results shown in panels, by buffer id.
local results: { [number]: Results } = {}

-- The results panel, while it's open.
local panel: kern.View? = nil

local function key(path: string, line: number): string
	return `{path}:{line + 1}`
end

local function grep(pattern: string, root: string): Found
	local found, err = kern.fs.grep(core.search.smart_case(pattern), root)
	if found == nil then
		error(err, 0)
	end
	return found
end

-- Opens `path` (relative to `root`) in the main view with the cursor at
-- `column` on 0-based `line`.
local function go_to(root: string, path: string, line: number, column: number)
	kern.open(core.project.path(root, path))
	local view = kern.view()
	local buffer = view:buffer()
	local start = buffer:line_start(math.clamp(line, 0, buffer:line_count() - 1))
	local at = math.min(start + column, buffer:line_end(buffer:line_of(start)))
	view:set_selection({ ranges = { { anchor = at, head = at } }, primary = 1 })
end

-- Shows `found` in the results panel, one line per match.
local function show(pattern: string, root: string, found: Found)
	if #found == 0 then
		kern.echo(`nothing matches {pattern}`)
		return
	end
	local lines, marks = {}, {}
	local r: Results = { root = root, original = {}, column = {} }
	local pos = 0
	for _, f in found do
		local location = key(f.path, f.line)
		local prefix = location .. ": "
		r.original[location] = f.text
		r.column[location] = f.matches[1].from
		table.insert(marks, { from = pos, to = pos + #prefix - 2, style = "ui.grep.location" })
		for _, m in f.matches do
			table.insert(marks, {
				from = pos + #prefix + m.from,
				to = pos + #prefix + m.to,
				style = "ui.search.match",
			})
		end
		table.insert(lines, prefix .. f.text)
		pos += #prefix + #f.text + 1
	end
	local buffer = kern.create_buffer("grep", table.concat(lines, "\n"))
	buffer:decorate("grep", marks)
	results[buffer:id()] = r
	local current = panel
	local ok, old = pcall(function()
		return (current :: kern.View):buffer()
	end)
	if current and ok then
		results[old:id()] = nil
		current:show(buffer)
		current:focus()
	else
		panel = kern.panel(buffer, { side = "right", width = "45%", title = "Search" })
	end
	kern.echo(`{#found} lines match {pattern} - :w writes your edits back`)
end

-- `text` with the lines in `changes` (by 0-based line) replaced where they
-- still read as they did. Returns the new text and how many lines changed
-- and were skipped.
local function replace_lines(
	text: string,
	changes: { [number]: { old: string, new: string } }
): (string, number, number)
	local out, changed, skipped = {}, 0, 0
	local pos, line = 1, 0
	while true do
		local newline = string.find(text, "\n", pos, true)
		local content = string.sub(text, pos, (newline or #text + 1) - 1)
		local cr = if string.sub(content, -1) == "\r" then "\r" else ""
		content = string.sub(content, 1, #content - #cr)
		local change = changes[line]
		if change and content == change.old then
			content = change.new
			changed += 1
		elseif change then
			skipped += 1
		end
		table.insert(out, content .. cr .. (if newline then "\n" else ""))
		if newline == nil then
			break
		end
		pos, line = newline + 1, line + 1
	end
	return table.concat(out), changed, skipped
end

-- Edits the lines in `changes` in an open buffer, where they still read as
-- they did. Returns how many changed and were skipped.
local function replace_in_buffer(
	buffer: kern.Buffer,
	changes: { [number]: { old: string, new: string } }
): (number, number)
	local changed, skipped = 0, 0
	buffer:edit(function(e)
		for line, change in changes do
			local start = if line < buffer:line_count() then buffer:line_start(line) else nil
			if start and buffer:slice(start, buffer:line_end(line)) == change.old then
				e:replace(start, buffer:line_end(line), change.new)
				changed += 1
			else
				skipped += 1
			end
		end
	end)
	return changed, skipped
end

-- Writes the lines edited in a results buffer back to their files. Files
-- open in Kern are edited there, and saved unless they had other unsaved
-- changes.
local function write_back(buffer: kern.Buffer)
	local r = results[buffer:id()]
	if r == nil then
		return
	end
	local by_path: { [string]: { [number]: { old: string, new: string } } } = {}
	for i = 0, buffer:line_count() - 1 do
		local text = buffer:slice(buffer:line_start(i), buffer:line_end(i))
		local path, number, new = string.match(text, "^(.-):(%d+): (.*)$")
		local old = path and r.original[`{path}:{number}`]
		if path and number and new and old and old ~= new then
			by_path[path] = by_path[path] or {}
			by_path[path][(tonumber(number) :: number) - 1] = { old = old, new = new }
		end
	end
	local open: { [string]: kern.Buffer } = {}
	for _, b in kern.buffers() do
		local path = b:path()
		if path then
			open[path] = b
		end
	end
	local files, lines, skipped = 0, 0, 0
	for path, changes in by_path do
		local full = core.project.path(r.root, path)
		local changed, missed
		local target = open[full]
		if target then
			local unsaved = target:modified()
			changed, missed = replace_in_buffer(target, changes)
			if changed > 0 and not unsaved then
				target:save()
			end
		else
			local text, err = kern.fs.read(full)
			if text == nil then
				error(err, 0)
			end
			local new_text
			new_text, changed, missed = replace_lines(text, changes)
			if changed > 0 then
				local ok, write_err = kern.fs.write(full, new_text)
				if not ok then
					error(write_err, 0)
				end
			end
		end
		for line, change in changes do
			r.original[key(path, line)] = change.new
		end
		files += if changed > 0 then 1 else 0
		lines += changed
		skipped += missed
	end
	local message = `changed {lines} lines in {files} files`
	if skipped > 0 then
		message ..= `; skipped {skipped} that changed since the search`
	end
	kern.echo(message)
end

core.file.on_save("grep", write_back)

-- At most this many lines are listed while searching as you type; :grep
-- lists everything.
local LIVE_LIMIT = 1000

kern.command({
	name = "search-project",
	doc = "Search the project for a regex as you type, and go to a match",
	run = function()
		local root = core.project.root()
		local pattern = ""
		local function lines(query: string): { picker.Item }
			pattern = query
			-- A half-typed pattern that doesn't parse yet finds nothing.
			local found = kern.fs.grep(core.search.smart_case(query), root, { limit = LIVE_LIMIT })
				or {}
			local items = {}
			for _, f in found do
				local label = `{key(f.path, f.line)}: {string.match(f.text, "^%s*(.-)%s*$")}`
				table.insert(items, { label = label, value = f })
			end
			return items
		end
		picker.pick("Search", {}, function(item)
			local f = item.value :: kern.GrepLine
			go_to(root, f.path, f.line, f.matches[1].from)
		end, {
			source = lines,
			preview = function(item)
				local f = item.value :: kern.GrepLine
				local path = core.project.path(root, f.path)
				local text = kern.fs.read(path)
				if text == nil then
					return nil
				end
				return { text = text, language = kern.language_of(path), line = f.line }
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

kern.command({
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

kern.command({
	name = "grep-open",
	doc = "Open the match on the cursor's line",
	run = function(ctx)
		local r = results[ctx.buffer:id()]
		if r == nil then
			return
		end
		local selection = ctx.view:selection()
		local line = ctx.buffer:line_of(selection.ranges[selection.primary].head)
		local text = ctx.buffer:slice(ctx.buffer:line_start(line), ctx.buffer:line_end(line))
		local path, number = string.match(text, "^(.-):(%d+): ")
		if path and number then
			go_to(r.root, path, (tonumber(number) :: number) - 1, r.column[`{path}:{number}`] or 0)
		end
	end,
})

kern.command({
	name = "grep-close",
	doc = "Close the search results",
	run = function()
		local view = panel
		panel = nil
		if view then
			pcall(function()
				results[view:buffer():id()] = nil
				view:close()
			end)
		end
	end,
})

kern.keymap.bind({ mode = "normal", kind = "grep" }, { enter = "grep-open", q = "grep-close" })
kern.keymap.bind("normal", { ["space /"] = "search-project" })

return {}
