-- The pickers Greed ships with: files in the project, open buffers,
-- commands, the outline of a file, and your notes, mail and chat searched
-- at once (core.everywhere).

local greed = require("@greed")
local picker = require("./picker")
local core = require("@core")
local project = core.project

-- At most this much of a file is read for its preview.
local PREVIEW_BYTES = 64 * 1024

-- A file's start, highlighted in its language.
local function file_preview(item: picker.Item): picker.Preview?
	local text = greed.fs.read(item.value, PREVIEW_BYTES)
	if text == nil then
		return nil
	end
	if string.find(text, "\0", 1, true) then
		return { text = "(binary file)" }
	end
	return { text = text, language = greed.language_of(item.value) }
end

-- An open buffer's text as it is now, saved or not.
local function buffer_preview(item: picker.Item): picker.Preview?
	local buffer = greed.buffer_for(item.value)
	return if buffer then { text = buffer:text(), language = buffer:language() } else nil
end

-- Picks a file under `root`, skipping ignored files, and opens it.
local function pick_file(title: string, root: string)
	local items = {}
	for _, path in greed.files(root) do
		table.insert(items, { label = path, value = project.resolve(path, root), kind = "file" })
	end
	picker.pick(title, items, function(item)
		core.file.open(item.value)
	end, { preview = file_preview })
end

greed.command({
	name = "pick-file",
	doc = "Open a file in the project, skipping ignored files",
	run = function()
		pick_file("Files", project.root())
	end,
})

greed.command({
	name = "pick-file-here",
	doc = "Open a file under the folder Greed was started in, skipping ignored files",
	run = function()
		pick_file("Files here", greed.fs.cwd())
	end,
})

greed.command({
	name = "picker-resume",
	doc = "Open the last picker again",
	run = function()
		if not picker.resume() then
			greed.echo("no picker yet")
		end
	end,
})

greed.command({
	name = "pick-buffer",
	doc = "Switch to an open file",
	run = function()
		-- The files you were in last come first, named as the file picker
		-- names them, with [+] on those with unsaved changes.
		local items: { picker.Item } = {}
		local listed: { [number]: boolean } = {}
		local buffers = core.recent.buffers()
		for _, buffer in greed.buffers() do
			table.insert(buffers, buffer)
		end
		for _, buffer in buffers do
			local path = buffer:path()
			if path and not listed[buffer:id()] then
				listed[buffer:id()] = true
				local label = project.short(path)
				if core.file.unsaved(buffer) then
					label ..= " [+]"
				end
				table.insert(items, { label = label, value = path, kind = "file" })
			end
		end
		picker.pick("Buffers", items, function(item)
			core.file.open(item.value)
		end, { preview = buffer_preview })
	end,
})

greed.command({
	name = "command-palette",
	doc = "Run any command by name",
	run = function()
		-- Keys that run each command where the palette opened from, the
		-- leader's too.
		local keys_of: { [string]: { string } } = {}
		for _, binding in greed.keymap.active() do
			local list = keys_of[binding.command] or {}
			table.insert(list, binding.keys)
			keys_of[binding.command] = list
		end
		local items = {}
		-- Commands that won't run without an argument, typed so they say, and
		-- whether there's a command line to give it on.
		local has_command_line = false
		local needs_args: { [string]: boolean } = {}
		for _, command in greed.commands() do
			has_command_line = has_command_line or command.name == "command-line"
			for _, arg in command.args do
				if arg.type and not arg.optional then
					needs_args[command.name] = true
				end
			end
			local keys = keys_of[command.name] or {}
			local detail = command.doc
			if #keys > 0 then
				detail = `({table.concat(keys, ", ")})  {detail}`
			end
			table.insert(
				items,
				{ label = command.name, detail = detail, value = command.name, kind = "command" }
			)
		end
		picker.pick("Commands", items, function(item)
			-- One that needs an argument goes to the command line, its name
			-- typed, to give it there.
			if needs_args[item.value] and has_command_line then
				greed.run("command-line", { args = { `{item.value} ` } })
			else
				greed.run(item.value)
			end
		end)
	end,
})

greed.command({
	name = "pick-outline",
	doc = "Jump to a function or type in the file, from its syntax tree",
	run = function(ctx)
		local buffer, view = ctx.buffer, ctx.view
		local syntax = require("@core").syntax
		local found: { { node: greed.Node, name: greed.Node, object: string } } = {}
		for _, object in { "function", "type" } do
			for _, o in syntax.objects(buffer, object) do
				local name = o.around:child("name")
				if name then
					table.insert(found, { node = o.around, name = name, object = object })
				end
			end
		end
		table.sort(found, function(a: { name: greed.Node }, b: { name: greed.Node })
			return a.name.from < b.name.from
		end)
		-- What each is, then its line, the numbers lined up on the right.
		local digits = #tostring(buffer:line_count())
		local items = {}
		for _, f in found do
			-- Nested items are indented under what holds them.
			local depth = 0
			for _, other in found do
				if other.node.from < f.node.from and f.node.to <= other.node.to then
					depth += 1
				end
			end
			local line = buffer:line_of(f.name.from)
			table.insert(items, {
				label = `{string.rep("  ", depth)}{f.name:text()}`,
				detail = string.format(`%-8s  line %{digits}d`, f.object, line + 1),
				value = f.name.from,
			})
		end
		local text, language = buffer:text(), buffer:language()
		picker.pick("Outline", items, function(item)
			view:set_selection({
				ranges = { { anchor = item.value, head = item.value } },
				primary = 1,
			})
		end, {
			preview = function(item)
				return { text = text, language = language, line = buffer:line_of(item.value) }
			end,
		})
	end,
})

greed.command({
	name = "watches",
	doc = "List what's watched for changes; enter stops watching one",
	run = function()
		local items = {}
		for _, object in core.watch.list() do
			table.insert(items, { label = object.kind, detail = object.label, value = object })
		end
		if #items == 0 then
			greed.echo("nothing is watched: watch, on space ., starts")
			return
		end
		picker.pick("Watched (enter stops one)", items, function(item)
			core.watch.toggle(item.value)
		end)
	end,
})

greed.command({
	name = "pick-jump",
	doc = "Pick a place from the jumplist and go there",
	run = function()
		local jumps = require("@core").jumps
		local root = project.root()
		local items: { picker.Item } = {}
		for _, place in jumps.list() do
			local buffer: greed.Buffer? = nil
			for _, open in greed.buffers() do
				if open:id() == place.buffer then
					buffer = open
				end
			end
			local path = place.path
			local name = if path == nil then "[scratch]" else project.relative(path, root)
			local where, line = "?", ""
			if buffer then
				local row = buffer:line_of(math.min(place.pos, buffer:len()))
				where = tostring(row + 1)
				line = string.gsub(buffer:line_text(row), "^%s+", "")
			end
			table.insert(items, { label = `{name}:{where}`, detail = line, value = place })
		end
		if #items == 0 then
			greed.echo("the jumplist is empty")
			return
		end
		picker.pick("Jumplist", items, function(item)
			jumps.go(item.value)
		end)
	end,
})

greed.command({
	name = "pick-style",
	doc = "Pick an editing style",
	run = function()
		local using = core.style.current().name
		-- The style in use comes first, so enter right away changes nothing.
		local items: { picker.Item } = {}
		for _, style in core.style.list() do
			local item: picker.Item = { label = style.name, detail = style.doc, value = style.name }
			table.insert(items, if style.name == using then 1 else #items + 1, item)
		end
		picker.pick("Editing style", items, function(item)
			core.style.set(item.value)
			greed.echo(`editing style: {item.value}`)
		end)
	end,
})

-- How something found everywhere reads: where, what, and when.
local function found_label(hit: core.EverywhereHit): string
	local when = if hit.at then `  · {os.date("%Y-%m-%d", hit.at // 1000)}` else ""
	return `{hit.source}  {hit.label}{when}`
end

greed.command({
	name = "search-everywhere",
	doc = "Search your notes, mail and chat at once, as you type; in:mail, in:chat or in:notes picks some",
	run = function()
		picker.pick("Search everywhere", {}, function(item)
			item.value.open()
		end, {
			delay = 250,
			source = function(query: string): { picker.Item }
				if core.text.trim(query) == "" then
					return {}
				end
				local hits, troubles = core.everywhere.search(query)
				if #troubles > 0 then
					greed.echo(table.concat(troubles, "; "))
				end
				local items = {}
				for _, hit in hits do
					table.insert(items, { label = found_label(hit), value = hit })
				end
				return items
			end,
			preview = function(item: picker.Item): picker.Preview?
				local hit: core.EverywhereHit = item.value
				return { text = hit.snippet or hit.label }
			end,
		})
	end,
})

greed.keymap.bind({ layer = "leader" }, { ["n s"] = "search-everywhere" })

return {}
