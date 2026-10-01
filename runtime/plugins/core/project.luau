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

local kern = require("@kern")

local M = {}

--- Files or folders that mark a project's root, checked in order in each
--- folder going up.
M.markers = { ".jj", ".git" }

local function absolute(path: string): string
	return if string.sub(path, 1, 1) == "/" then path else kern.fs.cwd() .. "/" .. path
end

local function parent(dir: string): string?
	local up = string.match(dir, "^(.*)/[^/]*$")
	return if up == nil or dir == "/" then nil elseif up == "" then "/" else up
end

--- The root of the project `path` (a file or folder) is in: the nearest
--- folder up holding a marker, or the folder itself when none does.
--- Without a path, the current buffer's file is used, or else the shown
--- project's root.
function M.root(path: string?): string
	local start = path or kern.view():buffer():path()
	if start == nil then
		return kern.project.current().root
	end
	local first = absolute(start)
	local info = kern.fs.stat(first)
	local folder = if info and info.kind == "dir" then first else parent(first)
	local dir = folder
	while dir do
		for _, marker in M.markers do
			if kern.fs.stat(dir .. "/" .. marker) then
				return dir
			end
		end
		dir = parent(dir)
	end
	return folder or kern.project.current().root
end

-- How many recent projects are remembered.
local RECENT = 30

-- A list of folders kept in the cache, one per line, as `name`.
local function list_file(name: string): string?
	local cache = kern.fs.dirs().cache
	return if cache then `{cache}/{name}` else nil
end

local function read_list(name: string): { string }
	local file = list_file(name)
	local text = file and kern.fs.read(file)
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
	kern.fs.write(file, table.concat(roots, "\n") .. "\n")
end

--- The roots of projects opened lately, newest first, from any session.
function M.recent(): { string }
	return read_list("recent-projects")
end

local function remember(root: string)
	add_to_list("recent-projects", root, RECENT)
end

--- The roots of projects whose own config (`.kern/init.luau`) you trusted.
function M.trusted(): { string }
	return read_list("trusted-projects")
end

-- Runs the config in project `root`'s `.kern` folder if it has one and it's
-- trusted, or says how to trust it.
local function run_config(root: string)
	local dir = `{root}/.kern`
	if kern.fs.stat(`{dir}/init.luau`) == nil then
		return
	end
	if not table.find(M.trusted(), root) then
		kern.echo(`{root} has its own Kern config in .kern/ - :trust runs it`)
		return
	end
	local name = string.match(root, "([^/]+)$") or root
	local ok, err = pcall(kern.plugin.load, dir, `project/{name}`)
	if not ok then
		kern.echo(`project config: {err}`)
	end
end

--- Shows the project `path` (a file or folder) is in, opening it if it
--- isn't open yet. Returns its id.
function M.open(path: string): number
	local root = M.root(path)
	remember(root)
	for _, project in kern.project.list() do
		if project.root == root then
			kern.project.switch(project.id)
			return project.id
		end
	end
	local id = kern.project.open(root)
	run_config(root)
	return id
end

--- The files in the shown project that have unsaved changes.
function M.unsaved(): { string }
	local current = kern.project.current().id
	local unsaved = {}
	for _, buffer in kern.buffers() do
		if buffer:project() == current and buffer:kind() == "file" and buffer:modified() then
			table.insert(unsaved, buffer:path() or "an unnamed buffer")
		end
	end
	return unsaved
end

--- `path`, relative to `root`, as a path to open: relative to the
--- starting directory when the root is inside it, so files opened from a
--- search and from the file picker are the same buffer.
function M.path(root: string, path: string): string
	local cwd = kern.fs.cwd()
	if root == cwd then
		return path
	elseif string.sub(root, 1, #cwd + 1) == cwd .. "/" then
		return string.sub(root, #cwd + 2) .. "/" .. path
	end
	return root .. "/" .. path
end

kern.command({
	name = "project",
	doc = "Open a project, or switch to it if it's open",
	args = { { name = "path", doc = "A folder or file in the project", complete = "file" } },
	run = function(ctx)
		local path = ctx.args[1]
		if path == nil then
			error("project needs a path, e.g. :project ~/src/kern; space P picks an open one", 0)
		end
		M.open(path)
	end,
})

kern.command({
	name = "project-close",
	doc = "Close the shown project, unless it has unsaved changes (force closes anyway)",
	run = function(ctx)
		local unsaved = M.unsaved()
		if #unsaved > 0 and not ctx.force then
			error("unsaved changes in " .. table.concat(unsaved, ", "), 0)
		end
		if not kern.project.close(kern.project.current().id) then
			error("this is the only project open; :q quits", 0)
		end
	end,
})

kern.command({
	name = "session",
	doc = "Go to another session: a running one by name, or a project's (started if needed)",
	args = { { name = "to", doc = "A session's name, or a folder or file", complete = "file" } },
	run = function(ctx)
		local to = ctx.args[1]
		if to == nil then
			error("session needs a name or a path; space P picks one", 0)
		end
		for _, session in kern.session.list() do
			if session.name == to then
				kern.session.switch({ name = to })
				return
			end
		end
		kern.session.switch({ path = to })
	end,
})

kern.command({
	name = "trust",
	doc = "Trust the shown project's own config in .kern/, and run it now and whenever it opens",
	run = function()
		local root = kern.project.current().root
		if kern.fs.stat(`{root}/.kern/init.luau`) == nil then
			error(`{root} has no .kern/init.luau to trust`, 0)
		end
		add_to_list("trusted-projects", root, math.huge)
		run_config(root)
	end,
})

kern.command({
	name = "project-config",
	doc = "Run the shown project's own config in .kern/, if you trusted it",
	run = function()
		run_config(kern.project.current().root)
	end,
})

-- `kern FILE` or `kern FOLDER` in a session that's already running: show
-- that project, and the file if it's one.
kern.on("client.attached", function(event: kern.ClientAttached)
	local path = event.path
	if path == nil then
		return
	end
	M.open(path)
	local info = kern.fs.stat(path)
	if info == nil or info.kind == "file" then
		kern.open(path)
	end
end)

return M
