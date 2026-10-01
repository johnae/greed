-- What a project is: the nearest folder, from the current file up, holding
-- one of `markers`. Without one, it's the directory Kern started in.
--
-- Change the markers from your config, e.g. to stop at Rust workspaces:
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

--- The root of the project `path` (a file or folder) is in. Without a
--- path, the current buffer's file is used, or the starting directory.
function M.root(path: string?): string
	local start = path or kern.view():buffer():path()
	local first = if start then absolute(start) else kern.fs.cwd()
	local info = kern.fs.stat(first)
	local dir: string? = if info and info.kind ~= "dir" then parent(first) else first
	while dir do
		for _, marker in M.markers do
			if kern.fs.stat(dir .. "/" .. marker) then
				return dir
			end
		end
		dir = parent(dir)
	end
	return kern.fs.cwd()
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

return M
