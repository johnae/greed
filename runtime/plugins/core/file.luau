-- Opening, saving and quitting.

local greed = require("@greed")
local project = require("./project")

local M = {}

-- How buffers that aren't files save, by kind.
local savers: { [string]: (buffer: greed.Buffer) -> () } = {}

--- Makes :w on buffers of `kind` call `save` rather than write a file,
--- e.g. for a list of search results that writes its edits back.
function M.on_save(kind: string, save: (buffer: greed.Buffer) -> ())
	savers[kind] = save
end

-- What runs on a file's buffer just before it's written, like a formatter,
-- by name.
local before_save: { [string]: (buffer: greed.Buffer) -> () } = {}

--- Makes `hook` run on each file's buffer just before it's written,
--- replacing any hook called `name`. An error in it is shown, and the file
--- is written anyway.
function M.before_save(name: string, hook: (buffer: greed.Buffer) -> ())
	before_save[name] = hook
end

local function save(buffer: greed.Buffer, path: string?)
	local saver = savers[buffer:kind()]
	if saver and path == nil then
		saver(buffer)
		return
	end
	for _, hook in before_save do
		xpcall(hook, function(err)
			greed.echo(tostring(err))
		end, buffer)
	end
	buffer:save(path)
	greed.echo("wrote " .. (buffer:path() or "?"))
end

-- Fails if any of `unsaved` has changes, unless `force` says to go ahead.
local function check_unsaved(unsaved: { string }, force: boolean)
	if #unsaved > 0 and not force then
		error(
			"unsaved changes in " .. table.concat(unsaved, ", ") .. " - :w saves, :q! quits anyway",
			0
		)
	end
end

-- Every file with unsaved changes, in any project.
local function all_unsaved(): { string }
	local unsaved = {}
	for _, buffer in greed.buffers() do
		if buffer:kind() == "file" and buffer:modified() then
			table.insert(unsaved, buffer:path() or "an unnamed buffer")
		end
	end
	return unsaved
end

greed.option.define({
	name = "on-quit",
	doc = 'What :q on the last project does to the session: "auto" ends it unless something '
		.. 'is running (a command in a terminal, an agent at work) and keeps it then, "end" always '
		.. 'ends it, "keep" always leaves it running to attach to again',
	default = "auto",
})

greed.option.define({
	name = "on-quit-remote",
	doc = "Like on-quit, when you're attached over greed ssh",
	default = "keep",
})

greed.option.define({
	name = "session-idle-hours",
	doc = "A session nothing is attached to, with nothing running and nothing unsaved, ends after this many hours; 0 keeps it",
	default = 24,
})

-- What keeps a session worth keeping, by name: each says what of it runs.
local running: { [string]: () -> { string } } = {}

--- Makes `check` say what of yours is running ("cargo test in a
--- terminal", "an agent at work"), for :q to keep the session while
--- anything does. Replaces any check called `name`.
function M.running(name: string, check: () -> { string })
	running[name] = check
end

--- Everything the checks say is running.
function M.busy(): { string }
	local found = {}
	for _, check in running do
		local ok, said = pcall(check)
		if ok then
			for _, what in said do
				table.insert(found, what)
			end
		end
	end
	table.sort(found)
	return found
end

--- Whether :q on the last project keeps the session, attached over ssh
--- or not (`remote`), and what's running.
function M.keeps(remote: boolean): (boolean, { string })
	local how = greed.option.get(if remote then "on-quit-remote" else "on-quit")
	local busy = M.busy()
	return how == "keep" or (how == "auto" and #busy > 0), busy
end

-- Ends the session, whatever runs in it, unless files have unsaved changes
-- and `force` doesn't say to go ahead.
local function end_session(force: boolean)
	check_unsaved(all_unsaved(), force)
	greed.quit()
end

-- Leaves the shown project: with others open it closes and the terminal
-- lets go, leaving the rest running. The last one ends the session or
-- keeps it, as on-quit says. In a panel or a float, like an agent's
-- transcript or a help page, it closes just that, as `:q` closes a window
-- in Vim.
local function quit(force: boolean)
	local view = greed.view()
	if not view:is_pane() then
		view:close()
		return
	end
	if #greed.project.list() == 1 then
		-- Only a session can be left running; unsaved changes are safe in it.
		if greed.session.current() and M.keeps(greed.session.remote()) then
			greed.detach()
			return
		end
		end_session(force)
		return
	end
	check_unsaved(project.unsaved(), force)
	greed.project.close(greed.project.current().id)
	greed.detach()
end

greed.command({
	name = "save",
	doc = "Write the buffer to its file, or to a new one",
	args = {
		{
			name = "path",
			doc = "Where to write it; it becomes the buffer's file",
			complete = "file",
		},
	},
	run = function(ctx)
		save(ctx.buffer, ctx.args[1])
	end,
})

greed.command({
	name = "detach",
	doc = "Leave the editor running in the background; greed attach comes back",
	run = function()
		greed.detach()
	end,
})

greed.command({
	name = "quit",
	doc = "Close the project and leave, or exit the editor if it's the last one; "
		.. "refuses with unsaved changes (force goes anyway)",
	run = function(ctx)
		quit(ctx.force)
	end,
})

greed.command({
	name = "quit-session",
	doc = "End the session, whatever runs in it, unless files have unsaved changes (force ends it anyway)",
	run = function(ctx)
		end_session(ctx.force)
	end,
})

-- Counts each time a client goes, so an idle wait that started before the
-- last one gives up.
local detached_count = 0

-- With nothing attached, ends the session once nothing has run in it for
-- session-idle-hours. Something running starts the wait over.
greed.on("client.detached", function()
	detached_count += 1
	local mine = detached_count
	greed.spawn(function()
		local idle_since = greed.now()
		while true do
			greed.sleep(60000)
			if mine ~= detached_count or greed.session.attached() then
				return
			end
			local hours = tonumber(greed.option.get("session-idle-hours")) or 0
			if #M.busy() > 0 or #all_unsaved() > 0 or hours <= 0 then
				idle_since = greed.now()
			elseif greed.now() - idle_since >= hours * 3600000 then
				greed.quit()
				return
			end
		end
	end)
end)

greed.command({
	name = "quit-all",
	doc = "End the session and every project in it, whatever runs, unless files have unsaved changes (force ends it anyway)",
	run = function(ctx)
		end_session(ctx.force)
	end,
})

greed.command({
	name = "save-quit",
	doc = "Write the buffer to its file, then quit",
	run = function(ctx)
		save(ctx.buffer)
		quit(ctx.force)
	end,
})

greed.command({
	name = "open",
	doc = "Open a file in the main view",
	args = {
		{
			name = "path",
			doc = "The file to open; a new one is created when saved",
			complete = "file",
		},
	},
	run = function(ctx)
		local path = ctx.args[1]
		if path == nil then
			error("open needs a path, e.g. :open src/main.rs", 0)
		end
		greed.open(path)
	end,
})

-- What views showing `closing` show instead: the file opened last in the
-- same project, or an empty buffer.
local function replacement(closing: greed.Buffer): greed.Buffer
	local best: greed.Buffer? = nil
	for _, buffer in greed.buffers() do
		if
			buffer:id() ~= closing:id()
			and buffer:path()
			and buffer:project() == closing:project()
			and (best == nil or buffer:id() > best:id())
		then
			best = buffer
		end
	end
	return best or greed.create_buffer("file", "")
end

--- Closes `buffer`: views showing it show another file instead. Refuses
--- with unsaved changes unless `force`.
function M.close(buffer: greed.Buffer, force: boolean?)
	if buffer:kind() == "file" and buffer:modified() and not force then
		error(
			`unsaved changes in {buffer:path() or "this buffer"} - :w saves, :bc! closes anyway`,
			0
		)
	end
	local views = buffer:views()
	if #views > 0 then
		local instead = replacement(buffer)
		for _, view in views do
			view:show(instead)
		end
	end
	buffer:close()
end

greed.command({
	name = "buffer-close",
	doc = "Close this buffer, showing another file in its place; refuses with "
		.. "unsaved changes (force closes anyway)",
	run = function(ctx)
		M.close(ctx.buffer, ctx.force)
	end,
})

greed.command({
	name = "buffer-close-others",
	doc = "Close every file but this one; refuses if one has unsaved changes "
		.. "(force closes anyway)",
	run = function(ctx)
		local others = {}
		for _, buffer in greed.buffers() do
			if buffer:id() ~= ctx.buffer:id() and buffer:path() then
				table.insert(others, buffer)
			end
		end
		if not ctx.force then
			local unsaved = {}
			for _, buffer in others do
				if buffer:modified() then
					table.insert(unsaved, buffer:path() :: string)
				end
			end
			if #unsaved > 0 then
				error(`unsaved changes in {table.concat(unsaved, ", ")} - :bco! closes anyway`, 0)
			end
		end
		for _, buffer in others do
			M.close(buffer, true)
		end
	end,
})

return M
