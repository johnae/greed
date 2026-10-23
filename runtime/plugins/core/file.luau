-- Opening, saving and quitting.

local greed = require("@greed")
local project = require("./project")
local prompt = require("./prompt")
local recent = require("./recent")
local registry = require("./registry")
local text = require("./text")
local transient = require("./transient")
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
	greed.plugin.cleanup(registry.set(savers, kind, save))
end

--- How a file is being saved, for the hooks that run before: `auto` when
--- auto-save saves it, while you may only have paused typing.
export type Saving = { auto: boolean }

type Hook = (buffer: greed.Buffer, how: Saving) -> ()

-- What runs on a file's buffer just before it's written, like a formatter,
-- by name.
local before_save: { [string]: Hook } = {}

--- Makes `hook` run on each file's buffer just before it's written,
--- replacing any hook called `name`. An error in it is shown, and the file
--- is written anyway. It goes when the plugin that added it does.
function M.before_save(name: string, hook: Hook)
	greed.plugin.cleanup(registry.set(before_save, name, hook))
end

-- Writes `buffer` to its file, or `path`, after the hooks.
local function write(buffer: greed.Buffer, path: string?, how: Saving)
	registry.tell(before_save, buffer, how)
	buffer:save(path)
end

--- Saves a file's buffer as auto-save does: the hooks are told it's an
--- auto-save, and nothing is said.
function M.autosave(buffer: greed.Buffer)
	write(buffer, nil, { auto = true })
end

-- Saves `buffer`, to `path` if given. A folder it goes in that isn't there
-- is made with `force`; without, saving refuses, saying `forced` makes it.
local function save(buffer: greed.Buffer, path: string?, force: boolean?, forced: string?)
	path = path and project.resolve(path)
	local saver = savers[buffer:kind()]
	if saver and path == nil then
		saver(buffer)
		return
	end
	if path == nil and buffer:path() == nil then
		-- An untitled buffer asks where to go, as "Save As" does.
		local given = prompt.ask("save as")
		if given == nil or string.match(given, "^%s*$") then
			error("not saved", 0)
		end
		path = project.resolve(given)
	end
	local folder = string.match(path or buffer:path() or "", "^(.+)/[^/]*$")
	if folder and greed.fs.stat(folder) == nil then
		if not force then
			error(
				`can't save {project.name(buffer)}: the folder {project.relative(folder)} isn't there; {forced or ":w!"} makes it`,
				0
			)
		end
		assert(greed.fs.mkdir(folder))
	end
	write(buffer, path, { auto = false })
	greed.echo("wrote " .. project.name(buffer))
end

-- The names of `buffers`, joined for a message.
local function names(buffers: { greed.Buffer }): string
	local list = {}
	for _, buffer in buffers do
		table.insert(list, project.name(buffer))
	end
	return table.concat(list, ", ")
end

-- Every file with unsaved changes, in any project.
local function all_unsaved(): { greed.Buffer }
	local found = {}
	for _, buffer in greed.buffers() do
		if unsaved.unsaved(buffer) then
			table.insert(found, buffer)
		end
	end
	return found
end

-- Saves each of `buffers` that has a file, making missing folders with
-- `force`; fails naming how many have none, after saving the rest.
local function save_all(buffers: { greed.Buffer }, force: boolean?, forced: string?)
	local unnamed = 0
	for _, buffer in buffers do
		if buffer:path() then
			save(buffer, nil, force, forced or ":wa!")
		else
			unnamed += 1
		end
	end
	if unnamed == 1 then
		error("an unnamed buffer has no file to save to - :w PATH saves it", 0)
	elseif unnamed > 1 then
		error(`{unnamed} unnamed buffers have no file to save to - :w PATH saves each`, 0)
	end
end

-- How quitting goes on with unsaved files: what forcing it is typed as,
-- for the refusal, or to ask instead.
type Unsaved = { forced: string, ask: boolean? }

-- Whether to go on with `buffers` unsaved: yes when there are none or
-- `force` says so. With `how.ask`, asks whether to save them first, go on
-- without saving, or stop, as VS Code does on quitting; otherwise fails,
-- naming them.
local function go_on(buffers: { greed.Buffer }, force: boolean, how: Unsaved): boolean
	if #buffers == 0 or force then
		return true
	end
	local list = names(buffers)
	if not how.ask then
		local only = if #buffers == 1 then buffers[1] else nil
		local saves = if only == nil
			then ":wa saves them"
			elseif only:path() == nil then ":w PATH saves it"
			elseif only ~= greed.view():buffer() then ":wa saves it"
			else ":w saves it"
		error(`unsaved changes in {list} - {saves}, {how.forced} quits anyway`, 0)
	end
	local chosen: string? = nil
	local function choose(choice: string): (switches: { [string]: boolean }) -> ()
		return function(_switches)
			chosen = choice
		end
	end
	transient.show({
		title = `Unsaved changes in {list}`,
		groups = {
			{
				title = "Quit",
				items = {
					{ key = "s", doc = "Save, then quit", run = choose("save") },
					{ key = "d", doc = "Don't save, quit", run = choose("discard") },
					{ key = "esc", doc = "Cancel" },
				},
			},
		},
	})
	if chosen == "save" then
		save_all(buffers)
	end
	return chosen ~= nil
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
	greed.plugin.cleanup(registry.set(running, name, check))
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
	go_on(all_unsaved(), force, { forced = ":qa!" })
	greed.quit()
end

-- Runs the command `name` if a plugin has it; says whether it did.
local function run_if(name: string): boolean
	for _, command in greed.commands() do
		if command.name == name then
			greed.run(name)
			return true
		end
	end
	return false
end

-- Closes what `:q` is in, as Vim's `:q` closes a window: a panel or a
-- float (an agent's transcript, a help page), a pane with others beside
-- it, or the last pane of a tab with others after it. Its buffer stays
-- open, so this never refuses. Says whether there was one to close.
local function close_window(): boolean
	local view = greed.view()
	-- pane-close also ends a terminal the float was the last to show.
	if not view:is_pane() then
		return run_if("pane-close") or view:close()
	end
	if #greed.tab.current().panes > 1 and (run_if("pane-close") or view:close()) then
		return true
	end
	return #greed.tab.list() > 1
		and (run_if("tab-close") or greed.tab.close(greed.tab.current().id))
end

-- What ends the wait on each buffer a program waits on, by buffer id.
local waiting: { [number]: greed.Signal } = {}

--- Waits until `buffer` is done with, for a program that opened it to be
--- edited, as `git commit` does through `greed edit --wait`: `:q` or `:wq`
--- in it, or closing it, give "done", and `:cq` "aborted". Until then `:q`
--- there ends the wait rather than closing a window or leaving, refusing
--- over unsaved changes as it always does. Waits in a command, handler or
--- greed.spawn.
function M.wait(buffer: greed.Buffer): "done" | "aborted"
	local id = buffer:id()
	local signal = waiting[id] or greed.signal()
	waiting[id] = signal
	return signal:wait()
end

--- Whether a program waits on `buffer` (see `wait`).
function M.waited(buffer: greed.Buffer): boolean
	return waiting[buffer:id()] ~= nil
end

local function finish(id: number, outcome: "done" | "aborted"): boolean
	local signal = waiting[id]
	if signal == nil then
		return false
	end
	waiting[id] = nil
	signal:send(outcome)
	return true
end

--- Ends the wait on `buffer` with `outcome`, "done" by default, as `:q` in
--- it does. False when nothing waited on it.
function M.finish(buffer: greed.Buffer, outcome: ("done" | "aborted")?): boolean
	return finish(buffer:id(), outcome or "done")
end

greed.on("buffer.closed", function(event: greed.BufferClosed)
	finish(event.id, "done")
end)

-- Closes the window `:q` is in, if there's one to close, or else leaves
-- the shown project: with others open it closes and the terminal lets go,
-- leaving the rest running. The last one ends the session or keeps it, as
-- on-quit says. With `ask`, as VS Code's ctrl-q, it leaves whatever window
-- it's in, and unsaved files ask rather than refuse. In a buffer a program
-- waits on, it ends the wait instead.
local function quit(force: boolean, ask: boolean?)
	local buffer = greed.view():buffer()
	if not ask and M.waited(buffer) then
		go_on(if unsaved.unsaved(buffer) then { buffer } else {}, force, { forced = ":q!" })
		M.finish(buffer)
		return
	end
	if not ask and close_window() then
		return
	end
	if #greed.project.list() == 1 then
		-- Only a session can be left running; unsaved changes are safe in it.
		if greed.session.current() and M.keeps(greed.session.remote()) then
			greed.detach()
			return
		end
		if go_on(all_unsaved(), force, { forced = ":q!", ask = ask }) then
			greed.quit()
		end
		return
	end
	if go_on(project.unsaved_buffers(), force, { forced = ":q!", ask = ask }) then
		greed.project.close(greed.project.current().id)
		greed.detach()
	end
end

greed.command({
	name = "save",
	doc = "Write the buffer to its file, or to a new one; force makes a folder it goes in that isn't there",
	args = {
		{
			name = "path",
			doc = "Where to write it; it becomes the buffer's file",
			complete = "file",
			type = "string",
			optional = true,
		},
	},
	run = function(ctx)
		local path: string? = ctx.values.path
		if path and string.sub(path, 1, 1) == "!" then
			error(
				"Greed doesn't write to a program: :%!cmd puts the lines through it, :!cmd runs it in the shell",
				0
			)
		end
		save(ctx.buffer, path, ctx.force)
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
	doc = "Close this pane when there are others; otherwise close the project and leave, "
		.. "or exit the editor if it's the last one, refusing with unsaved changes (force goes anyway)",
	run = function(ctx)
		quit(ctx.force)
	end,
})

greed.command({
	name = "quit-abort",
	doc = "In a file a program waits on, like git commit's message, stop the program with an error, "
		.. "as Vim's :cq does; whatever was written is left as it is",
	run = function(ctx)
		if not M.finish(ctx.buffer, "aborted") then
			error("no program waits on this buffer", 0)
		end
	end,
})

greed.command({
	name = "quit-ask",
	doc = "Leave the project, or exit the editor, from any pane, as VS Code's ctrl-q does; "
		.. "asks whether to save unsaved files first rather than refusing",
	run = function(ctx)
		quit(ctx.force, true)
	end,
})

greed.command({
	name = "quit-session",
	doc = "End the session, whatever runs in it, unless files have unsaved changes (force ends it anyway); "
		.. "terminals, shells and agents never count as unsaved",
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
	doc = "Write the buffer to its file if it changed, then quit",
	run = function(ctx)
		-- Unchanged, there's nothing to write, as with an untitled buffer
		-- nothing was typed in.
		if unsaved.unsaved(ctx.buffer) or savers[ctx.buffer:kind()] then
			save(ctx.buffer, nil, ctx.force, ":wq!")
		end
		quit(ctx.force)
	end,
})

greed.command({
	name = "save-all",
	doc = "Write every file with unsaved changes; force makes folders they go in that aren't there",
	run = function(ctx)
		local buffers = all_unsaved()
		if #buffers == 0 then
			greed.echo("nothing to save")
			return
		end
		save_all(buffers, ctx.force)
	end,
})

greed.command({
	name = "save-quit-all",
	doc = "Write every file with unsaved changes, then end the session",
	run = function(ctx)
		save_all(all_unsaved(), ctx.force, ":wqa!")
		end_session(ctx.force)
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
	greed.plugin.cleanup(registry.put(openers, { match = match, open = open }))
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

-- Hands `uri` to `command` (the uri last), or else the link-opener option
-- or the system's opener. Says why when it can't.
local function outside(uri: string, command: { string }?)
	local given = greed.option.get("link-opener") :: string
	local done, err
	if command or given ~= "" then
		local run = if command then table.clone(command) else string.split(given, " ")
		table.insert(run, uri)
		done, err = greed.process.run(run)
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

--- How a file opens, by its extension: as Greed shows it ("greed": its
--- viewer, or as text), with the system's opener ("outside"), or with a
--- command, the file's path last.
export type OpenWith = "greed" | "outside" | { string }

-- How files open, by extension, as your config says.
local ways: { [string]: OpenWith } = {}

-- What Greed can't show and the system's opener can: documents, sound
-- and video. Other files open in Greed unless you say otherwise.
local DOCUMENTS = {}
for _, ext in
	{
		"doc",
		"docx",
		"odt",
		"rtf",
		"pages",
		"xls",
		"xlsx",
		"ods",
		"numbers",
		"ppt",
		"pptx",
		"odp",
		"key",
		"epub",
		"mobi",
		"mp3",
		"m4a",
		"ogg",
		"oga",
		"opus",
		"flac",
		"wav",
		"aac",
		"mp4",
		"m4v",
		"mov",
		"mkv",
		"webm",
		"avi",
	}
do
	DOCUMENTS[ext] = true
end

-- Programs and scripts: what the system's opener would run. They're
-- never handed out; one that's text opens as text.
local PROGRAMS = {}
for _, ext in
	{
		"exe",
		"msi",
		"com",
		"scr",
		"bat",
		"cmd",
		"ps1",
		"vbs",
		"vbe",
		"js",
		"jse",
		"wsf",
		"hta",
		"cpl",
		"lnk",
		"reg",
		"jar",
		"apk",
		"app",
		"command",
		"tool",
		"sh",
		"bash",
		"zsh",
		"fish",
		"csh",
		"run",
		"bin",
		"appimage",
		"desktop",
		"deb",
		"rpm",
		"pkg",
		"dmg",
		"iso",
		"workflow",
		"scpt",
		"applescript",
		"py",
		"pl",
		"rb",
	}
do
	PROGRAMS[ext] = true
end

local function extension(path: string): string
	return string.lower(string.match(path, "%.([%w]+)$") or "")
end

--- Makes files ending in `.ext` open `how`: in Greed ("greed", the
--- default), with the system's opener ("outside") or with a command, as
--- `core.file.open_with("docx", { "libreoffice" })`. Programs never open
--- outside, whatever it says. It goes with the plugin (or config) that
--- said it.
function M.open_with(ext: string, how: OpenWith)
	local bare = string.gsub(ext, "^%.", "")
	greed.plugin.cleanup(registry.set(ways, string.lower(bare), how))
end

-- Whether the file at `path` starts as a program does (ELF, Mach-O, a
-- Windows .exe, a script's #!), whatever it's called.
local function runs(path: string): boolean
	local head = greed.fs.read(path, 4) or ""
	return string.sub(head, 1, 2) == "#!"
		or string.sub(head, 1, 2) == "MZ"
		or head == "\127ELF"
		or head == "\207\250\237\254"
		or head == "\206\250\237\254"
		or head == "\254\237\250\207"
		or head == "\202\254\186\190"
end

--- How `path` would open, and in words: "viewer" (a plugin shows it, as a
--- PDF's pages), "text", "outside" (another program), "binary" (nothing
--- here shows it: save it, or open it outside) or "refused" (a program,
--- which only saves). `mime`, when known, says what it is before the file
--- is there to look at.
function M.opening(
	path: string,
	mime: string?
): ("viewer" | "text" | "outside" | "binary" | "refused", string)
	local ext = extension(path)
	local way = ways[ext]
	local program = PROGRAMS[ext] == true
	local function is_text(): boolean
		if mime then
			local m = string.lower(mime)
			return string.match(m, "^text/") ~= nil
				or string.match(m, "[/+]json$") ~= nil
				or string.match(m, "[/+]xml$") ~= nil
		end
		-- One that isn't there yet is a new file, written as text.
		local head = greed.fs.read(path, 8192)
		return head == nil or not string.find(head, "\0", 1, true)
	end
	local out = type(way) == "table" or way == "outside" or (way == nil and DOCUMENTS[ext] == true)
	if out and not program then
		return "outside",
			if type(way) == "table" then `opens with {way[1]}` else "opens outside Greed"
	elseif opener_for(path) then
		return "viewer", "opens in Greed"
	elseif is_text() then
		return "text", "opens in Greed as text"
	elseif program then
		return "refused", "a program: it's saved, never opened"
	end
	return "binary", "Greed can't show it: save it, or open it outside"
end

--- Hands the file at `path` to the program that opens it outside Greed
--- (`open_with`'s, or the system's opener), unless it's a program itself.
function M.open_outside(path: string)
	path = project.resolve(path)
	local ext = extension(path)
	if PROGRAMS[ext] or runs(path) then
		greed.echo(`not opening {project.short(path)} outside: it's a program`)
		return
	end
	local way = ways[ext]
	outside(`file://{text.percent_encode(path, "/")}`, if type(way) == "table" then way else nil)
end

--- Shows the file at `path` in the main view and focuses it: as its
--- opener shows it (an image, a PDF), otherwise as text; or hands it to
--- the program that opens it, as `opening` says.
function M.open(path: string)
	-- A relative path is from the project you're in, as in the picker.
	path = project.resolve(path)
	local how, says = M.opening(path)
	if how == "outside" then
		M.open_outside(path)
		return
	elseif how == "refused" or how == "binary" then
		greed.echo(`not opening {project.short(path)}: {says}`)
		return
	end
	local opener = if how == "viewer" then opener_for(path) else nil
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
	needs = "proc",
	doc = 'What opens a link, e.g. "firefox"; empty for xdg-open, or open on macOS',
	default = "",
})

-- The kinds of links the system's opener gets. Others, like file:// (which
-- macOS's open runs when it's a program), could come from any file you
-- read, so they aren't opened.
local OPENED = { http = true, https = true, mailto = true }

-- What opens links of a scheme in Greed, by scheme.
local schemes: { [string]: (uri: string) -> () } = {}

--- Makes `open` open links of `scheme` (like "mail" for mail:ID) in Greed
--- rather than outside, until the plugin that called this goes.
function M.link_scheme(scheme: string, open: (uri: string) -> ())
	greed.plugin.cleanup(registry.set(schemes, string.lower(scheme), open))
end

--- Opens the web page at `path`, one a plugin wrote (like mail laid out
--- to load nothing), in the browser, as links open outside Greed. Only an
--- .html file: the system's opener runs a program it's given.
function M.open_page(path: string)
	if not string.match(string.lower(path), "%.html?$") then
		greed.echo(`not opening {path}: only a web page opens in the browser`)
		return
	end
	outside(`file://{text.percent_encode(path, "/")}`)
end

--- Opens `uri`: a link of a scheme a plugin opens (`link_scheme`) with
--- that plugin, a web or mail address with the link-opener option or the
--- system's opener, and a file:// link as the file here. Says why when it
--- can't.
function M.open_link(uri: string)
	local scheme = string.lower(string.match(uri, "^(%a[%w+.-]*):") or "")
	local path = if scheme == "file" then string.match(uri, "^%a+://(/.*)$") else nil
	local own = schemes[scheme]
	if own then
		own(uri)
		return
	elseif path then
		M.open(text.percent_decode(path))
		return
	elseif not OPENED[scheme] then
		greed.echo(`not opening {uri}: only http, https and mailto links open from Greed`)
		return
	end
	outside(uri)
end

greed.command({
	name = "open",
	doc = "Open a file in the main view",
	args = {
		{
			name = "path",
			doc = "The file to open; a new one is created when saved",
			complete = "file",
			type = "string",
			optional = true,
		},
	},
	run = function(ctx)
		local path: string? = ctx.values.path
		if path == nil and ctx.force then
			-- :e! loads the file again, as in Vim.
			greed.run("reload")
			return
		elseif path == nil then
			error("open needs a path, e.g. :open src/main.rs", 0)
		end
		local info = greed.fs.stat(project.resolve(path))
		if info and info.kind == "dir" then
			error(`{path} is a folder: space f finds a file, space e shows the tree`, 0)
		end
		M.open(path)
	end,
})

-- What views showing `closing` show instead: the file in the same project
-- you were in last, as editors go back to the one before, else the one
-- opened last, or an empty buffer.
local function replacement(closing: greed.Buffer): greed.Buffer
	for _, buffer in recent.buffers() do
		if buffer ~= closing and buffer:path() and buffer:project() == closing:project() then
			return buffer
		end
	end
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
			`unsaved changes in {project.name(buffer)} - :w saves, and ! after the command closes anyway`,
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
	-- Showing another in its place may have closed it already, as it does
	-- an untitled buffer nothing was typed in.
	if buffer:valid() then
		buffer:close()
	end
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
				if unsaved.unsaved(buffer) then
					table.insert(found, buffer)
				end
			end
			if #found > 0 then
				error(`unsaved changes in {names(found)} - :bco! closes anyway`, 0)
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

--- A function giving the view the user is in among those whose buffer
--- `wanted` says yes to, for things typed elsewhere (an agent's pane, a
--- shell) that are about it: the focused one when wanted, else the tab's
--- active pane, else the last wanted one that had focus. Nil when none is.
function M.view_where(wanted: (greed.Buffer) -> boolean): () -> greed.View?
	-- The last wanted view that had focus.
	local last: greed.View? = nil

	local function fits(view: greed.View?): boolean
		if view == nil then
			return false
		end
		-- A closed view fails when asked anything.
		local ok, yes = pcall(function(): boolean
			return wanted(view:buffer())
		end)
		return ok and yes
	end

	greed.on("view.focused", function(event: greed.ViewFocused)
		if fits(event.view) then
			last = event.view
		elseif fits(event.from) then
			last = event.from
		end
	end)

	return function(): greed.View?
		local focused = greed.view()
		if fits(focused) then
			return focused
		end
		local active = greed.tab.current().active
		if fits(active) then
			return active
		end
		return if fits(last) then last else nil
	end
end

--- The view with the file the user is in (see `view_where`). Nil when none
--- shows a file.
M.view = M.view_where(function(buffer: greed.Buffer): boolean
	return buffer:path() ~= nil
end)

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

-- What's told of each file or folder written, moved or removed here.
local changed_listeners: { (path: string, to: string?) -> () } = {}

--- Calls `listener` with the full path of each file or folder `M.write`,
--- `M.rename` (both ends) and `M.remove` changed, once it has, for what
--- keeps something worked out from files, like the notes' index. It goes
--- when the plugin that added it does. For the old end of a rename, `to`
--- is where it went.
function M.on_changed(listener: (path: string, to: string?) -> ())
	greed.plugin.cleanup(registry.put(changed_listeners, listener))
end

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
		registry.tell(changed_listeners, full)
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
	registry.tell(changed_listeners, full)
	return nil
end

--- Moves the file or folder at `from` to `to` (full paths), taking the
--- buffers showing what's in it along. Refuses if `to` is there already, or
--- a buffer in it has unsaved changes.
function M.rename(from: string, to: string)
	if greed.fs.stat(to) then
		error(`{project.short(to)} is there already`, 0)
	end
	local moving: { { buffer: greed.Buffer, path: string } } = {}
	for _, buffer in greed.buffers() do
		local path = buffer:path()
		if path and project.inside(path, from) then
			if unsaved.unsaved(buffer) then
				error(`{project.name(buffer)} has unsaved changes: save or undo them first`, 0)
			end
			table.insert(moving, { buffer = buffer, path = to .. string.sub(path, #from + 1) })
		end
	end
	local parent = string.match(to, "^(.*)/[^/]+$")
	if parent then
		greed.fs.mkdir(parent)
	end
	local ok, err = greed.fs.rename(from, to)
	if not ok then
		error(err, 0)
	end
	-- Each buffer becomes the file at its new place: writing what it holds
	-- there, which is what was moved.
	for _, move in moving do
		move.buffer:save(move.path)
	end
	registry.tell(changed_listeners, from, to)
	registry.tell(changed_listeners, to)
end

greed.option.define({
	name = "trash",
	doc = "Deleting a file or folder moves it to the trash, where there is one on the same disk",
	default = true,
})

-- `path` in a Trash Info file's Path line: bytes outside the safe ones
-- percent-encoded.
local function trash_path(path: string): string
	return text.percent_encode(path, "/")
end

--- Moves the file or folder at `path` to the trash: `~/.Trash` on macOS,
--- the freedesktop trash (`Trash` beside Greed's data folder, so
--- `~/.local/share/Trash` or under `XDG_DATA_HOME`, with a note of where it
--- came from) elsewhere. Returns where it went, or nil and why not, as
--- when the trash is on another disk.
function M.trash(path: string): (string?, string?)
	local dirs = greed.fs.dirs()
	local home = dirs.home
	if home == nil or home == "" then
		return nil, "no home folder to keep a trash in"
	end
	local mac = greed.fs.stat(`{home}/.Trash`)
	local files: string, info: string?
	if mac and mac.kind == "dir" and greed.which("osascript") then
		files, info = `{home}/.Trash`, nil
	else
		local share = if dirs.data then string.match(dirs.data, "^(.*)/[^/]+$") else nil
		local trash = `{share or home .. "/.local/share"}/Trash`
		files, info = `{trash}/files`, `{trash}/info`
	end
	greed.fs.mkdir(files)
	if info then
		greed.fs.mkdir(info)
	end
	-- A name nothing in the trash has yet.
	local name = project.basename(path) or "deleted"
	local taken, n = name, 1
	local function used(as: string): boolean
		return greed.fs.stat(`{files}/{as}`) ~= nil
			or (info ~= nil and greed.fs.stat(`{info}/{as}.trashinfo`) ~= nil)
	end
	while used(taken) do
		n += 1
		taken = `{name}.{n}`
	end
	local note = if info then `{info}/{taken}.trashinfo` else nil
	if note then
		local when = os.date("%Y-%m-%dT%H:%M:%S") :: string
		greed.fs.write(note, `[Trash Info]\nPath={trash_path(path)}\nDeletionDate={when}\n`)
	end
	local to = `{files}/{taken}`
	local ok, err = greed.fs.rename(path, to)
	if not ok then
		if note then
			greed.fs.remove(note)
		end
		return nil, err
	end
	return to, nil
end

--- Deletes the file or folder (and what's in it) at `path`, closing the
--- buffers showing what was there. With the `trash` option on, it goes to
--- the trash where it can (see `trash`); returns where it went there, or
--- nil when it was deleted for good.
function M.remove(path: string): string?
	local info = greed.fs.stat(path)
	if info == nil then
		error(`there's nothing at {path}`, 0)
	end
	local trashed = if greed.option.get("trash") == true then M.trash(path) else nil
	if trashed == nil then
		local ok, err = greed.fs.remove(path, { recursive = info.kind == "dir" })
		if not ok then
			error(err, 0)
		end
	end
	for _, buffer in greed.buffers() do
		local at = buffer:path()
		if at and project.inside(at, path) then
			M.close(buffer, true)
		end
	end
	registry.tell(changed_listeners, path)
	return trashed
end

--- Asks to press y before deleting `path`, so only you can confirm it (keys
--- a plugin feeds don't answer). Says whether it was deleted.
function M.confirm_remove(path: string): boolean
	local info = greed.fs.stat(path)
	local what = if info and info.kind == "dir" then "the folder" else "the file"
	greed.echo(`delete {what} {project.short(path)}? y deletes it, anything else keeps it`)
	local key = greed.next_key()
	greed.echo("")
	if key ~= "y" then
		greed.echo("kept")
		return false
	end
	local trashed = M.remove(path)
	greed.echo(
		if trashed
			then `moved {project.short(path)} to the trash`
			else `deleted {project.short(path)}`
	)
	return true
end

greed.command({
	name = "file-rename",
	doc = "Rename or move this file: a name alone keeps it in its folder, a path is from the project",
	args = { { name = "to", doc = "The new name, or a path", complete = "file", type = "string" } },
	run = function(ctx)
		local from = ctx.buffer:path()
		local to: string = ctx.values.to
		if from == nil then
			error("this buffer has no file to rename; :w saves it as one", 0)
		end
		local full = if string.find(to, "/", 1, true)
			then project.resolve(to)
			else (string.match(from, "^(.*)/[^/]+$") or "") .. "/" .. to
		M.rename(from, full)
		greed.echo(`renamed to {project.short(full)}`)
	end,
})

greed.command({
	name = "file-delete",
	doc = "Delete this file from the disk, after you press y, and close it",
	run = function(ctx)
		local path = ctx.buffer:path()
		if path == nil then
			error("this buffer has no file to delete", 0)
		end
		M.confirm_remove(path)
	end,
})

return M
