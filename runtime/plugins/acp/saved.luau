-- Sessions you can take up again, kept in the cache folder: which agent,
-- where it worked, its ACP session and what you asked it first.

local greed = require("@greed")
local session = require("./session")

type Session = session.Session

local M = {}

export type Saved = {
	agent: string,
	root: string,
	workspace: session.Workspace?,
	session_id: string,
	title: string,
	time: number,
}

local function saved_file(): string?
	local cache = greed.fs.dirs().cache
	return if cache then `{cache}/agents.json` else nil
end

local function read_saved(file: string?): { any }
	local text = if file then greed.fs.read(file) else nil
	local all = if text then greed.json.decode(text) else nil
	return if type(all) == "table" then all else {}
end

--- The sessions you can take up again for the project at `root`, newest
--- first, leaving out those of `running` that still run.
function M.list(root: string, running: { Session }): { Saved }
	local out: { Saved } = {}
	for _, entry in read_saved(saved_file()) do
		local live = false
		for _, s in running do
			live = live or (s.session_id == entry.session_id and s.status ~= "exited")
		end
		if entry.root == root and not live then
			table.insert(out, entry)
		end
	end
	table.sort(out, function(a: Saved, b: Saved)
		return a.time > b.time
	end)
	return out
end

-- What `s` was asked first, if anything yet.
local function first_asked(s: Session): string?
	for _, entry in s.entries do
		if entry.kind == "user" and entry.text then
			return entry.text
		end
	end
	return nil
end

--- Keeps `s` to take up again, or with `forget`, stops keeping it.
function M.remember(s: Session, forget: boolean?)
	local file = saved_file()
	if file == nil or s.session_id == nil then
		return
	end
	local kept: { any } = {}
	for _, entry in read_saved(file) do
		if entry.session_id ~= s.session_id then
			table.insert(kept, entry)
		end
	end
	if not forget then
		local first = first_asked(s)
		table.insert(kept, {
			agent = s.agent,
			root = s.root,
			workspace = s.workspace,
			session_id = s.session_id,
			title = first and string.match(first, "^%s*([^\n]*)") or "(nothing asked yet)",
			time = os.time(),
		})
	end
	greed.fs.write(file, greed.json.encode(greed.json.array(kept)))
end

-- What each session was last kept as, so it's written only when that changes.
local kept_as: { [number]: string } = {}

--- Keeps `s` to take up again once it has an ACP session, again when what
--- it was first asked changes.
function M.keep(s: Session)
	local key = `{s.session_id}\0{first_asked(s) or ""}`
	if s.session_id and kept_as[s.id] ~= key then
		kept_as[s.id] = key
		M.remember(s)
	end
end

return M
