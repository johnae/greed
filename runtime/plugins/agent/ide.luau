-- Claude Code's IDE integration: run `claude` in the project and `/ide`
-- offers Kern, like it offers VS Code. Claude Code then sees your
-- selection as you move, reads diagnostics, and shows its edits here as
-- proposed changes to accept or reject (see proposals.luau) instead of
-- writing files behind your back.
--
--   space o m  mention the selected lines to Claude Code

local kern = require("@kern")
local core = require("@core")
local registry = require("./registry")
local proposals = require("./proposals")

local function text(...: string)
	local content = {}
	for _, part in { ... } do
		table.insert(content, { type = "text", text = part })
	end
	return { content = content }
end

local function json(value: any)
	return text(kern.json.encode(value))
end

local function absolute(path: string): string
	return if string.sub(path, 1, 1) == "/" then path else kern.fs.cwd() .. "/" .. path
end

local function uri(path: string): string
	return "file://" .. absolute(path)
end

-- The open buffer for the file at `path`, however either path is written.
local function find_buffer(path: string): kern.Buffer?
	local wanted = absolute(path)
	for _, buffer in kern.buffers() do
		local own = buffer:path()
		if own and absolute(own) == wanted then
			return buffer
		end
	end
	return nil
end

-- A position as LSP and Claude Code count it: 0-based line and column.
local function lsp_position(buffer: kern.Buffer, pos: number)
	local line = buffer:line_of(pos)
	return { line = line, character = pos - buffer:line_start(line) }
end

-- Where the primary selection of `view` starts and ends.
local function primary_range(view: kern.View): (number, number)
	local selection = view:selection()
	local range = selection.ranges[selection.primary]
	return math.min(range.anchor, range.head), math.max(range.anchor, range.head)
end

-- The primary selection in the main view, as Claude Code describes one.
local function current_selection(): { [string]: any }?
	local view = kern.view()
	local buffer = view:buffer()
	local path = buffer:path()
	if path == nil then
		return nil
	end
	local from, to = primary_range(view)
	return {
		text = buffer:slice(from, to),
		filePath = absolute(path),
		fileUrl = uri(path),
		selection = {
			start = lsp_position(buffer, from),
			["end"] = lsp_position(buffer, to),
			isEmpty = from == to,
		},
	}
end

local function tool(name: string, run: (args: { [string]: any }) -> any)
	registry.tool({ name = name, description = name, client = "ide", run = run })
end

tool("openFile", function(args)
	local path = args.filePath
	if args.makeFrontmost == false then
		local buffer = kern.load(path)
		return json({
			success = true,
			filePath = absolute(path),
			languageId = buffer:language(),
			lineCount = buffer:line_count(),
		})
	end
	kern.open(path)
	local view = kern.view()
	local buffer = view:buffer()
	if args.startText then
		local content = buffer:text()
		local from = string.find(content, args.startText, 1, true)
		if from then
			local to = from - 1 + #args.startText
			if args.endText then
				local finish = string.find(content, args.endText, from, true)
				to = if finish then finish - 1 + #args.endText else to
			end
			if args.selectToEndOfLine then
				to = buffer:line_end(buffer:line_of(to))
			end
			view:set_selection({ ranges = { { anchor = from - 1, head = to } }, primary = 1 })
		end
	end
	return text(`Opened file: {absolute(path)}`)
end)

tool("openDiff", function(args)
	local path = args.new_file_path or args.old_file_path
	local buffer = kern.load(path)
	local before = buffer:text()
	local changes = kern.diff(before, args.new_file_contents)
	if #changes == 0 then
		return text("FILE_SAVED", before)
	end
	kern.open(path)
	local unsaved = buffer:modified()
	local decided = proposals.propose_changes(buffer, path, changes, args.tab_name, args.tab_name)
	if decided.accepted == 0 then
		return text("DIFF_REJECTED", args.tab_name)
	end
	-- Claude Code writes the file with this text too; saving keeps the
	-- buffer from looking changed.
	if not unsaved then
		buffer:save()
	end
	return text("FILE_SAVED", buffer:text())
end)

tool("close_tab", function(args)
	proposals.withdraw(args.tab_name)
	return text("TAB_CLOSED")
end)

tool("closeAllDiffTabs", function()
	return text(`CLOSED_{proposals.withdraw_all()}_DIFF_TABS`)
end)

local function selection_tool()
	local selection = current_selection()
	if selection == nil then
		return json({ success = false, message = "No active editor found" })
	end
	selection.success = true
	return json(selection)
end

tool("getCurrentSelection", selection_tool)
tool("getLatestSelection", selection_tool)

tool("getOpenEditors", function()
	local active = kern.view():buffer():id()
	local tabs: { any } = {}
	for _, buffer in kern.buffers() do
		local path = buffer:path()
		if path then
			table.insert(tabs, {
				uri = uri(path),
				isActive = buffer:id() == active,
				label = string.match(path, "[^/]*$"),
				languageId = buffer:language(),
				isDirty = buffer:modified(),
			})
		end
	end
	return json({ tabs = kern.json.array(tabs) })
end)

tool("getWorkspaceFolders", function()
	local root = core.project.root()
	return json({
		success = true,
		folders = { { name = string.match(root, "[^/]*$"), uri = uri(root), path = root } },
		rootPath = root,
	})
end)

local SEVERITY = { "Error", "Warning", "Information", "Hint" }

tool("getDiagnostics", function(args)
	local files: { any } = {}
	for _, buffer in kern.buffers() do
		local path = buffer:path()
		if path and (args.uri == nil or uri(path) == args.uri) then
			local list: { any } = {}
			for _, d in kern.lsp.diagnostics(buffer) do
				table.insert(list, {
					message = d.message,
					severity = SEVERITY[d.severity] or "Hint",
					range = {
						start = lsp_position(buffer, d.from),
						["end"] = lsp_position(buffer, d.to),
					},
					source = d.source,
				})
			end
			table.insert(files, { uri = uri(path), diagnostics = kern.json.array(list) })
		end
	end
	return json(kern.json.array(files))
end)

tool("checkDocumentDirty", function(args)
	local buffer = find_buffer(args.filePath)
	if buffer == nil then
		return json({ success = false, message = `Document not open: {args.filePath}` })
	end
	return json({
		success = true,
		filePath = args.filePath,
		isDirty = buffer:modified(),
		isUntitled = false,
	})
end)

tool("saveDocument", function(args)
	local buffer = find_buffer(args.filePath)
	if buffer == nil then
		return json({ success = false, message = `Document not open: {args.filePath}` })
	end
	buffer:save()
	return json({
		success = true,
		filePath = args.filePath,
		saved = true,
		message = "Document saved successfully",
	})
end)

-- Tells Claude Code about the selection a moment after it settles, so
-- holding a key down doesn't flood it.
local last_sent = ""
local generation = 0

kern.on("command.run", function()
	generation += 1
	local mine = generation
	kern.sleep(100)
	if mine ~= generation then
		return
	end
	local selection = current_selection()
	if selection == nil then
		return
	end
	local encoded = kern.json.encode(selection)
	if encoded ~= last_sent then
		last_sent = encoded
		kern.control.notify("selection_changed", selection)
	end
end)

kern.command({
	name = "ide-mention",
	doc = "Mention the selected lines to Claude Code, like @file#L1-5",
	run = function(ctx)
		local path = ctx.buffer:path()
		if path == nil then
			error("this buffer has no file to mention", 0)
		end
		local from, to = primary_range(ctx.view)
		-- A selection ending at a line's start, like `x` makes, ends on the
		-- line before.
		local last = if to > from and to == ctx.buffer:line_start(ctx.buffer:line_of(to))
			then ctx.buffer:line_of(ctx.buffer:prev_char(to))
			else ctx.buffer:line_of(to)
		kern.control.notify("at_mentioned", {
			filePath = absolute(path),
			lineStart = ctx.buffer:line_of(from),
			lineEnd = last,
		})
	end,
})

kern.keymap.bind("normal", { ["space o m"] = "ide-mention" })

-- Without a session (in tests, say) there is nothing for Claude Code to
-- connect to.
pcall(kern.control.serve_ide, { core.project.root() }, nil)

return {}
