-- Finding the repository a file is in, and running jj or git there.

local greed = require("@greed")

local M = {}

export type Repo = { kind: "jj" | "git", root: string }

local function parent(path: string): string?
	return string.match(path, "^(.*)/[^/]*$")
end

--- The repository `path` is in, if any.
function M.repo_of(path: string): Repo?
	local dir = parent(path)
	while dir and dir ~= "" do
		if greed.fs.stat(dir .. "/.jj") then
			return { kind = "jj", root = dir }
		elseif greed.fs.stat(dir .. "/.git") then
			return { kind = "git", root = dir }
		end
		dir = parent(dir)
	end
	return nil
end

--- `path` from the root, as given if it already is.
function M.absolute(path: string): string
	return if string.sub(path, 1, 1) == "/" then path else `{greed.fs.cwd()}/{path}`
end

--- The repository `buffer`'s file is in, and the file's path from its root.
function M.locate(buffer: greed.Buffer): (Repo?, string?)
	local path = buffer:path()
	local repo = path and M.repo_of(M.absolute(path))
	if path == nil or repo == nil then
		return nil, nil
	end
	return repo, string.sub(M.absolute(path), #repo.root + 2)
end

--- Runs a jj or git command in `repo`'s root and returns what it printed, or
--- nil if it failed. jj doesn't look at the files on disk unless `snapshot`
--- says to, for commands that only read what's committed.
function M.run(repo: Repo, args: { string }, snapshot: boolean?): string?
	local command: { string } = { repo.kind }
	if repo.kind == "jj" and not snapshot then
		-- Reading only: don't snapshot the working copy as a side effect.
		table.insert(command, "--ignore-working-copy")
	end
	for _, arg in args do
		table.insert(command, arg)
	end
	local done = greed.process.run(command, { cwd = repo.root })
	return if done and done.code == 0 then done.stdout else nil
end

return M
