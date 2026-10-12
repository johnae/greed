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
	local project = core.project.basename(root) or "project"
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

--- What an agent in `ws`, a workspace of its own for the project at `root`,
--- needs to know about it: where it is, and how what it does there gets
--- to the user, so it keeps its work where that finds it.
function M.note(ws: Workspace, root: string): string
	local lines = {
		`You work in a workspace of your own at {ws.path}, a copy of the project at {root}; `
			.. "paths are relative to it. Change files only there: the user's own files stay as "
			.. "they are until they bring your work in. The editor context shows the user's copy; "
			.. "the same relative path is in your workspace.",
	}
	if ws.kind == "jj" then
		table.insert(
			lines,
			`It's the jj workspace {ws.name}, started from the parent of the user's working copy, `
				.. "so it doesn't have changes they haven't committed. Keep all your work in its "
				.. `working-copy change ({ws.name}@): the user brings that one change in, squashed `
				.. "into theirs. Don't run jj new, commit, squash, edit, rebase, abandon or "
				.. "restore, and leave other changes and bookmarks alone; jj describe is fine."
		)
	else
		table.insert(
			lines,
			`It's a git worktree on the branch greed/{ws.name}, started from the user's last `
				.. "commit, so it doesn't have changes they haven't committed. Commit there or "
				.. "not as you like; the user brings in everything that differs from where you "
				.. "started. Don't switch branches, rebase, merge, reset or push."
		)
	end
	table.insert(
		lines,
		"When you're done, say what you changed and that it's ready: the user reviews it from "
			.. "the session list (space i l: d shows the diff, R reviews it change by change, b "
			.. "brings it in). Don't bring it in yourself or copy files into their project."
	)
	return table.concat(lines, " ")
end

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

--- The files `s` changed in its workspace, relative to it, and how to get
--- one's text as the agent started from it ("" for a file it added).
function M.changed(s: Session): ({ string }?, ((string) -> string)?, string?)
	local ws = assert(s.workspace)
	local names: string?
	local base: (string) -> string
	if ws.kind == "jj" then
		names = M.run(ws, { "diff", "--name-only" })
		base = function(path)
			return M.run(ws, { "file", "show", "-r", "@-", "--", path }) or ""
		end
	else
		M.run(ws, { "add", "-A", "-N" })
		local from = ws.base or "HEAD"
		names = M.run(ws, { "diff", "--name-only", from })
		base = function(path)
			return M.run(ws, { "show", `{from}:{path}` }) or ""
		end
	end
	if names == nil then
		return nil, nil, `can't read what {s.name} changed`
	end
	local listed = names :: string
	local list = {}
	for _, name in string.split(listed, "\n") do
		if name ~= "" then
			table.insert(list, name)
		end
	end
	return list, base, nil
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
		local args = { "squash", "--from", `{ws.name}@`, "--into", "@" }
		-- With both described, jj would open an editor to join them; yours stays.
		local yours = run("jj", s.root, { "log", "-r", "@", "--no-graph", "-T", "description" })
		if yours and string.match(yours, "%S") then
			table.insert(args, "--use-destination-message")
		end
		local _, err = run("jj", s.root, args)
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

--- Removes the workspace of `s` (a session, or one kept from before), if
--- it has one.
function M.remove(s: { root: string, workspace: Workspace? })
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
