-- Projects: the folders being worked on. The editor can have several open,
-- each with its own main view and panels; `:project PATH` opens one (or
-- switches to it), `:project-close` closes the shown one, and `space P`
-- picks between them.
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

--- Shows the project `path` (a file or folder) is in, opening it if it
--- isn't open yet. Returns its id.
function M.open(path: string): number
	local root = M.root(path)
	for _, project in kern.project.list() do
		if project.root == root then
			kern.project.switch(project.id)
			return project.id
		end
	end
	return kern.project.open(root)
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

return M
