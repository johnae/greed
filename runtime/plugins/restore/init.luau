-- Session restore: a session remembers its projects, the files open in
-- each and where the cursor was, and opens them again when it starts.
-- Written down when it quits and when a file is saved, per session name in
-- the cache, so it only works for editors running as a session (which
-- `kern` is, unless GREED_NO_SESSION is set).

local kern = require("@kern")

kern.option.define({
	name = "restore-session",
	doc = "Open the files a session had open when it starts again",
	default = true,
})

type Project = {
	root: string,
	files: { string },
	shown: string?,
	cursor: number?,
}

type Saved = {
	current: string?,
	projects: { Project },
}

local M = {}

--- The session whose files are remembered; nil when the editor isn't one.
function M.name(): string?
	return kern.session.current()
end

local function file(): string?
	local name = M.name()
	local cache = kern.fs.dirs().cache
	if name == nil or cache == nil then
		return nil
	end
	return `{cache}/sessions/{name}.json`
end

local function absolute(path: string): string
	return if string.sub(path, 1, 1) == "/" then path else `{kern.fs.cwd()}/{path}`
end

-- What each project's main view showed when it was last the shown one, by
-- root: only the shown project's main view can be asked.
local shown: { [string]: { path: string, cursor: number } } = {}

--- Writes down the open projects and files.
function M.save()
	local path = file()
	if path == nil or kern.option.get("restore-session") ~= true then
		return
	end
	local current = kern.project.current()
	local view = kern.view()
	local main = view:buffer():path()
	if main then
		shown[current.root] = { path = absolute(main), cursor = view:selection().ranges[1].head }
	end
	local projects: { Project } = {}
	local by_id: { [number]: Project } = {}
	for _, info in kern.project.list() do
		local last = shown[info.root]
		local project: Project = {
			root = info.root,
			files = kern.json.array({} :: { string }),
			shown = last and last.path,
			cursor = last and last.cursor,
		}
		table.insert(projects, project)
		by_id[info.id] = project
	end
	for _, buffer in kern.buffers() do
		local p = buffer:path()
		local project = by_id[buffer:project() or current.id]
		if p and project and buffer:kind() == "file" then
			table.insert(project.files, absolute(p))
		end
	end
	for _, project in projects do
		table.sort(project.files)
	end
	kern.fs.write(
		path,
		kern.json.encode({ current = current.root, projects = kern.json.array(projects) })
	)
end

local function read(): Saved?
	local path = file()
	local text = path and kern.fs.read(path)
	if text == nil then
		return nil
	end
	local saved = kern.json.decode(text)
	return if type(saved) == "table" and type(saved.projects) == "table" then saved else nil
end

local function project_id(root: string): number?
	for _, info in kern.project.list() do
		if info.root == root then
			return info.id
		end
	end
	return nil
end

-- Opens `project`'s files in it, and shows the one it showed if its main
-- view has nothing else to show.
local function reopen(project: Project)
	local before = kern.view():buffer():path()
	for _, path in project.files do
		if kern.fs.stat(path) then
			kern.open(path)
		end
	end
	if before then
		kern.open(before)
	elseif project.shown and kern.fs.stat(project.shown) then
		local view = kern.view()
		kern.open(project.shown)
		local pos = math.min(project.cursor or 0, view:buffer():len())
		view:set_selection({ ranges = { { anchor = pos, head = pos } }, primary = 1 })
		shown[project.root] = { path = project.shown, cursor = pos }
	end
end

--- Opens what `save` wrote down. A file the session was started with stays
--- shown, and its project stays the shown one.
function M.restore()
	local saved = if kern.option.get("restore-session") == true then read() else nil
	if saved == nil then
		return
	end
	local start = kern.project.current().id
	local started_with_file = kern.view():buffer():path() ~= nil
	for _, project in saved.projects do
		local id = project_id(project.root)
		if id then
			kern.project.switch(id)
		elseif kern.fs.stat(project.root) then
			kern.project.open(project.root)
		else
			continue
		end
		reopen(project)
	end
	local current = saved.current and project_id(saved.current)
	kern.project.switch(if current and not started_with_file then current else start)
end

kern.on("editor.started", M.restore)
kern.on("editor.quitting", M.save)
kern.on("buffer.saved", M.save)

return M
