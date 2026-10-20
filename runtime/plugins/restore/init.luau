-- Session restore: a session remembers its projects, the files open in
-- each and where the cursor was, and each project's tabs: their panes,
-- what those show, and the terminals in them (run again, unless what they
-- ran is risky; then a shell). It opens them again when it starts, unless
-- it was quit: then it starts clean, except with `restore-after-quit` or
-- after an upgrade. Written down when it starts and quits and when a file
-- is opened, closed or saved, per session name in the cache, so it only
-- works for editors running as a session (which `greed` is, unless
-- GREED_NO_SESSION is set).

local greed = require("@greed")
local core = require("@core")
local saved_layouts = require("@panes").saved

greed.option.define({
	name = "restore-session",
	doc = "Open the files a session had open when it starts again after it ended without being quit, as in a crash or a restart",
	default = true,
})

greed.option.define({
	name = "restore-after-quit",
	doc = "Restore a session when it starts again after it was quit, too",
	default = false,
})

type Project = {
	root: string,
	files: { string },
	shown: string?,
	cursor: number?,
	--- Its tabs, as `panes.saved` describes one, when it last was the shown
	--- project.
	tabs: { any }?,
}

type Saved = {
	current: string?,
	projects: { Project },
	--- Whether the session was quit, rather than ending some other way.
	quit: boolean?,
}

local M = {}

--- The session whose files are remembered; nil when the editor isn't one.
function M.name(): string?
	return greed.session.current()
end

--- Whether the session was started fresh, without restoring.
function M.fresh(): boolean
	return greed.session.fresh()
end

--- Whether the session was started to be restored even after a quit, as
--- for an upgrade.
function M.restoring(): boolean
	return greed.session.restoring()
end

--- Whether the session has started and restored what it would: until
--- then, opening a file doesn't write down what's open, which would lose
--- what's to be restored.
M.started = false

local function file(): string?
	local name = M.name()
	local cache = greed.fs.dirs().cache
	if name == nil or cache == nil then
		return nil
	end
	return `{cache}/sessions/{name}.json`
end

-- What each project's main view showed when it was last the shown one, by
-- root: only the shown project's main view can be asked.
local shown: { [string]: { path: string, cursor: number } } = {}

-- Each project's tabs when it was last the shown one, by root, as the
-- shown project's are the only ones that can be asked.
local tabs: { [string]: { any } } = {}

-- The shown project's tabs, described to open again.
local function shown_tabs(): { any }
	local out = {}
	for _, tab in greed.tab.list() do
		table.insert(out, saved_layouts.describe(tab.id))
	end
	return out
end

--- Writes down the open projects and files, and with `quit` that the
--- session was quit.
function M.save(quit: boolean?)
	local path = file()
	if path == nil or greed.option.get("restore-session") ~= true then
		return
	end
	local current = greed.project.current()
	local view = greed.view()
	local main = view:buffer():path()
	if main then
		shown[current.root] = { path = main, cursor = view:cursor() }
	end
	tabs[current.root] = shown_tabs()
	local projects: { Project } = {}
	local by_id: { [number]: Project } = {}
	for _, info in greed.project.list() do
		local last = shown[info.root]
		local project: Project = {
			root = info.root,
			files = greed.json.array({} :: { string }),
			shown = last and last.path,
			cursor = last and last.cursor,
			tabs = tabs[info.root],
		}
		table.insert(projects, project)
		by_id[info.id] = project
	end
	for _, buffer in greed.buffers() do
		local p = buffer:path()
		local project = by_id[buffer:project() or current.id]
		if p and project and buffer:kind() == "file" then
			table.insert(project.files, p)
		end
	end
	for _, project in projects do
		table.sort(project.files)
	end
	greed.fs.write(
		path,
		greed.json.encode({
			current = current.root,
			projects = greed.json.array(projects),
			quit = quit or nil,
		})
	)
end

local function read(): Saved?
	local path = file()
	local text = path and greed.fs.read(path)
	if text == nil then
		return nil
	end
	local saved = greed.json.decode(text)
	return if type(saved) == "table" and type(saved.projects) == "table" then saved else nil
end

local function project_id(root: string): number?
	for _, info in greed.project.list() do
		if info.root == root then
			return info.id
		end
	end
	return nil
end

-- Opens `project`'s files in it, and shows the one it showed if its main
-- view has nothing else to show.
local function reopen(project: Project)
	local before = greed.view():buffer():path()
	for _, path in project.files do
		if greed.fs.stat(path) then
			greed.open(path)
		end
	end
	if before then
		greed.open(before)
	elseif project.shown and greed.fs.stat(project.shown) then
		local view = greed.view()
		greed.open(project.shown)
		local pos = math.min(project.cursor or 0, view:buffer():len())
		view:set_cursor(pos)
		shown[project.root] = { path = project.shown, cursor = pos }
	end
end

-- `tree` (a tab, as described) with each terminal that ran something risky
-- (`core.risk`) made a plain shell, so starting again doesn't run it.
local function safe(tree: any): any
	if type(tree.children) == "table" then
		for _, child in tree.children do
			safe(child)
		end
	elseif type(tree.terminal) == "table" and core.risk.of(table.concat(tree.terminal, " ")) then
		tree.terminal = true
	end
	return tree
end

-- Opens `project`'s tabs again, the shown project being it: the first in
-- the tab shown, unless that shows a file the session was started with.
-- A single tab showing one file is what `reopen` did already.
local function reopen_tabs(project: Project, keep_shown: boolean)
	local list = project.tabs
	if list == nil or #list == 0 then
		return
	end
	local only = list[1]
	if #list == 1 and only.children == nil and only.terminal == nil then
		return
	end
	local start = greed.tab.current().id
	for i, tree in list do
		local problem = saved_layouts.open_saved(safe(tree), { here = i == 1 and not keep_shown })
		if problem then
			greed.echo(`restoring a tab: {problem}`)
		end
	end
	greed.tab.switch(start)
end

-- Opens `saved`'s projects, files and tabs. A file the session was
-- started with stays shown, and its project stays the shown one.
local function reopen_all(saved: Saved)
	local start = greed.project.current().id
	local started_with_file = greed.view():buffer():path() ~= nil
	for _, project in saved.projects do
		local id = project_id(project.root)
		if id then
			greed.project.switch(id)
		elseif greed.fs.stat(project.root) then
			greed.project.open(project.root)
		else
			continue
		end
		reopen(project)
		if project.tabs then
			tabs[project.root] = project.tabs
			reopen_tabs(project, started_with_file and id == start)
		end
	end
	local current = saved.current and project_id(saved.current)
	greed.project.switch(if current and not started_with_file then current else start)
end

--- Opens what `save` wrote down, unless the session was quit (see
--- `restore-after-quit`).
function M.restore()
	local wanted = greed.option.get("restore-session") == true and not M.fresh()
	local saved = if wanted then read() else nil
	local after_quit = greed.option.get("restore-after-quit") == true or M.restoring()
	-- Files opened along the way are written down once it's done, and what
	-- the session starts with is too, for when it ends without quitting.
	local ok, err = true, nil
	if saved and (after_quit or not saved.quit) then
		ok, err = pcall(reopen_all, saved)
	end
	M.started = true
	M.save()
	if not ok then
		error(err, 0)
	end
end

-- What's open now, for a session that ends without quitting.
local function changed()
	if M.started then
		M.save()
	end
end

greed.on("editor.started", M.restore)
greed.on("editor.quitting", function()
	M.save(true)
end)
greed.on("buffer.saved", function()
	M.save()
end)
greed.on("buffer.opened", changed)
greed.on("buffer.closed", changed)

return M
