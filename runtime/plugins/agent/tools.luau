-- The tools Greed offers agents out of the box. Each is also `greed ctl NAME`.

local greed = require("@greed")
local core = require("@core")
local agent = require("./registry")
local proposals = require("./proposals")
local describe = require("@describe")
local context = require("./context")
local untrusted = require("./untrusted").wrap

local object = agent.schema.object

-- 1-based line and column, as people and agents count them.
local function position(buffer: greed.Buffer, pos: number): { line: number, column: number }
	local line = buffer:line_of(pos)
	return { line = line + 1, column = pos - buffer:line_start(line) + 1 }
end

local SEVERITY = { "error", "warning", "info", "hint" }

agent.tool({
	name = "focus",
	description = "What the user is looking at: the view and buffer ids (for inspect, act or "
		.. "run_command's view), the current file, the mode as greed.mode.get() gives it "
		.. '(like "helix-insert") and as the status line shows it (label, "insert"), their '
		.. "selections with the selected text, and the lines on screen",
	run = function()
		return context.focus(context.view() or greed.view())
	end,
})

agent.tool({
	name = "buffers",
	description = "The files open in the editor, and which have unsaved changes",
	run = function()
		local list = {}
		for _, buffer in greed.buffers() do
			local path = buffer:path()
			if path then
				table.insert(
					list,
					{ path = path, modified = buffer:modified(), language = buffer:language() }
				)
			end
		end
		return greed.json.array(list)
	end,
})

-- The text of what `id` names when it's an object's id rather than a path:
-- a buffer's (unsaved changes too), a view's buffer's, a file's, and the
-- buffer when it's one. Nil when it isn't an id; an error for an object
-- that has no text.
local function object_text(id: string): (string?, greed.Buffer?)
	local kind = string.match(id, "^([%w%-]+):")
	local known = false
	for _, each in core.objects.kinds() do
		known = known or each.name == kind
	end
	if not known then
		return nil, nil
	end
	local found = core.objects.get(id) or error(`there's no object {id} now; objects lists them`, 0)
	if found.kind == "buffer" or found.kind == "view" then
		local buffer: greed.Buffer = if found.kind == "view"
			then found.value:buffer()
			else found.value
		return buffer:text(), buffer
	elseif found.kind == "file" then
		local text, err = core.file.text(found.value)
		return text or error(err, 0), nil
	end
	error(`{id} is an object's id, not a file: use inspect for its state`, 0)
end

agent.tool({
	name = "read",
	description = "A file's text as the editor has it, including unsaved changes, or a "
		.. "buffer's or view's by its id (buffer:12, view:3). Lines are 1-based and both ends "
		.. "are included",
	input = object({
		path = {
			type = "string",
			description = "The file, or a buffer's or view's id; the current file if left out",
		},
		from_line = { type = "integer" },
		to_line = { type = "integer" },
	}),
	run = function(args)
		local path: string? = args.path
		local text: string
		local of_object, buffer = nil, nil
		if path then
			of_object, buffer = object_text(path)
		end
		if of_object then
			text = of_object
		elseif path then
			local read, err = core.file.text(path)
			if read == nil then
				error(err, 0)
			end
			text = read
		else
			local current = greed.view():buffer()
			buffer = current
			text = current:text()
		end
		if args.from_line ~= nil or args.to_line ~= nil then
			local lines = string.split(text, "\n")
			local from = math.max(args.from_line or 1, 1)
			local to = math.min(args.to_line or #lines, #lines)
			text = table.concat(lines, "\n", from, to)
		end
		local outside = buffer and core.outside.source(buffer)
		return if outside then untrusted(outside, text) else text
	end,
})

agent.tool({
	name = "diagnostics",
	description = "Errors and warnings from language servers, for one open file or all of them",
	input = object({
		path = { type = "string", description = "The file; every open file if left out" },
	}),
	run = function(args)
		local list = {}
		local wanted: greed.Buffer? = if args.path
			then core.file.buffer(args.path :: string)
			else nil
		for _, buffer in greed.buffers() do
			local path = buffer:path()
			if path and (args.path == nil or wanted == buffer) then
				for _, d in greed.lsp.diagnostics(buffer) do
					local at = position(buffer, d.from)
					table.insert(list, {
						path = path,
						line = at.line,
						column = at.column,
						severity = SEVERITY[d.severity] or "hint",
						message = d.message,
						source = d.source,
					})
				end
			end
		end
		return greed.json.array(list)
	end,
})

-- Adds each line of `text` to `out`, after `prefix`.
local function add_lines(out: { string }, prefix: string, text: string)
	local lines = string.split(text, "\n")
	if lines[#lines] == "" then
		table.remove(lines)
	end
	for _, line in lines do
		table.insert(out, prefix .. line)
	end
end

-- The changed lines between `old` and `new`, "-" for removed and "+" for
-- added, each run under "@@ line N" (1-based, in `new`).
local function diff_lines(old: string, new: string): string
	local out = {}
	local shift = 0
	for _, hunk in greed.diff(old, new) do
		local removed = string.sub(old, hunk.from + 1, hunk.to)
		local _, breaks = string.gsub(string.sub(new, 1, hunk.from + shift), "\n", "")
		shift += #hunk.text - #removed
		table.insert(out, `@@ line {breaks + 1}`)
		add_lines(out, "-", removed)
		add_lines(out, "+", hunk.text)
	end
	return table.concat(out, "\n")
end

agent.tool({
	name = "history_recent",
	group = "history",
	description = "What changed lately in the open files and who changed it. For each file, "
		.. 'its edits, newest first: the author ("user", "external" for changes on disk, or '
		.. 'the plugin that made them; changes agents made through the editor are "agent"), '
		.. "the command they came from and how many seconds ago; then a diff of the text "
		.. "since the first of them",
	input = object({
		path = { type = "string", description = "One file; every open file if left out" },
		author = {
			type = "string",
			description = 'Only edits by them: "user", "external" or a plugin, like "agent"',
		},
		minutes = { type = "number", description = "How far back to look; 10 if left out" },
	}),
	run = function(args)
		local filter: greed.HistoryFilter = { since = os.time() - (args.minutes or 10) * 60 }
		if args.author == "user" or args.author == "external" then
			filter.author = args.author
		elseif args.author then
			filter.plugin = args.author
		end
		local wanted: greed.Buffer? = if args.path
			then core.file.buffer(args.path :: string)
			else nil
		local list = {}
		for _, buffer in greed.buffers() do
			local path = buffer:path()
			if path and (args.path == nil or wanted == buffer) then
				local entries = buffer:history(filter)
				if #entries > 0 then
					local edits = {}
					for i = 1, math.min(#entries, 20) do
						local entry = entries[i]
						table.insert(edits, {
							author = entry.plugin or entry.author,
							cause = entry.cause,
							seconds_ago = math.max(0, math.floor(os.time() - entry.time)),
						})
					end
					local before = buffer:text_before(entries[#entries].id) or ""
					table.insert(list, {
						path = path,
						edits = edits,
						diff = diff_lines(before, buffer:text()),
					})
				end
			end
		end
		return greed.json.array(list)
	end,
})

local EDITS = {
	type = "array",
	items = object(
		{ old_text = { type = "string" }, new_text = { type = "string" } },
		{ "old_text", "new_text" }
	),
}

agent.tool({
	name = "propose",
	kind = "edit",
	reviews = true,
	description = "Propose changes for the user to review in the editor: to one file with path "
		.. "and edits, or to several with files. Each change replaces old_text, which must "
		.. "appear exactly once in its file (quote enough around it), with new_text. Changes "
		.. "to several files make one operation the user can undo in one step. Waits for the "
		.. "user and says which changes they accepted",
	input = object({
		path = { type = "string" },
		edits = EDITS,
		files = {
			type = "array",
			items = object({ path = { type = "string" }, edits = EDITS }, { "path", "edits" }),
		},
		reason = { type = "string", description = "One line on why, shown to the user" },
	}),
	run = function(args)
		if args.files then
			return proposals.propose_files(args.files, args.reason)
		elseif args.path and args.edits then
			return proposals.propose(args.path, args.edits :: { proposals.Edit }, args.reason)
		end
		error("give path and edits, or files", 0)
	end,
})

agent.tool({
	name = "open",
	description = "Open a file in the editor for the user, optionally at a 1-based line",
	input = object({ path = { type = "string" }, line = { type = "integer" } }, { "path" }),
	run = function(args)
		local line: number? = args.line
		core.file.open_at(core.project.resolve(args.path), if line then line - 1 else nil)
		return `opened {args.path}`
	end,
})

agent.tool({
	name = "project",
	description = "The project's root folder",
	run = function()
		return core.project.root()
	end,
})

-- The buffer for `path` (the current one if nil), opening the file without
-- showing it if it isn't open, and failing without a syntax tree.
local function syntax_buffer(path: string?): greed.Buffer
	local buffer = if path then greed.load(core.project.resolve(path)) else greed.view():buffer()
	if buffer:tree() == nil then
		error(`no syntax tree for {buffer:path() or "this buffer"}: Greed has no grammar for it`, 0)
	end
	return buffer
end

-- Captured text longer than this many characters is cut, to keep answers
-- small.
local MAX_TEXT = 300

local function cut(text: string): string
	local past = utf8.offset(text, MAX_TEXT + 1)
	return if past and past <= #text then string.sub(text, 1, past - 1) .. "…" else text
end

agent.tool({
	name = "outline",
	description = "The functions and types in a file with their lines, from its syntax tree: "
		.. "cheaper than reading the whole file to find your way around it",
	input = object({
		path = { type = "string", description = "The file; the current one if left out" },
	}),
	run = function(args)
		local buffer = syntax_buffer(args.path)
		local list: { { name: string, kind: string, line: number, end_line: number } } = {}
		for _, object in { "function", "type" } do
			for _, found in core.syntax.objects(buffer, object) do
				local name = found.around:child("name")
				if name then
					table.insert(list, {
						name = name:text(),
						kind = found.around.kind,
						line = position(buffer, found.around.from).line,
						end_line = position(buffer, found.around.to).line,
					})
				end
			end
		end
		table.sort(list, function(a: { line: number }, b: { line: number })
			return a.line < b.line
		end)
		return greed.json.array(list)
	end,
})

agent.tool({
	name = "syntax_query",
	group = "syntax",
	description = "Run a tree-sitter query over a file's syntax tree, e.g. "
		.. '"(call_expression function: (identifier) @name)". Returns each match\'s captures '
		.. "with their node kind, 1-based lines and columns and text",
	input = object({
		query = { type = "string" },
		path = { type = "string", description = "The file; the current one if left out" },
	}, { "query" }),
	run = function(args)
		local buffer = syntax_buffer(args.path)
		local matches = {}
		for _, captures in buffer:query(args.query) do
			local match = {}
			for name, node in captures do
				local from, to = position(buffer, node.from), position(buffer, node.to)
				match[name] = {
					kind = node.kind,
					line = from.line,
					column = from.column,
					end_line = to.line,
					end_column = to.column,
					text = cut(node:text()),
				}
			end
			table.insert(matches, match)
		end
		return greed.json.array(matches)
	end,
})

agent.tool({
	name = "describe",
	description = "What a command, option, event, API function or type, plugin or mode is: "
		.. "its doc, keys, current value, who defined it and where. Also the objects of the "
		.. "running editor by id (buffer:12, tab:3, shell-block:7.2, terminal:9): their state, "
		.. "the objects they relate to and their actions; editor: relates to them all. Give a "
		.. "name that isn't exact and it lists the names that contain it: greed.tab lists that "
		.. "module's functions, View: a type's methods",
	input = object({
		name = {
			type = "string",
			description = "e.g. next-word, text-width, buffer.changed, greed.option.set, View, Buffer:edit, editor:, buffer:12",
		},
		kind = {
			type = "string",
			enum = { "command", "option", "event", "api", "plugin", "mode", "style", "object" },
			description = "To look in one kind only",
		},
	}, { "name" }),
	run = function(args)
		local text = describe.text(args.name, args.kind)
		if text then
			return text
		end
		local like = {}
		for _, entry in describe.entries(args.kind) do
			if string.find(entry.name, args.name, 1, true) and #like < 40 then
				table.insert(like, `{entry.kind} {entry.name}`)
			end
		end
		if #like == 0 then
			return `nothing called {args.name}`
		end
		return `nothing called exactly {args.name}; these contain it:\n{table.concat(like, "\n")}`
	end,
})

agent.tool({
	name = "debug_log",
	group = "plugins",
	description = "What Greed and its plugins say about what they're doing, kept while a debug "
		.. "topic is on: keys (each key, what it ran, how long it waited), runs (every run of "
		.. "plugin code and its time), frames (each frame built), rpc (language server "
		.. "messages), jobs (programs run), client (the terminal's or window's side), plugins "
		.. "(greed.debug.log; plugin:NAME for one). Turn topics on with `set`, do what you want "
		.. "to see, then read the lines; pass the last id as `after` to read only newer ones",
	input = object({
		set = {
			type = "string",
			description = 'Topics to turn on, with spaces between; "-keys" turns one off, "off" all',
		},
		after = { type = "number", description = "Only lines after this id" },
		limit = { type = "number", description = "At most this many, the newest; 200 if left out" },
		topic = { type = "string", description = "Only this topic's lines" },
		plugin = { type = "string", description = "Only this plugin's lines" },
	}),
	run = function(args)
		greed.debug.switch(args.set or "")
		return {
			on = greed.json.array(greed.debug.enabled()),
			lines = greed.json.array(greed.debug.lines({
				after = args.after,
				limit = args.limit or 200,
				topic = args.topic,
				plugin = args.plugin,
			})),
		}
	end,
})

return {}
