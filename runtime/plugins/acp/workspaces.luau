-- Workspaces of their own for agents: a jj workspace or a git worktree
-- outside the project, what the agent changed there, and bringing that
-- into your working copy.

local greed = require("@greed")
local core = require("@core")
local vcs = require("@vcs")
local session = require("./session")

type Session = session.Session
type Workspace = session.Workspace

local M = {}

-- Runs jj or git, as `kind` says, with `args` in `dir`, taking in what
-- changed in the files there. What it printed, or nil and why it failed.
local function run(kind: "jj" | "git", dir: string, args: { string }): (string?, string?)
	return vcs.repo.run({ kind = kind, root = dir }, args, true)
end

--- Runs jj or git with `args` in the workspace `ws`, taking in what the
--- agent wrote there. What it printed, or nil and why it failed.
function M.run(ws: Workspace, args: { string }): (string?, string?)
	return run(ws.kind, ws.path, args)
end

--- A workspace of its own for an agent `agent` runs, outside the project
--- at `root`: from your working copy's parent, or from `from`'s working
--- copy, edits and all, for a fork.
function M.make(root: string, agent: string, from: Workspace?): (Workspace?, string?)
	local repo = vcs.repo.repo_of(root .. "/.")
	if repo == nil then
		return nil, "the project isn't in a jj or git repository"
	end
	local base = greed.fs.dirs().cache or core.project.clean(root .. "/..")
	local project = string.match(root, "([^/]+)/*$") or "project"
	greed.fs.mkdir(`{base}/workspaces`)
	-- Earlier sessions' workspaces may still be there to take up again.
	local n, name, path = 0, "", ""
	repeat
		n += 1
		name = `greed-{agent}-{n}`
		path = `{base}/workspaces/{project}-{name}`
	until not greed.fs.stat(path)
	if repo.kind == "jj" then
		local args = { "workspace", "add", "--name", name, path }
		if from then
			-- Any jj command there takes in what the agent wrote since.
			M.run(from, { "status" })
			table.insert(args, "-r")
			table.insert(args, `{from.name}@`)
		end
		local _, err = run("jj", root, args)
		if err then
			return nil, err
		end
		return { kind = "jj", name = name, path = path }, nil
	end
	local start = if from then `greed/{from.name}` else "HEAD"
	local head = run("git", root, { "rev-parse", "HEAD" })
	local _, err = run("git", root, { "worktree", "add", "-q", "-b", `greed/{name}`, path, start })
	if err then
		return nil, err
	end
	local based = if from then from.base else head and string.match(head, "%x+")
	return { kind = "git", name = name, path = path, base = based }, nil
end

M.IN_PROJECT = "it works in the project itself; its changes are already there"

--- What `s` changed in its workspace, as a diff.
function M.changes(s: Session): (string?, string?)
	local ws = s.workspace
	if ws == nil then
		return nil, M.IN_PROJECT
	elseif ws.kind == "jj" then
		-- Run in the workspace, so jj sees what the agent wrote since.
		return M.run(ws, { "diff", "--git", "--color", "never" })
	end
	-- Untracked files count too.
	M.run(ws, { "add", "-A", "-N" })
	return M.run(ws, { "diff", ws.base or "HEAD" })
end

--- Brings what `s` changed in its workspace into yours: with jj its change
--- is squashed into your working copy, with git its diff is applied.
function M.bring(s: Session): (boolean, string?)
	local ws = s.workspace
	if ws == nil then
		return false, M.IN_PROJECT
	elseif ws.kind == "jj" then
		-- Any jj command in the workspace takes in what the agent wrote.
		M.run(ws, { "status" })
		local _, err = run("jj", s.root, { "squash", "--from", `{ws.name}@`, "--into", "@" })
		if err then
			return false, err
		end
		-- Its change is empty now; its files follow.
		M.run(ws, { "workspace", "update-stale" })
		return true, nil
	end
	local patch, err = M.changes(s)
	if patch == nil then
		return false, err
	elseif patch == "" then
		return false, "nothing changed"
	end
	local done = greed.process.run(
		{ "git", "apply", "--3way", "-" },
		{ cwd = s.root, stdin = patch }
	)
	if done == nil or done.code ~= 0 then
		return false, done and string.match(done.stderr, "^%s*(.-)%s*$")
	end
	return true, nil
end

--- Removes the workspace of `s`, if it has one.
function M.remove(s: Session)
	local ws = s.workspace
	if ws == nil then
		return
	elseif ws.kind == "jj" then
		run("jj", s.root, { "workspace", "forget", ws.name })
		greed.fs.remove(ws.path, { recursive = true })
	else
		run("git", s.root, { "worktree", "remove", "--force", ws.path })
		run("git", s.root, { "branch", "-D", `greed/{ws.name}` })
	end
end

return M
