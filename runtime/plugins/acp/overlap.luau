-- Agents in workspaces of their own changing the same files. Each works
-- without seeing the other's changes until you bring them in, so when one's
-- turn ends Greed compares what it changed with what the others in the
-- same project changed, and says so in both transcripts, once per file.

local session = require("./session")
local workspaces = require("./workspaces")

type Session = session.Session

local M = {}

-- What each session's agent had changed when last looked at, by id.
local seen: { [number]: { string } } = {}

-- The files each pair of sessions was told they share, by "id id file".
local told: { [string]: boolean } = {}

--- The files in `mine` that are also in `theirs`, in `mine`'s order.
function M.shared(mine: { string }, theirs: { string }): { string }
	local in_theirs: { [string]: boolean } = {}
	for _, file in theirs do
		in_theirs[file] = true
	end
	local both = {}
	for _, file in mine do
		if in_theirs[file] then
			table.insert(both, file)
		end
	end
	return both
end

-- Tells `s` that `other` changes `files` too.
local function warn(s: Session, other: Session, files: string)
	local text = `{other.name} changes {files} too; bringing both in may clash`
	table.insert(s.entries, { kind = "note", text = text })
	s.changed()
end

--- Compares what `s` changed in its workspace with what the other
--- sessions in `all` changed in theirs, for the same project, and says in
--- both transcripts which files they share, each file once per pair.
--- `changed` gives a session's changed files (`workspaces.changed` by
--- default).
function M.check(s: Session, all: { Session }, changed: ((Session) -> { string }?)?)
	local files_of: (Session) -> { string }? = changed
		or function(x: Session): { string }?
			return (workspaces.changed(x))
		end
	local mine = if s.workspace then files_of(s) else nil
	if mine == nil then
		return
	end
	seen[s.id] = mine
	for _, other in all do
		if
			other == s
			or other.workspace == nil
			or other.root ~= s.root
			or other.status == "exited"
		then
			continue
		end
		local theirs = seen[other.id] or files_of(other)
		if theirs == nil then
			continue
		end
		seen[other.id] = theirs
		local low, high = math.min(s.id, other.id), math.max(s.id, other.id)
		local new = {}
		for _, file in M.shared(mine, theirs) do
			local key = `{low} {high} {file}`
			if not told[key] then
				told[key] = true
				table.insert(new, file)
			end
		end
		if #new > 0 then
			local files = table.concat(new, ", ")
			warn(s, other, files)
			warn(other, s, files)
		end
	end
end

--- Forgets what `s` changed, as it closes.
function M.forget(s: Session)
	seen[s.id] = nil
end

return M
