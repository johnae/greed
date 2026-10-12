-- Projects: the folders being worked on. The editor can have several open,
-- each with its own main view and panels; `:project PATH` opens one (or
-- switches to it), `:project-close` closes the shown one, `:session` goes to
-- another session (each runs in its own process), and `space P` picks
-- between projects and sessions.
--
-- A project's root is the nearest folder, from a file up, holding one of
-- `markers`. Change them from your config, e.g. to stop at Rust workspaces:
--
--     table.insert(require("@core").project.markers, 1, "Cargo.lock")

local greed = require("@greed")
local unsaved = require("./unsaved")

local M = {}

--- Files or folders that mark a project's root, checked in order in each
--- folder going up.
M.markers = { ".jj", ".git" }

local function parent(dir: string): string?
	local up = string.match(dir, "^(.*)/[^/]*$")
	return if up == nil or dir == "/" then nil elseif up == "" then "/" else up
end

-- `path` from the folder Greed started in when it's relative.
local function absolute(path: string): string
	return if string.sub(path, 1, 1) == "/" then path else `{greed.fs.cwd()}/{path}`
end

--- The last part of `path`, its file or folder name ("main.rs" for
--- "src/main.rs", "src" for "src/"); nil when it has none, as for "/".
function M.basename(path: string): string?
	return string.match(path, "([^/]+)/*$")
end

--- `path` as a full path with `.`, `..` and doubled slashes worked out,
--- from the folder Greed started in when it's relative. Symbolic links
--- aren't followed.
function M.clean(path: string): string
	local full = absolute(path)
	local parts: { string } = {}
	for part in string.gmatch(full, "[^/]+") do
		if part == ".." then
			table.remove(parts)
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	return "/" .. table.concat(parts, "/")
end

--- Whether `path` is `folder` or inside it, once both are cleaned up
--- (`M.clean`), so "src/../../x" isn't inside "src".
function M.inside(path: string, folder: string): boolean
	local p, f = M.clean(path), M.clean(folder)
	return p == f or f == "/" or string.sub(p, 1, #f + 1) == f .. "/"
end

--- The nearest folder from `dir` up holding `marker` (a file or folder,
--- like ".git"), if one does.
function M.nearest(dir: string, marker: string): string?
	local at: string? = M.clean(dir)
	while at do
		if greed.fs.stat(at .. "/" .. marker) then
			return at
		end
		at = parent(at)
	end
	return nil
end

-- The folder standing for the project in each thread running `M.within`.
local standing_in: { [thread]: string } = setmetatable({}, { __mode = "k" }) :: any

-- The root paths go from by default: the folder `M.within` gave this
-- thread, else the shown project's.
local function base(): string
	return standing_in[coroutine.running()] or greed.project.current().root
end

--- Runs `f` with the folder `dir` standing for the project in this thread:
--- `root()` without a path, `resolve` and `relative` go from it. For an
--- agent in a workspace of its own, whose tools should see the workspace.
function M.within<T>(dir: string, f: () -> T): T
	local thread = coroutine.running()
	local before = standing_in[thread]
	standing_in[thread] = M.clean(dir)
	local ok, result = pcall(f)
	standing_in[thread] = before
	if not ok then
		error(result, 0)
	end
	return result
end

--- The root of the project `path` (a file or folder) is in: the nearest
--- folder up holding a marker, or the folder itself when none does.
--- Without a path, the current buffer's file is used, or else the shown
--- project's root; inside `within`, its folder.
function M.root(path: string?): string
	local within = if path == nil then standing_in[coroutine.running()] else nil
	if within then
		return within
	end
	local start = path or greed.view():buffer():path()
	if start == nil then
		return base()
	end
	local first = M.clean(start)
	local info = greed.fs.stat(first)
	local folder = if info and info.kind == "dir" then first else parent(first)
	local dir = folder
	while dir do
		for _, marker in M.markers do
			if greed.fs.stat(dir .. "/" .. marker) then
				return dir
			end
		end
		dir = parent(dir)
	end
	return folder or base()
end

-- The first line of the file at `path`, trimmed, if there's one.
local function first_line(path: string): string?
	local text = greed.fs.read(path)
	local line = text and string.match(text, "^%s*([^\n]*)")
	local trimmed = line and string.match(line, "^(.-)%s*$")
	return if trimmed and trimmed ~= "" then trimmed else nil
end

--- What tells the repository the folder `root` is in apart from others,
--- the same in all its jj workspaces and git worktrees: the folder its
--- store is in (jj's `.jj/repo`, git's common `.git`). Outside a
--- repository, `root` itself.
function M.identity(root: string): string
	local dir: string? = M.clean(root)
	while dir do
		if greed.fs.stat(`{dir}/.jj`) then
			local store = `{dir}/.jj/repo`
			local info = greed.fs.stat(store)
			-- A workspace's store is a file saying where the repository's is.
			local points = if info and info.kind == "file" then first_line(store) else nil
			return if points then M.resolve(points, `{dir}/.jj`) else store
		end
		local dot = `{dir}/.git`
		local info = greed.fs.stat(dot)
		if info then
			-- A worktree's .git is a file naming its folder in the
			-- repository's, and that folder says where the repository's is.
			local gitdir = if info.kind == "file" then first_line(dot) else nil
			local linked = gitdir and string.match(gitdir, "^gitdir:%s*(.+)$")
			if linked == nil then
				return dot
			end
			local folder = M.resolve(linked, dir)
			local common = first_line(`{folder}/commondir`)
			return if common then M.resolve(common, folder) else folder
		end
		dir = parent(dir)
	end
	return root
end

-- How many recent projects are remembered.
local RECENT = 30

-- A list of folders kept in the cache, one per line, as `name`.
local function list_file(name: string): string?
	local cache = greed.fs.dirs().cache
	return if cache then `{cache}/{name}` else nil
end

local function read_list(name: string): { string }
	local file = list_file(name)
	local text = file and greed.fs.read(file)
	local roots = {}
	for _, line in string.split(text or "", "\n") do
		if line ~= "" then
			table.insert(roots, line)
		end
	end
	return roots
end

-- Puts `root` first in list `name`, keeping at most `limit`.
local function add_to_list(name: string, root: string, limit: number)
	local file = list_file(name)
	if file == nil then
		return
	end
	local roots = { root }
	for _, other in read_list(name) do
		if other ~= root and #roots < limit then
			table.insert(roots, other)
		end
	end
	greed.fs.write(file, table.concat(roots, "\n") .. "\n")
end

--- The roots of projects opened lately, newest first, from any session.
function M.recent(): { string }
	return read_list("recent-projects")
end

local function remember(root: string)
	add_to_list("recent-projects", root, RECENT)
end

--- The roots of projects whose own config (`.greed/init.luau`) you trusted.
function M.trusted(): { string }
	return read_list("trusted-projects")
end

-- Runs the config in project `root`'s `.greed` folder if it has one and it's
-- trusted, or says how to trust it.
local function run_config(root: string)
	local dir = `{root}/.greed`
	if greed.fs.stat(`{dir}/init.luau`) == nil then
		return
	end
	if not table.find(M.trusted(), root) then
		greed.echo(`{root} has its own Greed config in .greed/ - :trust runs it`)
		return
	end
	local name = M.basename(root) or root
	local ok, err = pcall(greed.plugin.load, dir, `project/{name}`)
	if not ok then
		greed.echo(`project config: {err}`)
	end
end

--- Shows the project `path` (a file or folder) is in, opening it if it
--- isn't open yet. Returns its id.
function M.open(path: string): number
	local root = M.root(path)
	remember(root)
	for _, project in greed.project.list() do
		if project.root == root then
			greed.project.switch(project.id)
			return project.id
		end
	end
	local id = greed.project.open(root)
	run_config(root)
	return id
end

--- The buffers in the shown project that have unsaved changes.
function M.unsaved_buffers(): { greed.Buffer }
	local current = greed.project.current().id
	local found = {}
	for _, buffer in greed.buffers() do
		if buffer:project() == current and unsaved.unsaved(buffer) then
			table.insert(found, buffer)
		end
	end
	return found
end

--- The files in the shown project that have unsaved changes, named as
--- `name` names them.
function M.unsaved(): { string }
	local found = {}
	for _, buffer in M.unsaved_buffers() do
		table.insert(found, M.name(buffer))
	end
	return found
end

-- `path` with a leading `~` as the home folder, or nil if it has none.
local function from_home(path: string): string?
	local home = greed.fs.dirs().home
	if home and (path == "~" or string.sub(path, 1, 2) == "~/") then
		return home .. string.sub(path, 2)
	end
	return nil
end

--- A typed path as a full one: "~/src" from the home folder, "src" from the
--- folder Greed started in.
function M.expand(path: string): string
	return from_home(path) or absolute(path)
end

--- `path` as a full path: "~/x" from the home folder, a relative one from
--- `root` (default: the shown project's root), with `.`, `..` and doubled
--- slashes worked out. Agents and tools take paths relative to the project
--- this way, wherever Greed was started.
function M.resolve(path: string, root: string?): string
	local full = from_home(path) or path
	if string.sub(full, 1, 1) ~= "/" then
		full = `{root or base()}/{full}`
	end
	return M.clean(full)
end

--- `path` as shown in the project at `root` (default: the shown one):
--- relative to its root when inside it, otherwise in full.
function M.relative(path: string, root: string?): string
	local from = M.clean(root or base())
	local full = M.resolve(path, from)
	if full == from then
		return "."
	elseif from == "/" then
		return string.sub(full, 2)
	elseif string.sub(full, 1, #from + 1) == from .. "/" then
		return string.sub(full, #from + 2)
	end
	return full
end

--- The full path `path` with the home folder written as "~", as in
--- "~/src/greed".
function M.tilde(path: string): string
	local home = greed.fs.dirs().home
	if home == nil then
		return path
	elseif path == home then
		return "~"
	elseif string.sub(path, 1, #home + 1) == home .. "/" then
		return "~" .. string.sub(path, #home + 1)
	end
	return path
end

--- `path` short enough to show: relative inside the project at `root`
--- (default: the shown one), from "~" under the home folder, otherwise in
--- full.
function M.short(path: string, root: string?): string
	local shown = M.relative(path, root)
	return if string.sub(shown, 1, 1) == "/" then M.tilde(shown) else shown
end

--- A buffer's file as `short` shows it, for messages: "src/main.rs", or
--- "an unnamed buffer" without one.
function M.name(buffer: greed.Buffer): string
	local path = buffer:path()
	return if path then M.short(path) else "an unnamed buffer"
end

greed.command({
	name = "project",
	doc = "Open a project, or switch to it if it's open",
	args = {
		{
			name = "path",
			doc = "A folder or file in the project",
			complete = "file",
			type = "string",
		},
	},
	run = function(ctx)
		M.open(ctx.values.path)
	end,
})

greed.command({
	name = "project-close",
	doc = "Close the shown project, unless it has unsaved changes (force closes anyway)",
	run = function(ctx)
		local unsaved = M.unsaved()
		if #unsaved > 0 and not ctx.force then
			error("unsaved changes in " .. table.concat(unsaved, ", "), 0)
		end
		if not greed.project.close(greed.project.current().id) then
			error("this is the only project open; :q quits", 0)
		end
	end,
})

greed.command({
	name = "session",
	doc = "Go to another session: a running one by name, or a project's (started if needed)",
	args = {
		{
			name = "to",
			doc = "A session's name, or a folder or file",
			complete = "file",
			type = "string",
		},
	},
	run = function(ctx)
		local to: string = ctx.values.to
		for _, session in greed.session.list() do
			if session.name == to then
				greed.session.switch({ name = to })
				return
			end
		end
		greed.session.switch({ path = to })
	end,
})

-- When `window-new` last asked for a window: the window that attaches soon
-- after is that one, and gets a layout of its own.
local window_asked = -math.huge
local WINDOW_WAIT = 30000

greed.command({
	name = "window-new",
	doc = "Open another window on this session, laid out on its own, as a terminal's new window does; space P in it goes to another project",
	run = function()
		local name = greed.session.current()
		if name == nil or greed.client.current().kind ~= "gui" then
			greed.echo("another window opens from a window (greed --gui)")
			return
		end
		window_asked = greed.now()
		greed.session.switch({ name = name, window = true })
	end,
})

greed.on("client.attached", function(event: greed.ClientAttached)
	if greed.now() - window_asked <= WINDOW_WAIT then
		window_asked = -math.huge
		greed.client.set_layout("independent", event.client)
	end
end)

greed.keymap.bind({}, { ["ctrl-N"] = "window-new" })

greed.command({
	name = "trust",
	doc = "Trust the shown project's own config in .greed/, and run it now and whenever it opens",
	run = function()
		local root = greed.project.current().root
		if greed.fs.stat(`{root}/.greed/init.luau`) == nil then
			error(`{root} has no .greed/init.luau to trust`, 0)
		end
		add_to_list("trusted-projects", root, math.huge)
		run_config(root)
	end,
})

greed.command({
	name = "project-config",
	doc = "Run the shown project's own config in .greed/, if you trusted it",
	run = function()
		run_config(greed.project.current().root)
	end,
})

-- `greed FILE` or `greed FOLDER` in a session that's already running: show
-- that project, and the file if it's one.
greed.on("client.attached", function(event: greed.ClientAttached)
	local path = event.path
	if path == nil then
		return
	end
	M.open(path)
	local info = greed.fs.stat(path)
	if info == nil or info.kind == "file" then
		greed.open(path)
	end
end)

return M
