-- Git's staging area: staging a file as a given text, so one change can be
-- staged at a time, and the staged view (`space g S`), a diff of what's
-- staged where `u` unstages the hunk under the cursor and `c` commits.
local greed = require("@greed")
local core = require("@core")
local diffs = require("./diffs")
local multibuffer = require("@multibuffer")
local repos = require("./repo")

type Repo = repos.Repo

local M = {}

-- Runs git `args` in `repo` with `stdin`; its output, or nil and why.
local function git(repo: Repo, args: { string }, stdin: string?): (string?, string?)
	local done, err = greed.process.run(
		{ "git", table.unpack(args) },
		{ cwd = repo.root, stdin = stdin }
	)
	if done == nil or done.code ~= 0 then
		return nil, string.match(if done then done.stderr else err or "", "^%s*(.-)%s*$")
	end
	return done.stdout, nil
end

--- Stages the file at `relative` in `repo` as `text`, whatever the file
--- holds. Returns false and why when git refuses.
function M.stage(repo: Repo, relative: string, text: string): (boolean, string?)
	local listed = git(repo, { "ls-files", "-s", "--", relative }) or ""
	local mode = string.match(listed, "^(%d+)") or "100644"
	local hash, err = git(repo, { "hash-object", "-w", "--stdin" }, text)
	if hash == nil then
		return false, err
	end
	local _, why = git(repo, {
		"update-index",
		"--add",
		"--cacheinfo",
		`{mode},{string.match(hash, "%x+")},{relative}`,
	})
	return why == nil, why
end

type Staged = { repo: Repo, buffer: greed.Buffer }

-- Staged views by their buffer's id.
local views: { [number]: Staged } = {}

local function fill(staged: Staged)
	local text = git(staged.repo, { "diff", "--cached", "--no-color" }) or ""
	diffs.fill(staged.buffer, if text == "" then "nothing staged\n" else text)
end

--- Shows what's staged in the git repository the project is in, in the
--- results panel.
function M.show()
	local repo = repos.repo_of(greed.project.current().root .. "/.")
	if repo == nil or repo.kind ~= "git" then
		greed.echo("staging is git's; with jj, split a change in the change stack (space g l)")
		return
	end
	local buffer = diffs.buffer("staged-diff", "")
	local staged: Staged = { repo = repo, buffer = buffer }
	views[buffer:id()] = staged
	fill(staged)
	multibuffer.show(buffer, "Staged")
end

-- The staged view `ctx` is in.
local function here(ctx: greed.Context): Staged?
	return views[ctx.buffer:id()]
end

greed.command({
	name = "staged",
	doc = "Show what's staged for the next git commit, to unstage hunks or commit",
	run = M.show,
})

greed.command({
	name = "staged-unstage",
	doc = "Unstage the hunk under the cursor",
	run = function(ctx)
		local staged = here(ctx)
		if staged == nil then
			return
		end
		local line = ctx.buffer:line_of(ctx.view:cursor())
		local patch = diffs.hunk_patch(ctx.buffer:text(), line)
		if patch == nil then
			greed.echo("no hunk here")
			return
		end
		local _, why = git(staged.repo, { "apply", "--cached", "-R", "-" }, patch)
		if why then
			greed.echo(`can't unstage: {why}`)
		end
		fill(staged)
		local pos = ctx.buffer:line_start(math.min(line, ctx.buffer:line_count() - 1))
		ctx.view:set_cursor(pos)
	end,
})

greed.command({
	name = "staged-commit",
	doc = "Commit what's staged",
	run = function(ctx)
		local staged = here(ctx)
		if staged == nil then
			return
		end
		local message = core.prompt.ask("Commit message")
		if message == nil or message == "" then
			return
		end
		local _, why = git(staged.repo, { "commit", "-q", "-m", message })
		greed.echo(if why then `can't commit: {why}` else "committed")
		fill(staged)
	end,
})

greed.command({
	name = "staged-refresh",
	doc = "Read what's staged again",
	run = function(ctx)
		local staged = here(ctx)
		if staged then
			fill(staged)
		end
	end,
})

greed.on("buffer.closed", function(event: greed.BufferClosed)
	views[event.id] = nil
end)

for _, mode in { "normal", "vim", "edit" } do
	greed.keymap.bind({ mode = mode, kind = "staged-diff" }, {
		u = "staged-unstage",
		c = "staged-commit",
		r = "staged-refresh",
		q = "multibuffer-close",
	})
end

return M
