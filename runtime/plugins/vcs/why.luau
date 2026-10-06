-- "Why is this here": the history of some lines. `space g w` shows, for the
-- selected lines, each change that made them as they are, newest first,
-- with who made it, when, its description and its diff. Agents get the
-- same as the `why` tool, so asking "why does this check exist?" comes
-- with the commits that added it.
--
-- With git it's `git log -L`, every commit that touched the lines. With jj
-- it's the changes that last touched each line, from `jj file annotate`,
-- each with its whole diff to the file.
local greed = require("@greed")
local core = require("@core")
local agent = require("@agent")
local multibuffer = require("@multibuffer")
local diffs = require("./diffs")
local repos = require("./repo")

type Repo = repos.Repo

local M = {}

-- How many changes are shown at most.
local LIMIT = 20

local TEMPLATE = 'change_id.shortest(8) ++ "  " ++ author.name() ++ "  " '
	.. '++ committer.timestamp().ago() ++ if(current_working_copy, "  (the working copy)") '
	.. '++ "\\n\\n" ++ description ++ "\\n"'

local function jj_history(
	repo: Repo,
	relative: string,
	first: number,
	last: number
): (string?, string?)
	local file = `root-file:"{(string.gsub(relative, '["\\]', "\\%0"))}"`
	local annotated = repos.run(repo, {
		"file",
		"annotate",
		"-T",
		'commit.change_id().shortest(8) ++ "\\n"',
		"--",
		-- A path, not a fileset, here.
		relative,
	}, true)
	if annotated == nil then
		return nil, "jj has no history for this file"
	end
	local ids: { string }, seen: { [string]: boolean } = {}, {}
	local lines = string.split(annotated, "\n")
	for line = first, math.min(last, #lines) do
		local id = lines[line]
		if id ~= "" and not seen[id] then
			seen[id] = true
			table.insert(ids, id)
		end
	end
	if #ids == 0 then
		return nil, "no history for these lines"
	end
	-- Newest first, as jj orders them.
	local ordered = repos.run(repo, {
		"log",
		"--no-graph",
		"-r",
		table.concat(ids, " | "),
		"-T",
		'change_id.shortest(8) ++ "\\n"',
	}, false) or table.concat(ids, "\n")
	local parts = {}
	for id in string.gmatch(ordered, "[^\n]+") do
		if #parts >= LIMIT then
			break
		end
		local about = repos.run(repo, { "log", "--no-graph", "-r", id, "-T", TEMPLATE }) or id
		local diff = repos.run(repo, { "diff", "--git", "--color", "never", "-r", id, "--", file })
			or ""
		table.insert(parts, about .. "\n" .. diff)
	end
	return table.concat(parts, "\n"), nil
end

local function git_history(
	repo: Repo,
	relative: string,
	first: number,
	last: number
): (string?, string?)
	local text = repos.run(repo, {
		"log",
		`-n{LIMIT}`,
		"--no-color",
		"--format=%h  %an  %ar%n%n%B",
		`-L{first},{last}:{relative}`,
	})
	if text == nil or text == "" then
		return nil, "git has no history for these lines"
	end
	return text, nil
end

--- The history of lines `first` to `last` (from 1) of the file at `path`:
--- each change that made them as they are, newest first. Nil and why not.
function M.history(path: string, first: number, last: number): (string?, string?)
	local absolute = core.project.resolve(path)
	local repo = repos.repo_of(absolute)
	if repo == nil then
		return nil, "the file isn't in a repository"
	end
	local relative = string.sub(absolute, #repo.root + 2)
	local text, err
	if repo.kind == "jj" then
		text, err = jj_history(repo, relative, first, last)
	else
		text, err = git_history(repo, relative, first, last)
	end
	if text == nil then
		return nil, err
	end
	local which = if first == last then `line {first}` else `lines {first}-{last}`
	return `Why {which} of {relative} are as they are\n\n{text}`, nil
end

greed.command({
	name = "why-lines",
	doc = "Show how the selected lines came to be: each change that made them, with its description and diff",
	run = function(ctx)
		local path = ctx.buffer:path()
		if path == nil then
			greed.echo("this buffer has no file")
			return
		end
		local selection = ctx.view:selection()
		local range = selection.ranges[selection.primary]
		local from, to = math.min(range.anchor, range.head), math.max(range.anchor, range.head)
		local first = ctx.buffer:line_of(from) + 1
		local last = ctx.buffer:line_of(math.max(from, to - 1)) + 1
		local text, err = M.history(path, first, last)
		if text == nil then
			greed.echo(err :: string)
			return
		end
		multibuffer.show(diffs.buffer("why", text), "Why")
	end,
})

agent.tool({
	name = "why",
	group = "history",
	description = "How some lines of a file came to be: each change that made them as they are, newest first, with who, when, its description and diff",
	input = {
		type = "object",
		properties = {
			path = { type = "string" },
			from_line = { type = "integer", description = "First line, from 1" },
			to_line = { type = "integer", description = "Last line; the first if left out" },
		},
		required = { "path", "from_line" },
	},
	run = function(args)
		local text, err = M.history(args.path, args.from_line, args.to_line or args.from_line)
		if text == nil then
			error(err, 0)
		end
		return text
	end,
})

greed.keymap.bind("normal", { ["space g w"] = "why-lines" })
greed.keymap.bind({ mode = "normal", kind = "why" }, { q = "multibuffer-close" })

return M
