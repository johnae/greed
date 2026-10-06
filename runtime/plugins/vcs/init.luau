-- Version control: signs beside lines added (+), changed (~) and removed
-- (-) since the last commit, with jj, or git where there's no .jj.
--
--   ] g / [ g   next / previous change; ] G / [ G the last and first
--   m i g       the change under the cursor; m a g its lines
--   space g r   put the change under the cursor back the way it was
--   space g b   who last changed this line, and when
--   space g s   every change since the last commit, in one multibuffer
--   space u c   commit just the latest operation's files, named after it
--   space g a   stage the change under the cursor (git)
--   space g S   what's staged (git), to unstage hunks and commit
--
-- With jj the comparison is with the working copy's parent (@-), so the
-- signs show what the change you're working on does to the file. With git
-- it's with what's staged, so staged changes lose their signs.

local core = require("@core")
local greed = require("@greed")
local multibuffer = require("@multibuffer")
local operations = require("@operations")
local picker = require("@picker")
local repos = require("@self/repo")
local statusline = require("@statusline")
local staging = require("@self/staging")
require("@self/stack")

type Repo = repos.Repo
local repo_of, locate, vcs = repos.repo_of, repos.locate, repos.run

local M = {}

--- Diffs as text: buffers showing them, and patches for single hunks.
M.diffs = require("@self/diffs")
--- The history of some lines: why they're as they are.
M.why = require("@self/why")

greed.option.define({
	name = "vcs-signs",
	doc = "Show signs beside lines changed since the last commit",
	default = true,
})

-- A change since the last commit, in the buffer as it is now: where it is,
-- and what was there before.
type Change = { from: number, to: number, old: string, at: number, kind: "+" | "~" | "-" }

-- What each buffer's file was at the last commit, by buffer id; false for
-- files outside a repository.
local bases: { [number]: string | false } = {}
-- Goes up with each edit, so only the latest edit's redraw runs.
local generation = 0

-- The file at `relative` in `repo` as changes are counted from: with jj the
-- working copy's parent, with git what's staged (the last commit unless
-- something was staged). "" if it's new.
local function base_text(repo: Repo, relative: string): string
	local text = if repo.kind == "jj"
		then vcs(repo, { "file", "show", "-r", "@-", "--", `root-file:"{relative}"` })
		else vcs(repo, { "show", `:{relative}` })
	return text or ""
end

-- The repository each buffer's file is in, by buffer id.
local located: { [number]: Repo } = {}
-- Lines added, changed and removed in each buffer, by id.
local counts: { [number]: { [string]: number } } = {}
-- Each repository's branch by root: with jj the nearest bookmark and the
-- working copy's change, e.g. "main · nwpr".
local branches: { [string]: string? } = {}

-- `text` without the whitespace around it, or nil if nothing's left.
local function trimmed(text: string?): string?
	local inner = text and string.match(text, "^%s*(.-)%s*$")
	return if inner and inner ~= "" then inner else nil
end

local function read_branch(repo: Repo)
	local name
	if repo.kind == "jj" then
		local change =
			trimmed(vcs(repo, { "log", "-r", "@", "--no-graph", "-T", "change_id.shortest(4)" }))
		local bookmark = trimmed(vcs(repo, {
			"log",
			"-r",
			"latest(heads(::@ & bookmarks()))",
			"--no-graph",
			"-T",
			'local_bookmarks.map(|b| b.name()).join(" ")',
		}))
		name = if bookmark and change then `{bookmark} · {change}` else change
	else
		-- Detached: the commit instead.
		name = trimmed(vcs(repo, { "branch", "--show-current" }))
			or trimmed(vcs(repo, { "rev-parse", "--short", "HEAD" }))
	end
	branches[repo.root] = name
end

-- The changes since the last commit, in order.
local function changes(buffer: greed.Buffer): { Change }
	local base: (string | false)? = bases[buffer:id()]
	if not base then
		return {}
	end
	local out: { Change } = {}
	-- Hunks are in the old text; `shift` turns their places into the new one's.
	local shift = 0
	for _, hunk in greed.diff(base, buffer:text()) do
		local from = hunk.from + shift
		local old = string.sub(base, hunk.from + 1, hunk.to)
		local kind: "+" | "~" | "-" = if old == "" then "+" elseif hunk.text == "" then "-" else "~"
		table.insert(
			out,
			{ from = from, to = from + #hunk.text, old = old, at = hunk.from, kind = kind }
		)
		shift += #hunk.text - #old
	end
	return out
end

-- The first and last lines a change covers; a removal covers the line it
-- was removed from.
local function lines_of(buffer: greed.Buffer, change: Change): (number, number)
	local first = buffer:line_of(math.min(change.from, buffer:len()))
	local last = if change.to > change.from then buffer:line_of(change.to - 1) else first
	return first, last
end

local STYLE: { [string]: string } =
	{ ["+"] = "diff.plus", ["~"] = "diff.delta", ["-"] = "diff.minus" }

local function mark(buffer: greed.Buffer)
	local marks: { greed.Mark } = {}
	local signs = greed.option.get("vcs-signs") == true
	local count = { ["+"] = 0, ["~"] = 0, ["-"] = 0 }
	for _, change in changes(buffer) do
		local first, last = lines_of(buffer, change)
		count[change.kind] += if change.kind == "-"
			then math.max(1, select(2, string.gsub(change.old, "\n", "")))
			else last - first + 1
		if signs then
			for line = first, last do
				-- Only the sign is styled; the text keeps its own colours.
				local start = buffer:line_start(line)
				local sign: string = change.kind
				table.insert(
					marks,
					{ from = start, to = start, style = STYLE[change.kind], sign = sign }
				)
			end
		end
	end
	counts[buffer:id()] = count
	buffer:decorate("vcs", marks)
end

local function refresh(buffer: greed.Buffer)
	local repo, relative = locate(buffer)
	local id = buffer:id()
	if repo then
		located[id] = repo
	else
		located[id] = nil
	end
	bases[id] = if repo and relative then base_text(repo, relative) else false
	if repo then
		read_branch(repo)
	end
	mark(buffer)
end

greed.on("buffer.closed", function(event: greed.BufferClosed)
	bases[event.id], located[event.id], counts[event.id] = nil, nil, nil
end)

-- Commits and checkouts made elsewhere show within a few seconds.
greed.spawn(function()
	while true do
		greed.sleep(5000)
		local roots: { [string]: Repo } = {}
		for _, repo in located do
			roots[repo.root] = repo
		end
		for _, repo in roots do
			pcall(read_branch, repo)
		end
	end
end)

-- The branch and the lines changed in the buffer, e.g. "main +3 ~1 -2".
statusline.add("right", "branch", function(ctx)
	local id = ctx.buffer:id()
	local repo = located[id]
	local branch = repo and branches[repo.root]
	if branch == nil then
		return nil
	end
	local parts = { branch }
	for _, kind in { "+", "~", "-" } do
		local n = counts[id] and counts[id][kind] or 0
		if n > 0 then
			table.insert(parts, `{kind}{n}`)
		end
	end
	return table.concat(parts, " ")
end, "problems")

greed.on("buffer.opened", function(event: greed.BufferChanged)
	refresh(event.buffer)
end)

-- Saving may follow a commit made elsewhere, so the base is read again.
greed.on("buffer.saved", function(event: greed.BufferChanged)
	refresh(event.buffer)
end)

greed.on("buffer.changed", function(event: greed.BufferChanged)
	local buffer = event.buffer
	if not bases[buffer:id()] then
		return
	end
	generation += 1
	local mine = generation
	greed.sleep(100)
	if mine == generation then
		pcall(mark, buffer)
	end
end)

greed.on("option.changed", function(event)
	if event.name == "vcs-signs" then
		for _, buffer in greed.buffers() do
			if bases[buffer:id()] then
				mark(buffer)
			end
		end
	end
end)

local function head(view: greed.View): number
	local selection = view:selection()
	return selection.ranges[selection.primary].head
end

local function goto_change(ctx: greed.Context, forward: boolean)
	local buffer = ctx.buffer
	local line = buffer:line_of(head(ctx.view))
	local found = changes(buffer)
	local target: number? = nil
	if forward then
		for _, change in found do
			local first = lines_of(buffer, change)
			if first > line then
				target = first
				break
			end
		end
	else
		for i = #found, 1, -1 do
			local first = lines_of(buffer, found[i])
			if first < line then
				target = first
				break
			end
		end
	end
	if target == nil then
		greed.echo("no more changes")
		return
	end
	local at = buffer:line_start(target)
	ctx.view:set_selection({ ranges = { { anchor = at, head = at } }, primary = 1 })
end

greed.command({
	name = "next-change",
	doc = "Go to the next change since the last commit",
	run = function(ctx)
		goto_change(ctx, true)
	end,
})

greed.command({
	name = "prev-change",
	doc = "Go to the previous change since the last commit",
	run = function(ctx)
		goto_change(ctx, false)
	end,
})

for _, last in { false, true } do
	greed.command({
		name = if last then "last-change" else "first-change",
		doc = if last
			then "Go to the last change since the last commit"
			else "Go to the first change since the last commit",
		run = function(ctx)
			local buffer = ctx.buffer
			local found = changes(buffer)
			local change = found[if last then #found else 1]
			if change == nil then
				greed.echo("no changes")
				return
			end
			local at = buffer:line_start((lines_of(buffer, change)))
			ctx.view:set_selection({ ranges = { { anchor = at, head = at } }, primary = 1 })
		end,
	})
end

-- The change since the last commit on the cursor's line, if there is one.
local function change_here(ctx: greed.Context): Change?
	local buffer = ctx.buffer
	local line = buffer:line_of(head(ctx.view))
	for _, change in changes(buffer) do
		local first, last = lines_of(buffer, change)
		if first <= line and line <= last then
			return change
		end
	end
	return nil
end

-- The change shown on `line`, with the lines it shows on: lines only
-- removed show under the line before where they were.
local function change_shown_at(buffer: greed.Buffer, line: number): (Change?, number, number)
	for _, change in changes(buffer) do
		local first, last = lines_of(buffer, change)
		if change.kind == "-" then
			first = math.max(first - 1, 0)
		end
		if first <= line and line <= last then
			return change, first, last
		end
	end
	return nil, 0, 0
end

for _, around in { false, true } do
	greed.command({
		name = if around then "select-around-change" else "select-inside-change",
		doc = if around
			then "Select the lines of the change since the last commit under the cursor"
			else "Select the text of the change since the last commit under the cursor",
		run = function(ctx)
			local change = change_here(ctx)
			if change == nil then
				return
			end
			local buffer = ctx.buffer
			local from, to = change.from, change.to
			if around then
				local first, last = lines_of(buffer, change)
				from = buffer:line_start(first)
				to = if last + 1 < buffer:line_count()
					then buffer:line_start(last + 1)
					else buffer:len()
			end
			ctx.view:set_selection({ ranges = { { anchor = from, head = to } }, primary = 1 })
		end,
	})
end

-- Every change since the last commit, in one multibuffer -------------------

-- The files changed since the last commit in `repo`, by path from its
-- root; deleted ones are left out, having nothing to show.
local function changed_files(repo: Repo): { string }
	local files = {}
	if repo.kind == "jj" then
		for line in string.gmatch(vcs(repo, { "diff", "--summary" }, true) or "", "[^\n]+") do
			local kind, path = string.match(line, "^(%a) (.+)$")
			if kind and path and kind ~= "D" then
				-- A rename shows as "R dir/{old => new}"; the file is the new name.
				table.insert(files, (string.gsub(path, "{[^}]* => ([^}]*)}", "%1")))
			end
		end
	else
		for line in string.gmatch(vcs(repo, { "status", "--porcelain", "-uall" }) or "", "[^\n]+") do
			-- The second column is the file against what's staged.
			local unstaged, path = string.sub(line, 2, 2), string.sub(line, 4)
			if unstaged ~= " " and unstaged ~= "D" then
				table.insert(files, string.match(path, " %-> (.+)$") or path)
			end
		end
	end
	table.sort(files)
	return files
end

-- `n` of `word`, with an "s" for more than one.
local function count(n: number, word: string): string
	return `{n} {word}{if n == 1 then "" else "s"}`
end

--- Shows every change in the repository the project is in, as a
--- multibuffer: with jj since the working copy's parent, with git what's
--- not staged. Edit it to change the files; `space g r` puts the change
--- under the cursor back and `space g a` stages it. `refreshing` closes it
--- when nothing's left.
function M.show_changes(refreshing: boolean?)
	local repo = repo_of(greed.project.current().root .. "/.")
	if repo == nil then
		error("the project isn't in a repository", 0)
	end
	local excerpts: { multibuffer.Excerpt } = {}
	local files = changed_files(repo)
	for _, relative in files do
		local path = `{repo.root}/{relative}`
		local text = core.file.text(path)
		if text then
			for _, excerpt in multibuffer.diff(path, relative, base_text(repo, relative), text) do
				table.insert(excerpts, excerpt)
			end
		end
	end
	local staged = ""
	if repo.kind == "git" then
		local names = vcs(repo, { "diff", "--cached", "--name-only" }) or ""
		local _, n = string.gsub(names, "\n", "")
		staged = if n > 0 then `; {count(n, "file")} staged (space g S)` else ""
	end
	if #excerpts == 0 then
		greed.echo(
			if repo.kind == "jj" then "nothing changed since @-" else `nothing to stage{staged}`
		)
		if refreshing then
			multibuffer.close()
		end
		return
	end
	local since = if repo.kind == "jj" then "since the working copy's parent" else "not staged"
	local summary = `{count(#excerpts, "change")} in {count(#files, "file")} {since}{staged}`
	local view = multibuffer.open(excerpts, {
		summary = summary,
		context = 2,
		base = function(path)
			return base_text(repo, string.sub(path, #repo.root + 2))
		end,
		refresh = function()
			M.show_changes(true)
		end,
	})
	multibuffer.show(view, "Changes")
end

greed.command({
	name = "changes",
	doc = "Show every change since the last commit in one buffer, to read, edit or put back",
	run = function()
		M.show_changes()
	end,
})

greed.command({
	name = "revert-change",
	doc = "Put the change under the cursor back the way it was at the last commit",
	run = function(ctx)
		local buffer = ctx.buffer
		if buffer:kind() == "multibuffer" then
			local ok, why = multibuffer.revert(buffer, head(ctx.view))
			if not ok then
				greed.echo(why :: string)
			end
			return
		end
		local change = change_shown_at(buffer, buffer:line_of(head(ctx.view)))
		if change == nil then
			greed.echo("no change here")
			return
		end
		buffer:edit(function(e)
			e:replace(change.from, change.to, change.old)
		end)
	end,
})

greed.command({
	name = "stage-change",
	doc = "Stage the change under the cursor for the next git commit, leaving the rest",
	run = function(ctx)
		local buffer = ctx.buffer
		local pos = head(ctx.view)
		local path, text
		if buffer:kind() == "multibuffer" then
			path, text = multibuffer.change_at(buffer, pos)
		else
			local change = change_shown_at(buffer, buffer:line_of(pos))
			local base: (string | false)? = bases[buffer:id()]
			if change and base then
				path = buffer:path()
				local new = string.sub(buffer:text(), change.from + 1, change.to)
				text = string.sub(base, 1, change.at)
					.. new
					.. string.sub(base, change.at + #change.old + 1)
			end
		end
		local repo = if path then repo_of(core.project.resolve(path)) else nil
		if repo and repo.kind == "jj" then
			greed.echo(
				"jj has no staging; split the change in the change stack (space g l) instead"
			)
			return
		elseif repo == nil or path == nil or text == nil then
			greed.echo("no change here")
			return
		end
		path, text = path :: string, text :: string
		local ok, why =
			staging.stage(repo, string.sub(core.project.resolve(path), #repo.root + 2), text)
		if not ok then
			greed.echo(`can't stage: {why}`)
			return
		end
		refresh(greed.load(path))
		if buffer:kind() == "multibuffer" then
			M.show_changes(true)
		end
	end,
})

-- The change under the cursor, as a thing to act on.
core.actions.finder({
	name = "change",
	plugin = "vcs",
	find = function(view, range)
		local buffer = view:buffer()
		local change, first, last = change_shown_at(buffer, buffer:line_of(range.head))
		if change == nil then
			return nil
		end
		local what = if change.kind == "+"
			then "added"
			elseif change.kind == "-" then "removed"
			else "changed"
		return {
			{
				kind = "change",
				label = `{what} line{if last > first then "s" else ""} {first + 1}`,
				value = change,
				from = change.from,
				to = change.to,
			},
		}
	end,
})
core.actions.command(
	"change",
	"revert",
	"revert-change",
	"Put it back the way it was at the last commit",
	"vcs"
)
core.actions.command("change", "blame", "blame-line", "Who last changed the line, and when", "vcs")
core.actions.command("change", "stage", "stage-change", "Stage it for the next git commit", "vcs")

greed.command({
	name = "blame-line",
	doc = "Show who last changed the line under the cursor, and when",
	run = function(ctx)
		local repo, relative = locate(ctx.buffer)
		if repo == nil or relative == nil then
			greed.echo("this file isn't in a repository")
			return
		end
		local line = ctx.buffer:line_of(head(ctx.view)) + 1
		local out = if repo.kind == "jj"
			then vcs(repo, { "file", "annotate", "-r", "@", "--", `root-file:"{relative}"` })
			else vcs(repo, { "blame", "-L", `{line},{line}`, "--", relative })
		if out == nil then
			greed.echo("no history for this line")
			return
		end
		local text: string = if repo.kind == "jj"
			then string.split(out :: string, "\n")[line] or ""
			else out :: string
		-- Just the who and when, not the line's text again.
		greed.echo(string.match(text, "^[^)]*%)") or string.match(text, "^[^:]*") or "")
	end,
})

--- The files changed in the repository `dir` is in, as absolute paths: with
--- jj in the working copy's change, with git since the last commit, leaving
--- out deleted ones. Nil and why not outside a repository.
function M.changed_files(dir: string): ({ string }?, string?)
	local repo = repo_of(dir .. "/.")
	if repo == nil then
		return nil, "not in a repository"
	end
	local out = {}
	for _, relative in changed_files(repo) do
		table.insert(out, `{repo.root}/{relative}`)
	end
	return out, nil
end

greed.command({
	name = "pick-changed-file",
	doc = "Open a file changed since the last commit",
	run = function()
		local root = core.project.root()
		local files, err = M.changed_files(root)
		if files == nil then
			greed.echo(err :: string)
			return
		elseif #files == 0 then
			greed.echo("nothing changed")
			return
		end
		local items = {}
		for _, path in files do
			table.insert(items, { label = core.project.relative(path, root), value = path })
		end
		picker.pick("Changed files", items, function(item)
			greed.open(item.value)
		end)
	end,
})

--- The changes in progress in the repository `dir` is in, as a diff: with
--- jj the working copy's change; with git what's staged, or everything when
--- nothing is. Also which it is ("jj" or "git"), or nil and why not.
function M.diff(dir: string): (string?, string?)
	local repo = repo_of(dir .. "/.")
	if repo == nil then
		return nil, "not in a repository"
	end
	if repo.kind == "jj" then
		return vcs(repo, { "diff", "--git" }, true), "jj"
	end
	local staged = vcs(repo, { "diff", "--cached" })
	if staged and staged ~= "" then
		return staged, "git"
	end
	return vcs(repo, { "diff" }), "git"
end

--- Describes the changes in progress in the repository `dir` is in with
--- `message`: with jj the working copy's description; with git a commit of
--- what's staged. Returns false and why when it can't.
function M.describe(dir: string, message: string): (boolean, string?)
	local repo = repo_of(dir .. "/.")
	if repo == nil then
		return false, "not in a repository"
	end
	local args = if repo.kind == "jj"
		then { "jj", "describe", "-m", message }
		else { "git", "commit", "-q", "-m", message }
	local done, err = greed.process.run(args, { cwd = repo.root })
	if done == nil or done.code ~= 0 then
		return false, if done then done.stderr else err
	end
	return true, nil
end

--- Saves the buffers of `paths` (files in one repository) and commits just
--- them with `message`, leaving any other changes as they were. Returns
--- false and why when it can't.
function M.commit(paths: { string }, message: string): (boolean, string?)
	local repo = if paths[1] then repo_of(paths[1]) else nil
	if repo == nil then
		return false, "the files aren't in a repository"
	end
	local relative: { string } = {}
	-- jj reads paths as patterns, so each is quoted as one exact file.
	local exact: { string } = {}
	for _, path in paths do
		local buffer = greed.load(path)
		if buffer:modified() then
			buffer:save()
		end
		local from_root = string.sub(core.project.resolve(path), #repo.root + 2)
		table.insert(relative, from_root)
		table.insert(exact, `file:"{(string.gsub(from_root, '["\\]', "\\%0"))}"`)
	end
	local steps: { { string } } = if repo.kind == "jj"
		then { { "commit", "-m", message, table.unpack(exact) } }
		else {
			{ "add", "--", table.unpack(relative) },
			{ "commit", "-q", "-m", message, "--", table.unpack(relative) },
		}
	for _, args in steps do
		local done, err = greed.process.run({ repo.kind, table.unpack(args) }, { cwd = repo.root })
		if done == nil or done.code ~= 0 then
			return false, if done then done.stderr else err
		end
	end
	return true, nil
end

greed.command({
	name = "operation-commit",
	doc = "Save the files of the latest operation (or the one being reviewed) and commit just them, named after it",
	run = function(ctx)
		local op = operations.target(ctx.buffer)
		if op == nil or #op.files == 0 then
			greed.echo("no operation with changes to commit")
			return
		end
		local paths = {}
		for _, file in op.files do
			table.insert(paths, file.path)
		end
		local ok, why = M.commit(paths, op.name)
		greed.echo(if ok then `committed "{op.name}"` else `can't commit: {why}`)
	end,
})

greed.keymap.bind("normal", {
	["space g s"] = "changes",
	["space g l"] = "change-stack",
	["] g"] = "next-change",
	["[ g"] = "prev-change",
	["] G"] = "last-change",
	["[ G"] = "first-change",
	["m i g"] = "select-inside-change",
	["m a g"] = "select-around-change",
	["space g g"] = "pick-changed-file",
	["space g r"] = "revert-change",
	["space g a"] = "stage-change",
	["space g S"] = "staged",
	["space g b"] = "blame-line",
	["space u c"] = "operation-commit",
})

return M
