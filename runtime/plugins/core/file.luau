-- Opening, saving and quitting.

local greed = require("@greed")
local project = require("./project")
local registry = require("./registry")
local unsaved = require("./unsaved")

local M = {}

--- Marks a buffer as scratch: its changes don't count as unsaved, so `:q`
--- doesn't refuse over them and the status line shows no [+], like a
--- shell's or the output a command put in a buffer.
M.scratch = unsaved.scratch

--- Whether a buffer is marked as scratch.
M.is_scratch = unsaved.is_scratch

--- Whether a buffer has changes to save: a file's, not scratch, changed
--- since it was opened or saved.
M.unsaved = unsaved.unsaved

-- How buffers that aren't files save, by kind.
local savers: { [string]: (buffer: greed.Buffer) -> () } = {}

--- Makes :w on buffers of `kind` call `save` rather than write a file,
--- e.g. for a list of search results that writes its edits back, until
--- the plugin that called this goes.
function M.on_save(kind: string, save: (buffer: greed.Buffer) -> ())
	greed.plugin.tie(registry.set(savers, kind, save))
end

-- What runs on a file's buffer just before it's written, like a formatter,
-- by name.
local before_save: { [string]: (buffer: greed.Buffer) -> () } = {}

--- Makes `hook` run on each file's buffer just before it's written,
--- replacing any hook called `name`. An error in it is shown, and the file
--- is written anyway. It goes when the plugin that added it does.
function M.before_save(name: string, hook: (buffer: greed.Buffer) -> ())
	greed.plugin.tie(registry.set(before_save, name, hook))
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
	local found = {}
	for _, buffer in greed.buffers() do
		if unsaved.unsaved(buffer) then
			table.insert(found, buffer:path() or "an unnamed buffer")
		end
	end
	return found
end

greed.option.define({
	name = "on-quit",
	doc = 'What :q on the last project does to the session: "auto" ends it unless something '
		.. 'is running (a command in a terminal, an agent at work) and keeps it then, "end" always '
		.. 'ends it, "keep" always leaves it running to attach to again',
	default = "auto",
	choices = { "auto", "end", "keep" },
})

greed.option.define({
	name = "on-quit-remote",
	doc = "Like on-quit, when you're attached over greed ssh",
	default = "keep",
	choices = { "auto", "end", "keep" },
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
--- anything does. Replaces any check called `name`; it goes when the
--- plugin that added it does.
function M.running(name: string, check: () -> { string })
	greed.plugin.tie(registry.set(running, name, check))
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
	name = "client-independent",
	doc = "Lay this client out on its own, starting from what it shows now: "
		.. "its tabs, panes and project no longer follow the other clients",
	run = function()
		if greed.client.set_layout("independent") then
			greed.echo(
				"this client is laid out on its own now; :client-follow follows the others again"
			)
		else
			greed.echo("this client is laid out on its own already")
		end
	end,
})

greed.command({
	name = "client-follow",
	doc = "Have this client show the project, tabs and panes the other clients follow, "
		.. "closing the panes it had on its own (their buffers stay open)",
	run = function()
		if greed.client.set_layout("follow") then
			greed.echo("this client follows the others again")
		else
			greed.echo("this client follows already")
		end
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

-- Files that open as something other than text, like images: the last
-- opener added that matches a path opens it.
type Opener = {
	match: (path: string) -> boolean,
	open: (path: string, views: { greed.View }) -> string?,
}
local openers: { Opener } = {}

--- Makes the files `match(path)` says yes to open with `open` rather than
--- as text, like images as the picture. `open(path, views)` shows the file
--- in each of `views` and returns nil, or says why it can't, and then the
--- file opens as text. It goes when the plugin that added it does.
function M.opener(
	match: (path: string) -> boolean,
	open: (path: string, views: { greed.View }) -> string?
)
	greed.plugin.tie(registry.put(openers, { match = match, open = open }))
end

local function opener_for(path: string): Opener?
	for i = #openers, 1, -1 do
		if openers[i].match(path) then
			return openers[i]
		end
	end
	return nil
end

-- Set while a file whose opener failed opens as text.
local as_text = false

--- Shows the file at `path` in the main view and focuses it: as its
--- opener shows it (an image, a PDF), otherwise as text.
function M.open(path: string)
	local opener = opener_for(path)
	if opener then
		local main = greed.tab.current().active
		local err = opener.open(path, { main })
		if err == nil then
			main:focus()
			return
		end
		greed.echo(err)
	end
	as_text = opener ~= nil
	local ok, err = pcall(function()
		greed.open(path)
	end)
	as_text = false
	if not ok then
		error(err, 0)
	end
end

--- Opens `path` like `M.open`, with the cursor on 0-based `line` at byte
--- `col` of it (both kept inside the file), when `line` is given.
function M.open_at(path: string, line: number?, col: number?)
	M.open(path)
	if line == nil then
		return
	end
	local view = greed.view()
	local buffer = view:buffer()
	local row = math.clamp(line, 0, buffer:line_count() - 1)
	view:set_cursor(math.min(buffer:line_start(row) + math.max(col or 0, 0), buffer:line_end(row)))
end

-- Files opened some other way than `M.open`, like `greed FILE` from a
-- shell, open as text first; their opener takes over the views.
greed.on("buffer.opened", function(event: greed.BufferChanged)
	local path = event.buffer:path()
	local opener = if path and not as_text then opener_for(path) else nil
	if path and opener then
		local err = opener.open(path, event.buffer:views())
		if err then
			greed.echo(err)
		end
	end
end)

greed.option.define({
	name = "link-opener",
	doc = 'What opens a link, e.g. "firefox"; empty for xdg-open, or open on macOS',
	default = "",
})

--- Opens `uri` (a web address, or any link the system knows how to open)
--- with the link-opener option, or the system's opener. Says why when it
--- can't.
function M.open_link(uri: string)
	local given = greed.option.get("link-opener") :: string
	local done, err
	if given ~= "" then
		local command = string.split(given, " ")
		table.insert(command, uri)
		done, err = greed.process.run(command)
	else
		done, err = greed.process.run({ "xdg-open", uri })
		if done == nil then
			done, err = greed.process.run({ "open", uri })
		end
	end
	if done == nil then
		greed.echo(`can't open {uri}: {err}`)
	elseif done.code ~= 0 then
		greed.echo(`can't open {uri}: {done.stderr}`)
	end
end

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
		M.open(path)
	end,
})

-- What views showing `closing` show instead: the file opened last in the
-- same project, or an empty buffer.
local function replacement(closing: greed.Buffer): greed.Buffer
	local best: greed.Buffer? = nil
	for _, buffer in greed.buffers() do
		if
			buffer ~= closing
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
	if unsaved.unsaved(buffer) and not force then
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
			if buffer ~= ctx.buffer and buffer:path() then
				table.insert(others, buffer)
			end
		end
		if not ctx.force then
			local found = {}
			for _, buffer in others do
				if buffer:modified() then
					table.insert(found, buffer:path() :: string)
				end
			end
			if #found > 0 then
				error(`unsaved changes in {table.concat(found, ", ")} - :bco! closes anyway`, 0)
			end
		end
		for _, buffer in others do
			M.close(buffer, true)
		end
	end,
})

--- The open buffer for the file at `path`, or nil if it isn't open. A
--- relative path is from `root`, the shown project's root by default (see
--- `project.resolve`).
function M.buffer(path: string, root: string?): greed.Buffer?
	return greed.buffer_for(project.resolve(path, root))
end

-- The last view showing a file that had focus.
local last_file_view: greed.View? = nil

local function has_file(view: greed.View?): boolean
	if view == nil then
		return false
	end
	-- A closed view fails when asked anything.
	local ok, path = pcall(function(): string?
		return view:buffer():path()
	end)
	return ok and path ~= nil
end

greed.on("view.focused", function(event: greed.ViewFocused)
	if has_file(event.view) then
		last_file_view = event.view
	elseif has_file(event.from) then
		last_file_view = event.from
	end
end)

--- The view with the file the user is in, for things typed elsewhere (an
--- agent's pane, a shell) that are about it: the focused one when it shows
--- a file, else the tab's active pane, else the last one with a file that
--- had focus. Nil when none shows a file.
function M.view(): greed.View?
	local focused = greed.view()
	if has_file(focused) then
		return focused
	end
	local active = greed.tab.current().active
	if has_file(active) then
		return active
	end
	return if has_file(last_file_view) then last_file_view else nil
end

--- The text of the file at `path` as you have it: its buffer's, unsaved
--- changes included, when it's open, otherwise what's on disk; nil and why
--- when there's neither. Paths are taken as `M.buffer` takes them.
function M.text(path: string, root: string?): (string?, string?)
	local full = project.resolve(path, root)
	local buffer = greed.buffer_for(full)
	if buffer then
		return buffer:text(), nil
	end
	return greed.fs.read(full)
end

export type WriteOptions = {
	--- What a relative path is from (see `M.buffer`).
	root: string?,
	--- Replace only `from`..`to` (0-based byte offsets) with the text.
	from: number?,
	to: number?,
	--- Open the file in a buffer to write through if it exists but isn't
	--- open, so its language server sees the change.
	load: boolean?,
}

--- Writes `text` to the file at `path`. An open file is changed through its
--- buffer, so undo takes it back and its language server sees it, and
--- saved; otherwise the file is written. Returns the buffer when it went
--- through one, and fails with why when it can't write.
function M.write(path: string, text: string, opts: WriteOptions?): greed.Buffer?
	local o: WriteOptions = opts or {}
	local full = project.resolve(path, o.root)
	local buffer = greed.buffer_for(full)
	if buffer == nil and o.load and greed.fs.stat(full) then
		buffer = greed.load(full)
	end
	if buffer then
		local open = buffer
		open:edit(function(e)
			e:replace(o.from or 0, o.to or open:len(), text)
		end)
		open:save()
		return open
	end
	local new = text
	if o.from or o.to then
		-- A file that isn't there yet is empty.
		local read, err = greed.fs.read(full)
		if read == nil and greed.fs.stat(full) then
			error(err, 0)
		end
		local old = read or ""
		new = string.sub(old, 1, o.from or 0) .. text .. string.sub(old, (o.to or #old) + 1)
	end
	local ok, err = greed.fs.write(full, new)
	if not ok then
		error(err, 0)
	end
	return nil
end

return M
