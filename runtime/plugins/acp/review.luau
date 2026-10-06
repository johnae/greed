-- What an agent changed in its workspace, shown as proposals on your
-- files to accept or reject change by change, instead of bringing it all
-- in at once.
--
-- Each file's change is merged three ways: the agent's edits are made
-- against the text it started from, so they're moved past what you
-- changed since, and the ones touching lines you changed too are left out
-- and named, for you to look at in its diff.

local greed = require("@greed")
local core = require("@core")
local agent = require("@agent")
local session = require("./session")

type Session = session.Session
type Change = { from: number, to: number, text: string }

local M = {}

-- Whether two changes to the same text touch: they overlap, or one goes
-- in where the other is.
local function touch(a: Change, b: Change): boolean
	if a.from == a.to or b.from == b.to then
		return a.from <= b.to and b.from <= a.to
	end
	return a.from < b.to and b.from < a.to
end

--- The agent's changes from `base` to `theirs`, moved onto `mine` (which
--- also started from `base`): changes to `mine`, sorted, and how many of
--- the agent's changes touched lines `mine` changed too and were left out.
--- Those already in `mine` are left out without counting.
function M.merge(base: string, theirs: string, mine: string): ({ Change }, number)
	local ours = greed.diff(base, mine)
	local out: { Change }, clashes = {}, 0
	for _, a in greed.diff(base, theirs) do
		local shift, clash, same = 0, false, false
		for _, m in ours do
			if m.from == a.from and m.to == a.to and m.text == a.text then
				same = true
			elseif touch(a, m) then
				clash = true
			elseif m.to <= a.from then
				shift += #m.text - (m.to - m.from)
			end
		end
		if not same then
			if clash then
				clashes += 1
			else
				table.insert(out, { from = a.from + shift, to = a.to + shift, text = a.text })
			end
		end
	end
	return out, clashes
end

-- Runs `args` in `cwd`; its output, or nil.
local function output(args: { string }, cwd: string): string?
	local done = greed.process.run(args, { cwd = cwd })
	if done == nil or done.code ~= 0 then
		return nil
	end
	return done.stdout
end

-- The files `s` changed in its workspace, relative to it, and how to get
-- one's text as the agent started from it ("" for a file it added).
local function changed(s: Session): ({ string }?, ((string) -> string)?, string?)
	local ws = assert(s.workspace)
	local names: string?
	local base: (string) -> string
	if ws.kind == "jj" then
		names = output({ "jj", "diff", "--name-only" }, ws.path)
		base = function(path)
			return output({ "jj", "file", "show", "-r", "@-", "--", path }, ws.path) or ""
		end
	else
		output({ "git", "add", "-A", "-N" }, ws.path)
		local from = ws.base or "HEAD"
		names = output({ "git", "diff", "--name-only", from }, ws.path)
		base = function(path)
			return output({ "git", "show", `{from}:{path}` }, ws.path) or ""
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

export type Reviewed = {
	--- What you decided, in words; nil when there was nothing to propose.
	decided: string?,
	--- What couldn't be proposed, a line per file, e.g. the lines it
	--- changed that you changed too.
	left: { string },
}

--- Proposes what `s` changed in its workspace on your files, as one
--- operation, and waits for you. Nil and why when it can't.
function M.review(s: Session): (Reviewed?, string?)
	local ws = s.workspace
	if ws == nil then
		return nil, "it works in the project itself; its changes are already there"
	end
	local names, base, err = changed(s)
	if names == nil or base == nil then
		return nil, err
	end
	local files: { agent.FileChanges } = {}
	local left: { string } = {}
	for _, name in names do
		local theirs = greed.fs.read(`{ws.path}/{name}`)
		local path = `{s.root}/{name}`
		if theirs == nil then
			table.insert(left, `{name}: deleted`)
		else
			local changes, clashes = M.merge(base(name), theirs, core.file.text(path) or "")
			if clashes > 0 then
				table.insert(left, `{name}: {clashes} changes to lines you changed too`)
			end
			if #changes > 0 then
				table.insert(files, { buffer = greed.load(path), path = path, changes = changes })
			end
		end
	end
	local decided = if #files > 0 then agent.propose_ranges(files, `what {s.name} changed`) else nil
	return { decided = decided, left = left }, nil
end

return M
