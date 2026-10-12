-- git's and jj's output in the shell as things: the files `git status`
-- and `jj st` list are changed files (diff, stage, restore), `git log`'s
-- lines commits and `jj log`'s revisions (show, new, edit, abandon).
-- Actions name the repository the block ran in, so an old block still
-- acts there.

local greed = require("@greed")
local core = require("@core")
local shell = require("@shell")

local parse = shell.parse

type Block = shell.Block
type Shell = shell.Shell
type Table = shell.Table
type Thing = shell.Thing

-- `text`'s lines, without the carriage returns a terminal adds.
local function lines_of(text: string): { string }
	return string.split((string.gsub(text, "\r", "")), "\n")
end

-- What's left of `line` after the graph `git log --graph` and `jj log`
-- draw before it.
local GRAPH = {
	" ",
	"│",
	"├",
	"┤",
	"─",
	"╮",
	"╯",
	"╭",
	"╰",
	"┬",
	"┴",
	"┼",
	"|",
	"/",
	"\\",
	"~",
	"*",
}
local function ungraphed(line: string): string
	local stripped = true
	while stripped do
		stripped = false
		for _, piece in GRAPH do
			if string.sub(line, 1, #piece) == piece then
				line = string.sub(line, #piece + 1)
				stripped = true
			end
		end
	end
	return line
end

-- What a two-letter code of `git status -s` says: what happened to the
-- file and whether that's staged.
local CODES: { [string]: string } = {
	M = "modified",
	A = "added",
	D = "deleted",
	R = "renamed",
	C = "copied",
	U = "conflict",
	T = "type changed",
	["?"] = "untracked",
}

-- The path a rename leads to: `old -> new` (git) or `dir/{old => new}` (jj).
local function renamed(path: string): string
	local new = string.match(path, " %-> (.+)$")
	if new then
		return new
	end
	local before, after, rest = string.match(path, "^(.-){.- => (.-)}(.*)$")
	return if before and after and rest then before .. after .. rest else path
end

-- A table of changed files from `rows`, each `{ status, staged, path }`,
-- on the lines `at`.
local function files_table(rows: { { string } }, at: { number }): Table?
	if #rows == 0 then
		return nil
	end
	local out: { { [string]: string } } = {}
	for _, row in rows do
		local cells: { [string]: string } = { STATUS = row[1], STAGED = row[2], PATH = row[3] }
		table.insert(out, cells)
	end
	return { columns = { "STATUS", "STAGED", "PATH" }, rows = out, at = at }
end

-- `git status`, short (`-s`, `--porcelain`) or long.
shell.parser("^git status", function(text: string): any
	local rows: { { string } } = {}
	local at: { number } = {}
	local section: string? = nil
	for i, line in lines_of(text) do
		local code, path = string.match(line, "^([ MADRCUT?!][ MADRCUT?!]) (.+)$")
		local heading = string.match(line, "^(%u[%a ]+):$")
		local name, file = string.match(line, "^%s+(%a[%a ]*):%s+(.+)$")
		if heading then
			section = heading
		elseif code and path and section == nil then
			local x, y = string.sub(code, 1, 1), string.sub(code, 2, 2)
			local status = CODES[if y ~= " " then y else x] or code
			local staged = if x == " " or x == "?" then "no" elseif y == " " then "yes" else "partly"
			table.insert(rows, { status, staged, renamed(path) })
			table.insert(at, i)
		elseif name and file and section then
			local staged = if string.find(section, "to be committed", 1, true) then "yes" else "no"
			table.insert(rows, { name, staged, renamed(file) })
			table.insert(at, i)
		elseif section and string.find(section, "Untracked", 1, true) then
			local untracked = string.match(line, "^%s+([^%s(].*)$")
			if untracked then
				table.insert(rows, { "untracked", "no", untracked })
				table.insert(at, i)
			end
		end
	end
	return files_table(rows, at)
end)

-- `jj st`'s working copy changes.
shell.parser("^jj st", function(text: string): any
	local rows: { { string } } = {}
	local at: { number } = {}
	local within = false
	for i, line in lines_of(text) do
		local code, path = string.match(line, "^([MADRC]) (.+)$")
		if string.match(line, "^Working copy changes:") then
			within = true
		elseif within and code and path then
			table.insert(rows, { CODES[code], "", renamed(path) })
			table.insert(at, i)
		else
			within = false
		end
	end
	return files_table(rows, at)
end)

-- `git log`, as one line each (`--oneline`, with `--graph` too) or in full.
shell.parser("^git log", function(text: string): any
	local rows: { { [string]: string } } = {}
	local at: { number } = {}
	local open: { [string]: string }? = nil
	for i, line in lines_of(text) do
		local plain = ungraphed(line)
		local full = string.match(plain, "^commit (%x+)")
		local sha, subject = string.match(plain, "^(%x%x%x%x%x%x%x+) (.*)$")
		if full then
			local commit: { [string]: string } = { SHA = string.sub(full, 1, 12), SUBJECT = "" }
			open = commit
			table.insert(rows, commit)
			table.insert(at, i)
		elseif open then
			if open.SUBJECT == "" and plain ~= "" and not string.match(plain, "^%a+:") then
				open.SUBJECT = plain
			end
		elseif sha and subject then
			local commit: { [string]: string } = { SHA = sha, SUBJECT = subject }
			table.insert(rows, commit)
			table.insert(at, i)
		end
	end
	return if #rows > 0 then { columns = { "SHA", "SUBJECT" }, rows = rows, at = at } else nil
end)

-- The symbols `jj log` marks a change's line with.
local NODES = { "@", "○", "◆", "×", "◉", "◌", "●", "◇" }

-- Whether `prefix`, what's before a change id, ends in a change's symbol.
local function node(prefix: string): boolean
	local trimmed = string.match(prefix, "^(.-)%s*$") or prefix
	for _, symbol in NODES do
		if string.sub(trimmed, -#symbol) == symbol then
			return true
		end
	end
	return false
end

-- `jj log`'s changes: the line with the change id, and the description on
-- the line after it.
local function jj_log(text: string): any
	local rows: { { [string]: string } } = {}
	local at: { number } = {}
	local lines = lines_of(text)
	-- The change id on `line` and what follows it, when it's a change's.
	local function change(line: string): (string?, string?)
		local prefix, id, rest = string.match(line, "^(.-)%s+([k-z][k-z][k-z][k-z]+)%s+(.*)$")
		if prefix and id and rest and node(prefix) then
			return id, rest
		end
		return nil, nil
	end
	for i, line in lines do
		local id, rest = change(line)
		if id and rest then
			local next_line = lines[i + 1] or ""
			local cells: { [string]: string } = {
				CHANGE = id,
				DESCRIPTION = if change(next_line) then "" else ungraphed(next_line),
				COMMIT = string.match(rest, "(%x%x%x%x%x%x%x%x+)%s*$") or "",
			}
			table.insert(rows, cells)
			table.insert(at, i)
		end
	end
	return if #rows > 0
		then { columns = { "CHANGE", "DESCRIPTION", "COMMIT" }, rows = rows, at = at }
		else nil
end
shell.parser("^jj log", jj_log)
shell.parser("^jj%s*$", jj_log)

-- What a block of a repository's command keeps: the repository's root.
local function repository(marker: string): (block: Block, sh: Shell) -> any
	return function(block: Block, _sh: Shell): any
		return core.project.nearest(block.cwd, marker)
	end
end

-- A changed file on `row`, in the repository at `root`.
local function changed_file(
	row: { [string]: string },
	root: string,
	block: Block,
	vcs: string
): Thing?
	local path = row.PATH
	if path == nil or path == "" then
		return nil
	end
	local full = core.project.resolve(path, block.cwd)
	return {
		kind = "changed-file",
		label = path,
		key = full,
		value = { path = full, status = row.STATUS, staged = row.STAGED, root = root, vcs = vcs },
		cells = { PATH = { kind = "file", label = path, value = full } },
	}
end

shell.kind({
	name = "git-status",
	match = "^git status",
	capture = repository(".git"),
	row = function(row: { [string]: string }, root: any, block: Block): Thing?
		return changed_file(row, root, block, "git")
	end,
	called = function(): (string, string)
		return "changed file", "changed files"
	end,
})

shell.kind({
	name = "jj-status",
	match = "^jj st",
	capture = repository(".jj"),
	row = function(row: { [string]: string }, root: any, block: Block): Thing?
		return changed_file(row, root, block, "jj")
	end,
	called = function(): (string, string)
		return "changed file", "changed files"
	end,
})

shell.kind({
	name = "git-log",
	match = "^git log",
	capture = repository(".git"),
	row = function(row: { [string]: string }, root: any): Thing?
		local sha = row.SHA
		if sha == nil or sha == "" then
			return nil
		end
		return {
			kind = "commit",
			label = `{sha} {row.SUBJECT or ""}`,
			key = sha,
			value = { sha = sha, subject = row.SUBJECT, root = root },
		}
	end,
	called = function(): (string, string)
		return "commit", "commits"
	end,
})

for i, match in { "^jj log", "^jj%s*$" } do
	shell.kind({
		name = if i == 1 then "jj-log" else "jj",
		match = match,
		capture = repository(".jj"),
		row = function(row: { [string]: string }, root: any): Thing?
			local id = row.CHANGE
			if id == nil or id == "" then
				return nil
			end
			local description = row.DESCRIPTION or ""
			return {
				kind = "revision",
				label = if description ~= "" then `{id} {description}` else id,
				key = id,
				value = { id = id, commit = row.COMMIT, description = description, root = root },
			}
		end,
		called = function(): (string, string)
			return "revision", "revisions"
		end,
	})
end

core.objects.kind({ name = "changed-file", doc = "A file git or jj says has changed, by its path" })
core.objects.kind({ name = "commit", doc = "A git commit, by its hash" })
core.objects.kind({ name = "revision", doc = "A jj revision, by its change id" })

-- `git` with `args`, in the repository at `value.root`.
local function git(args: string, value: any): string
	return `git -C {parse.quote(value.root)} {args}`
end

-- `jj` with `args`, in the repository at `value.root`.
local function jj(args: string, value: any): string
	return `jj -R {parse.quote(value.root)} {args}`
end

-- A changed file as jj names it: by its path from the repository's root.
local function fileset(value: any): string
	local relative = string.sub(value.path, #value.root + 2)
	local escaped = string.gsub(string.gsub(relative, "\\", "\\\\"), '"', '\\"')
	return parse.quote(`root:"{escaped}"`)
end

shell.action_command("changed-file", "diff", function(value: any): string
	if value.vcs == "jj" then
		return jj(`diff {fileset(value)}`, value)
	end
	return git(`diff HEAD -- {parse.quote(value.path)}`, value)
end, { doc = "What changed in it", default = true })
shell.action_command("changed-file", "stage", function(value: any): string?
	if value.vcs == "jj" then
		greed.echo("jj has no staging: jj split or jj squash -i pick what goes where")
		return nil
	end
	return git(`add -- {parse.quote(value.path)}`, value)
end, { doc = "Stage it for the next commit (git)" })
shell.action_command("changed-file", "unstage", function(value: any): string?
	if value.vcs == "jj" then
		greed.echo("jj has no staging")
		return nil
	end
	return git(`restore --staged -- {parse.quote(value.path)}`, value)
end, { doc = "Take it out of what's staged (git)" })
shell.action_command("changed-file", "restore", function(value: any): string
	if value.vcs == "jj" then
		return jj(`restore {fileset(value)}`, value)
	end
	return git(`restore -- {parse.quote(value.path)}`, value)
end, { doc = "Throw away its changes", danger = true })
core.actions.action({
	kind = "changed-file",
	name = "open",
	doc = "Open it here",
	run = function(target)
		core.file.open(target.value.path)
	end,
})

shell.action_command("commit", "show", function(value: any): string
	return git(`show {value.sha}`, value)
end, { doc = "Its message and what it changed", default = true })
shell.action_command("commit", "checkout", function(value: any): string
	return git(`checkout {value.sha}`, value)
end, { doc = "Make the working copy what it was there" })
shell.action_command("commit", "cherry-pick", function(value: any): string
	return git(`cherry-pick {value.sha}`, value)
end, { doc = "Make the same change on top of where you are" })
shell.action_command("commit", "revert", function(value: any): string
	return git(`revert {value.sha}`, value)
end, { doc = "A new commit undoing it", danger = true })

shell.action_command("revision", "show", function(value: any): string
	return jj(`show {value.id}`, value)
end, { doc = "Its description and what it changed", default = true })
shell.action_command("revision", "diff", function(value: any): string
	return jj(`diff -r {value.id}`, value)
end, { doc = "What it changed" })
shell.action_command("revision", "new", function(value: any): string
	return jj(`new {value.id}`, value)
end, { doc = "Start a new change on top of it" })
shell.action_command("revision", "edit", function(value: any): string
	return jj(`edit {value.id}`, value)
end, { doc = "Make it the working copy, to change it" })
shell.action_command("revision", "squash", function(value: any): string
	return jj(`squash -r {value.id}`, value)
end, { doc = "Move what it changed into its parent", danger = true })
shell.action_command("revision", "abandon", function(value: any): string
	return jj(`abandon {value.id}`, value)
end, { doc = "Drop it, keeping its children", danger = true })

return {}
