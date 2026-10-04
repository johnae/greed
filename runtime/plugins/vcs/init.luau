-- Version control: signs beside lines added (+), changed (~) and removed
-- (-) since the last commit, with jj, or git where there's no .jj.
--
--   ] g / [ g   next / previous change; ] G / [ G the last and first
--   m i g       the change under the cursor; m a g its lines
--   space g r   put the change under the cursor back the way it was
--   space g b   who last changed this line, and when
--   space g s   every change since the last commit, in one multibuffer
--   space u c   commit just the latest operation's files, named after it
--
-- With jj the comparison is with the working copy's parent (@-), so the
-- signs show what the change you're working on does to the file.

local core = require("@core")
local greed = require("@greed")
local multibuffer = require("@multibuffer")
local operations = require("@operations")
local picker = require("@picker")

local M = {}

greed.option.define({
	name = "vcs-signs",
	doc = "Show signs beside lines changed since the last commit",
	default = true,
})

type Repo = { kind: "jj" | "git", root: string }

-- A change since the last commit, in the buffer as it is now: where it is,
-- and what was there before.
type Change = { from: number, to: number, old: string, kind: "+" | "~" | "-" }

-- What each buffer's file was at the last commit, by buffer id; false for
-- files outside a repository.
local bases: { [number]: string | false } = {}
-- Goes up with each edit, so only the latest edit's redraw runs.
local generation = 0

local function parent(path: string): string?
	return string.match(path, "^(.*)/[^/]*$")
end

-- The repository `path` is in, if any.
local function repo_of(path: string): Repo?
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

local function absolute(path: string): string
	return if string.sub(path, 1, 1) == "/" then path else `{greed.fs.cwd()}/{path}`
end

-- The repository `buffer`'s file is in, and the file's path from its root.
local function locate(buffer: greed.Buffer): (Repo?, string?)
	local path = buffer:path()
	local repo = path and repo_of(absolute(path))
	if path == nil or repo == nil then
		return nil, nil
	end
	return repo, string.sub(absolute(path), #repo.root + 2)
end

-- Runs a jj or git command in `repo`'s root and returns what it printed, or
-- nil if it failed. jj doesn't look at the files on disk unless `snapshot`
-- says to, for commands that only read what's committed.
local function vcs(repo: Repo, args: { string }, snapshot: boolean?): string?
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

-- The file at `relative` in `repo` as of the last commit, or "" if it's new.
local function base_text(repo: Repo, relative: string): string
	local text = if repo.kind == "jj"
		then vcs(repo, { "file", "show", "-r", "@-", "--", `root-file:"{relative}"` })
		else vcs(repo, { "show", `HEAD:{relative}` })
	return text or ""
end

-- The file at the last commit: its text, "" if it's new, or false outside a
-- repository.
local function fetch_base(buffer: greed.Buffer): string | false
	local repo, relative = locate(buffer)
	if repo == nil or relative == nil then
		return false
	end
	return base_text(repo, relative)
end

-- The changes since the last commit, in order.
local function changes(buffer: greed.Buffer): { Change }
	local base = bases[buffer:id()]
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
		table.insert(out, { from = from, to = from + #hunk.text, old = old, kind = kind })
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
	if greed.option.get("vcs-signs") == true then
		for _, change in changes(buffer) do
			local first, last = lines_of(buffer, change)
			for line = first, last do
				-- Only the sign is styled; the text keeps its own colours.
				local start = buffer:line_start(line)
				table.insert(marks, {
					from = start,
					to = start,
					style = STYLE[change.kind],
					sign = change.kind,
				})
			end
		end
	end
	buffer:decorate("vcs", marks)
end

local function refresh(buffer: greed.Buffer)
	bases[buffer:id()] = fetch_base(buffer)
	mark(buffer)
end

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
		local line = buffer:line_of(head(ctx.view))
		for _, change in changes(buffer) do
			local first, last = lines_of(buffer, change)
			-- Removed lines show under the line before where they were.
			if change.kind == "-" then
				first = math.max(first - 1, 0)
			end
			if first <= line and line <= last then
				buffer:edit(function(e)
					e:replace(change.from, change.to, change.old)
				end)
				return
			end
		end
		greed.echo("no change here")
	end,
})

-- The change under the cursor, as a thing to act on.
core.actions.finder({
	name = "change",
	plugin = "vcs",
	find = function(view, range)
		local buffer = view:buffer()
		local line = buffer:line_of(range.head)
		for _, change in changes(buffer) do
			local first, last = lines_of(buffer, change)
			if change.kind == "-" then
				first = math.max(first - 1, 0)
			end
			if first <= line and line <= last then
				local what = if change.kind == "+"
					then "added"
					elseif change.kind == "-" then "removed"
					else "changed"
				local label = `{what} line{if last > first then "s" else ""} {first + 1}`
				return {
					{
						kind = "change",
						label = label,
						value = change,
						from = change.from,
						to = change.to,
					},
				}
			end
		end
		return nil
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
			local state, path = string.sub(line, 1, 2), string.sub(line, 4)
			if not string.find(state, "D", 1, true) then
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

--- Shows every change since the last commit in the repository the project
--- is in, as a multibuffer: edit it to change the files, `space g r` puts
--- the change under the cursor back.
function M.show_changes()
	local repo = repo_of(greed.project.current().root .. "/.")
	if repo == nil then
		error("the project isn't in a repository", 0)
	end
	local excerpts: { multibuffer.Excerpt } = {}
	local files = changed_files(repo)
	for _, relative in files do
		local path = `{repo.root}/{relative}`
		local open = nil
		for _, buffer in greed.buffers() do
			if buffer:path() and absolute(buffer:path() :: string) == path then
				open = buffer
			end
		end
		local text = if open then open:text() else greed.fs.read(path)
		if text then
			for _, excerpt in multibuffer.diff(path, relative, base_text(repo, relative), text) do
				table.insert(excerpts, excerpt)
			end
		end
	end
	if #excerpts == 0 then
		greed.echo(`nothing changed since {if repo.kind == "jj" then "@-" else "HEAD"}`)
		return
	end
	local against = if repo.kind == "jj" then "the working copy's parent" else "HEAD"
	local summary = `{count(#excerpts, "change")} in {count(#files, "file")} since {against}`
	local view = multibuffer.open(excerpts, {
		summary = summary,
		context = 2,
		base = function(path)
			return base_text(repo, string.sub(path, #repo.root + 2))
		end,
		refresh = M.show_changes,
	})
	multibuffer.show(view, "Changes")
end

greed.command({
	name = "changes",
	doc = "Show every change since the last commit in one buffer, to read, edit or put back",
	run = M.show_changes,
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
			local shown = if string.sub(path, 1, #root + 1) == root .. "/"
				then string.sub(path, #root + 2)
				else path
			table.insert(items, { label = shown, value = path })
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
		local from_root = string.sub(absolute(path), #repo.root + 2)
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
	["] g"] = "next-change",
	["[ g"] = "prev-change",
	["] G"] = "last-change",
	["[ G"] = "first-change",
	["m i g"] = "select-inside-change",
	["m a g"] = "select-around-change",
	["space g g"] = "pick-changed-file",
	["space g r"] = "revert-change",
	["space g b"] = "blame-line",
	["space u c"] = "operation-commit",
})

return M
