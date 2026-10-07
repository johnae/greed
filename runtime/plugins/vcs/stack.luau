-- The change stack, like Magit's log for jj: the changes between what's
-- pushed and the working copy, newest first, with keys to look at,
-- describe, split, squash, move and abandon them. `space g l` opens it and
-- `?` lists the keys. In a git repository it lists recent commits to look
-- at.
--
--   Changes in ~/src/greed    ? for keys
--
--   @ notpmpms (empty) (no description)
--   ○ wstllsro main  second
--   ◆ oyrstryz first

local greed = require("@greed")
local core = require("@core")
local diff_text = require("./diffs")
local hunks = require("./hunks")
local repos = require("./repo")

type Repo = repos.Repo

local M = {}

export type Change = {
	--- The full change id with jj, the commit hash with git.
	id: string,
	short: string,
	--- "@" for the working copy, "◆" for an immutable change, "○" otherwise.
	marker: string,
	empty: boolean,
	conflict: boolean,
	bookmarks: string,
	description: string,
}

type Stack = {
	repo: Repo,
	view: greed.View,
	buffer: greed.Buffer,
	--- What the view showed before, kept open for q, and whether it was
	--- kept before that.
	previous: greed.Buffer,
	was_kept: boolean,
	--- The change on each line, by 0-based line number.
	rows: { [number]: Change },
}

-- Stacks by their buffer's id.
local stacks: { [number]: Stack } = {}
-- Diffs by their buffer's id, with the stack they were opened from.
local diffs: { [number]: { stack: Stack, change: string } } = {}

-- The working copy, the mutable changes under it, and the immutable one
-- they start from.
local REVSET = "@ | immutable_heads()..@ | ((immutable_heads()..@)- ~ root())"

local TEMPLATE = table.concat({
	"change_id",
	"change_id.shortest(8)",
	'if(current_working_copy, "@", if(immutable, "◆", "○"))',
	'if(empty, "e")',
	'if(conflict, "c")',
	'bookmarks.join(" ")',
	"description.first_line()",
}, ' ++ "\\t" ++ ') .. ' ++ "\\n"'

--- The changes to show in `repo`, newest first: with jj the stack from the
--- last immutable change to the working copy, with git the last 30
--- commits. Nil and why when the command fails.
function M.changes(repo: Repo): ({ Change }?, string?)
	local out: { Change } = {}
	if repo.kind == "jj" then
		local text = repos.run(
			repo,
			{ "log", "--no-graph", "--color", "never", "-r", REVSET, "-T", TEMPLATE },
			true
		)
		if text == nil then
			return nil, "jj log failed"
		end
		for line in string.gmatch(text, "[^\n]+") do
			local fields = string.split(line, "\t")
			table.insert(out, {
				id = fields[1],
				short = fields[2],
				marker = fields[3],
				empty = fields[4] == "e",
				conflict = fields[5] == "c",
				bookmarks = fields[6] or "",
				description = table.concat(fields, "\t", 7),
			})
		end
	else
		local text = repos.run(repo, { "log", "-30", "--format=%H%x09%h%x09%D%x09%s" })
		if text == nil then
			return nil, "git log failed"
		end
		for line in string.gmatch(text, "[^\n]+") do
			local fields = string.split(line, "\t")
			table.insert(out, {
				id = fields[1],
				short = fields[2],
				marker = if #out == 0 then "@" else "○",
				empty = false,
				conflict = false,
				bookmarks = fields[3] or "",
				description = table.concat(fields, "\t", 4),
			})
		end
	end
	return out, nil
end

type Style = { from: number, to: number, style: string }

-- A change's line and the styles over it.
local function row(change: Change): (string, { Style })
	local styles: { Style } = {}
	local parts = { change.marker, " " }
	local at = #change.marker + 1
	local function add(text: string, style: string?)
		if style then
			table.insert(styles, { from = at, to = at + #text, style = style })
		end
		table.insert(parts, text)
		at += #text
	end
	add(change.short, "constant")
	add(" ")
	if change.conflict then
		add("(conflict) ", "diagnostic.error")
	end
	if change.empty then
		add("(empty) ", "comment")
	end
	if change.bookmarks ~= "" then
		add(change.bookmarks, "keyword")
		add("  ")
	end
	if change.description == "" then
		add("(no description)", "comment")
	else
		add(change.description)
	end
	return table.concat(parts), styles
end

-- The 0-based line the cursor of `stack`'s view is on.
local function cursor_line(stack: Stack): number
	return stack.view:buffer():line_of(stack.view:selection().ranges[1].head)
end

-- The change on the cursor's line, if any.
local function under_cursor(stack: Stack): Change?
	return stack.rows[cursor_line(stack)]
end

-- Redraws `stack`, keeping the cursor on the change it was on, or on
-- `select` if given.
local function render(stack: Stack, select: string?)
	local was_on = under_cursor(stack)
	local keep = select or (was_on and was_on.id)
	local changes, err = M.changes(stack.repo)
	local title = `Changes in {core.project.tilde(stack.repo.root)}`
	local header = title .. "    ? for keys"
	local lines = { header, "" }
	local marks: { greed.Mark } = {
		{ from = 0, to = #title, style = "markup.heading" },
		{ from = #title, to = #header, style = "comment" },
	}
	local at = #header + 2
	stack.rows = {}
	local cursor = nil
	if changes == nil then
		table.insert(lines, err :: string)
	else
		for _, change in changes do
			local line, styles = row(change)
			for _, style in styles do
				table.insert(
					marks,
					{ from = at + style.from, to = at + style.to, style = style.style }
				)
			end
			stack.rows[#lines] = change
			if change.id == keep or (change.marker == "@" and (cursor == nil or keep == "@")) then
				cursor = #lines
			end
			table.insert(lines, line)
			at += #line + 1
		end
	end
	local buffer = stack.buffer
	buffer:set_readonly(false)
	buffer:edit(function(e)
		e:replace(0, buffer:len(), table.concat(lines, "\n"))
	end)
	buffer:set_readonly(true)
	buffer:decorate("change-stack", marks)
	if stack.view:buffer():id() ~= buffer:id() then
		return
	end
	local pos = buffer:line_start(cursor or 2)
	stack.view:set_selection({ ranges = { { anchor = pos, head = pos } }, primary = 1 })
end

--- Opens the change stack of the repository the project is in, in `view`.
function M.open(view: greed.View)
	local repo = repos.repo_of(greed.project.current().root .. "/.")
	if repo == nil then
		error("the project isn't in a repository", 0)
	end
	for _, stack in stacks do
		if stack.repo.root == repo.root then
			stack.view = view
			if view:buffer():id() ~= stack.buffer:id() then
				view:show(stack.buffer)
			end
			render(stack)
			return
		end
	end
	local buffer = greed.create_buffer("change-stack", "", { readonly = true })
	buffer:set_line_numbers(false)
	-- Both stay open while something else is shown: the stack under a diff,
	-- what was there before under the stack.
	buffer:set_kept(true)
	local previous = view:buffer()
	local stack: Stack = {
		repo = repo,
		view = view,
		buffer = buffer,
		previous = previous,
		was_kept = previous:kept(),
		rows = {},
	}
	previous:set_kept(true)
	stacks[buffer:id()] = stack
	view:show(buffer)
	render(stack)
end

-- Puts back what `stack`'s view showed before and closes the stack.
local function close(stack: Stack)
	stacks[stack.buffer:id()] = nil
	-- Unkept and no longer shown, the stack closes.
	stack.buffer:set_kept(false)
	stack.view:show(stack.previous)
	stack.previous:set_kept(stack.was_kept)
end

-- The stack `ctx` is in, and the change under its cursor.
local function current(ctx: greed.Context): (Stack?, Change?)
	local stack = stacks[ctx.buffer:id()]
	if stack == nil then
		return nil, nil
	end
	stack.view = ctx.view
	return stack, under_cursor(stack)
end

-- Runs jj `args` in `stack`'s repository and redraws it, keeping the
-- cursor on `select` if given. Echoes jj's complaint when it fails.
local function jj(stack: Stack, args: { string }, select: string?): boolean
	if stack.repo.kind ~= "jj" then
		greed.echo("that needs a jj repository")
		return false
	end
	local done, err = greed.process.run(
		{ "jj", "--color", "never", table.unpack(args) },
		{ cwd = stack.repo.root }
	)
	if done == nil or done.code ~= 0 then
		local why = if done then done.stderr else err
		greed.echo(`jj {args[1]}: {string.match(why or "", "^%s*(.-)%s*$")}`)
		render(stack)
		return false
	end
	render(stack, select)
	return true
end

-- The files `change` touches, by path from the root: both names of a
-- renamed one.
local function touched(repo: Repo, change: Change): { string }
	local out = {}
	local summary = repos.run(repo, { "diff", "--summary", "-r", change.id }, true) or ""
	for line in string.gmatch(summary, "[^\n]+") do
		local kind, path = string.match(line, "^(%a) (.+)$")
		if kind == "R" or kind == "C" then
			local before, old, new, after = string.match(path :: string, "^(.-){(.-) => (.-)}(.*)$")
			if before then
				-- "{a => }" names a file moved up a folder, leaving "//".
				local function name(middle: string): string
					return (string.gsub(`{before}{middle}{after}`, "//", "/"))
				end
				if kind == "R" then
					table.insert(out, name(old :: string))
				end
				table.insert(out, name(new :: string))
			end
		elseif path then
			table.insert(out, path)
		end
	end
	return out
end

-- Quoted for a TOML string.
local function toml(text: string): string
	return '"' .. (string.gsub(text, '["\\]', "\\%0")) .. '"'
end

-- Copies the files written under the folder given second into the folder
-- jj gives first (what the first change will hold), and removes the ones
-- listed in its `deleted`.
local SPLIT_TOOL = 'right=$1; prep=$2; if [ -d "$prep/files" ]; then cp -R "$prep/files/." "$right/"; fi; '
	.. 'while IFS= read -r p; do rm -f "$right/$p"; done < "$prep/deleted"'

-- Splits `change` in two: the hunks picked go in a new change before it,
-- the rest stay. jj runs a diff editor for this, so the picked files are
-- written to a folder in .jj that a small shell script copies in.
local function split(stack: Stack, change: Change)
	if stack.repo.kind ~= "jj" then
		greed.echo("that needs a jj repository")
		return
	end
	local files: { hunks.File } = {}
	for _, path in touched(stack.repo, change) do
		local file = `root-file:{toml(path)}`
		table.insert(files, {
			path = path,
			old = repos.run(stack.repo, { "file", "show", "-r", change.id .. "-", "--", file }),
			new = repos.run(stack.repo, { "file", "show", "-r", change.id, "--", file }),
		})
	end
	if #files == 0 then
		greed.echo("nothing in it to split")
		return
	end
	hunks.pick(stack.view, {
		title = `Split {change.short}: pick what goes in the first change`,
		files = files,
		cancel = function()
			render(stack, change.id)
		end,
		done = function(picked, count, total)
			if count == 0 or count == total then
				greed.echo("pick some of the hunks, not none or all")
				render(stack, change.id)
				return
			end
			local message = core.prompt.ask("Describe the first change", change.description)
			if message == nil then
				render(stack, change.id)
				return
			end
			local prep = `{stack.repo.root}/.jj/greed-split`
			greed.fs.remove(prep, { recursive = true })
			local deleted = {}
			for path, text: string | false in picked do
				if text then
					greed.fs.write(`{prep}/files/{path}`, text)
				else
					table.insert(deleted, path)
				end
			end
			greed.fs.write(
				`{prep}/deleted`,
				if #deleted > 0 then table.concat(deleted, "\n") .. "\n" else ""
			)
			local edit_args = `["-c", {toml(SPLIT_TOOL)}, "sh", "$right", {toml(prep)}]`
			jj(stack, {
				"split",
				"-r",
				change.id,
				"-m",
				message,
				"--tool",
				"greed-split",
				"--config",
				"merge-tools.greed-split.program=sh",
				"--config",
				`merge-tools.greed-split.edit-args={edit_args}`,
			}, change.id)
			greed.fs.remove(prep, { recursive = true })
		end,
	})
end

-- Commands on the change under the cursor: each gets the stack and the
-- change, and is bound in change-stack buffers.
type Action = { name: string, key: string, doc: string, run: (Stack, Change) -> () }

local ACTIONS: { Action } = {
	{
		name = "change-stack-show",
		key = "enter",
		doc = "Show the change's diff",
		run = function(stack, change)
			local args = if stack.repo.kind == "jj"
				then { "diff", "--git", "--color", "never", "-r", change.id }
				else { "show", "--format=%H%n%an  %ad%n%n%B", change.id }
			local buffer = diff_text.buffer("change-diff", repos.run(stack.repo, args, true) or "")
			diffs[buffer:id()] = { stack = stack, change = change.id }
			stack.view:show(buffer)
		end,
	},
	{
		name = "change-stack-describe",
		key = "d",
		doc = "Describe the change",
		run = function(stack, change)
			local message = core.prompt.ask(`Describe {change.short}`, change.description)
			if message then
				jj(stack, { "describe", "-r", change.id, "-m", message })
			end
		end,
	},
	{
		name = "change-stack-new",
		key = "n",
		doc = "Start a new change on top of it",
		run = function(stack, change)
			jj(stack, { "new", change.id }, "@")
		end,
	},
	{
		name = "change-stack-edit",
		key = "e",
		doc = "Make it the working copy, to edit it",
		run = function(stack, change)
			jj(stack, { "edit", change.id }, "@")
		end,
	},
	{
		name = "change-stack-squash",
		key = "s",
		doc = "Squash it into its parent, keeping the parent's description",
		run = function(stack, change)
			jj(stack, { "squash", "-u", "-r", change.id })
		end,
	},
	{
		name = "change-stack-split",
		key = "S",
		doc = "Split it: pick the hunks that go in a change of their own before it",
		run = split,
	},
	{
		name = "change-stack-abandon",
		key = "a",
		doc = "Abandon it, after asking",
		run = function(stack, change)
			greed.echo(`abandon {change.short}? y/n`)
			local yes = greed.next_key() == "y"
			greed.echo("")
			if yes then
				jj(stack, { "abandon", change.id })
			end
		end,
	},
	{
		name = "change-stack-up",
		key = "alt-k",
		doc = "Move it above the change above it",
		run = function(stack, change)
			local above = stack.rows[cursor_line(stack) - 1]
			if above then
				jj(stack, { "rebase", "-r", change.id, "--insert-after", above.id }, change.id)
			end
		end,
	},
	{
		name = "change-stack-down",
		key = "alt-j",
		doc = "Move it below the change below it",
		run = function(stack, change)
			local below = stack.rows[cursor_line(stack) + 1]
			if below then
				jj(stack, { "rebase", "-r", change.id, "--insert-before", below.id }, change.id)
			end
		end,
	},
}

-- Commands on the stack as a whole.
local WHOLE: { { name: string, key: string, doc: string, run: (Stack) -> () } } = {
	{
		name = "change-stack-undo",
		key = "u",
		doc = "Undo the last jj operation",
		run = function(stack)
			jj(stack, { "undo" })
		end,
	},
	{
		name = "change-stack-refresh",
		key = "r",
		doc = "Read the stack again",
		run = function(stack)
			render(stack)
		end,
	},
	{
		name = "change-stack-close",
		key = "q",
		doc = "Close the stack and go back to what was shown before",
		run = close,
	},
}

local keys: { [string]: string } = {}

for _, action in ACTIONS do
	keys[action.key] = action.name
	greed.command({
		name = action.name,
		doc = action.doc,
		run = function(ctx)
			local stack, change = current(ctx)
			if stack and change then
				action.run(stack, change)
			end
		end,
	})
end

for _, action in WHOLE do
	keys[action.key] = action.name
	greed.command({
		name = action.name,
		doc = action.doc,
		run = function(ctx)
			local stack = current(ctx)
			if stack then
				action.run(stack)
			end
		end,
	})
end

greed.command({
	name = "change-stack-menu",
	doc = "List the change stack's keys and pick one",
	run = function()
		local function items(list: { any }): { core.TransientItem }
			local out = {}
			for _, action in list do
				table.insert(out, {
					key = action.key,
					doc = action.doc,
					run = function()
						greed.run(action.name)
					end,
				})
			end
			return out
		end
		core.transient.show({
			title = "Change stack",
			groups = {
				{ title = "The change under the cursor", items = items(ACTIONS) },
				{ title = "The stack", items = items(WHOLE) },
			},
		})
	end,
})
keys["?"] = "change-stack-menu"

greed.command({
	name = "change-stack",
	doc = "Show the changes from the last pushed one to the working copy, to describe, squash, move or abandon",
	run = function(ctx)
		M.open(ctx.view)
	end,
})

greed.command({
	name = "change-diff-close",
	doc = "Go back to the change stack",
	run = function(ctx)
		local diff = diffs[ctx.buffer:id()]
		if diff then
			diffs[ctx.buffer:id()] = nil
			ctx.view:show(diff.stack.buffer)
			render(diff.stack, diff.change)
		end
	end,
})

greed.on("buffer.closed", function(event: greed.BufferClosed)
	local stack = stacks[event.id]
	if stack then
		stacks[event.id] = nil
		-- What it hid may be gone too.
		pcall(stack.previous.set_kept, stack.previous, stack.was_kept)
	end
	diffs[event.id] = nil
end)

for _, mode in { "normal", "vim", "edit" } do
	greed.keymap.bind({ mode = mode, kind = "change-stack" }, keys)
	greed.keymap.bind({ mode = mode, kind = "change-diff" }, { q = "change-diff-close" })
end

return M
