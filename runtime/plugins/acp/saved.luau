-- Sessions you can take up again. For an ACP agent that's which agent,
-- where it worked, its ACP session and what you asked it first, kept in
-- the cache folder; the agent tells the rest itself. Greed's own agent has
-- no one else to remember its conversations, so each is kept whole in the
-- data folder, per project, readable only by you.

local greed = require("@greed")
local models = require("@models")
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

--- What Greed's own agent keeps of a session to take it up again: what
--- was said as the model sees it, the transcript's entries, the role it
--- used and the tool groups it switched on.
export type Conversation = {
	id: string,
	agent: string,
	root: string,
	title: string,
	time: number,
	role: string,
	groups: { string },
	said: { models.Said },
	entries: { session.Entry },
}

-- How many of Greed's own sessions are kept per project; older ones go.
local function most_kept(): number
	local count = greed.option.get("agent-sessions-kept")
	return if type(count) == "number" then count else 50
end

-- The most of a tool's output kept to show again, in lines and characters,
-- and how many of a transcript's entries are kept.
local OUTPUT_LINES = 200
local OUTPUT_CHARS = 20000
local MAX_ENTRIES = 1000

local function saved_file(): string?
	local cache = greed.fs.dirs().cache
	return if cache then `{cache}/agents.json` else nil
end

local function read_json(file: string?): any
	local text = if file then greed.fs.read(file) else nil
	return if text then greed.json.decode(text) else nil
end

local function read_saved(file: string?): { any }
	local all = read_json(file)
	return if type(all) == "table" then all else {}
end

-- The folder Greed's own sessions for the project at `root` are kept in.
local function conversations(root: string): string?
	local dirs = greed.fs.dirs()
	local base = dirs.data or dirs.cache
	if base == nil then
		return nil
	end
	local name = string.gsub(string.match(root, "([^/]+)/*$") or "root", "[^%w._-]", "_")
	return `{base}/agent-sessions/{name}-{string.sub(greed.hash.sha256(root), 1, 12)}`
end

-- The kept sessions of a project as its index lists them: the one written
-- last first.
local function index_of(dir: string): { Saved }
	local all = read_json(`{dir}/index.json`)
	return if type(all) == "table" then all else {}
end

local function write_index(dir: string, index: { Saved })
	greed.fs.write(
		`{dir}/index.json`,
		greed.json.encode(greed.json.array(index)),
		{ private = true }
	)
end

--- The sessions you can take up again for the project at `root`, newest
--- first, leaving out those of `running` that still run.
function M.list(root: string, running: { Session }): { Saved }
	local out: { Saved } = {}
	local dir = conversations(root)
	local all = read_saved(saved_file())
	local own: { Saved } = if dir then index_of(dir) else {}
	table.move(own, 1, #own, #all + 1, all)
	for _, entry in all do
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

--- What `s` was asked first, if anything yet.
function M.first_asked(s: Session): string?
	for _, entry in s.entries do
		if entry.kind == "user" and entry.text then
			return entry.text
		end
	end
	return nil
end

-- The first line of what `s` was asked first, to tell it by.
local function title_of(s: Session): string
	local first = M.first_asked(s)
	return first and string.match(first, "^%s*([^\n]*)") or "(nothing asked yet)"
end

--- Stops keeping Greed's own session `id` for the project at `root`.
function M.discard(root: string, id: string)
	local dir = conversations(root)
	if dir == nil then
		return
	end
	local kept: { Saved } = {}
	for _, entry in index_of(dir) do
		if entry.session_id ~= id then
			table.insert(kept, entry)
		end
	end
	write_index(dir, kept)
	greed.fs.remove(`{dir}/{id}.json`)
end

--- Keeps `s` to take up again, or with `forget`, stops keeping it.
function M.remember(s: Session, forget: boolean?)
	if s.driver then
		-- Greed's own agent keeps its sessions as it goes (`store`).
		if forget and s.session_id then
			M.discard(s.root, s.session_id)
		end
		return
	end
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
		table.insert(kept, {
			agent = s.agent,
			root = s.root,
			workspace = s.workspace,
			session_id = s.session_id,
			title = title_of(s),
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
	local key = `{s.session_id}\0{M.first_asked(s) or ""}`
	if s.session_id and s.driver == nil and kept_as[s.id] ~= key then
		kept_as[s.id] = key
		M.remember(s)
	end
end

-- `lines` cut to what's kept of a tool's output.
local function bounded(lines: { string }): { string }
	local out: { string } = {}
	local size = 0
	for i, line in lines do
		if i > OUTPUT_LINES or size + #line > OUTPUT_CHARS then
			table.insert(out, `({#lines - i + 1} more lines not kept)`)
			break
		end
		size += #line + 1
		table.insert(out, line)
	end
	return out
end

-- An entry as it's written down, without what only means something while
-- the session runs, like the signal a question is answered by.
local function plain(entry: session.Entry): any
	local tool = entry.tool
	local permission = entry.permission
	return {
		kind = entry.kind,
		text = entry.text,
		items = entry.items,
		chosen = if permission then entry.chosen or "cancelled" else nil,
		permission = if permission
			then { title = permission.title, kind = permission.kind }
			else nil,
		tool = if tool
			then {
				id = tool.id,
				title = tool.title,
				kind = tool.kind,
				status = tool.status,
				locations = tool.locations,
				detail = tool.detail,
				output = bounded(tool.output),
			}
			else nil,
	}
end

--- Writes down Greed's own session `s`, with what was said and the role
--- and groups it has, to take up again, keeping the project's newest
--- `agent-sessions-kept`. The file is replaced whole and only you can read it. Nil and
--- why when it can't.
function M.store(
	s: Session,
	state: { role: string, groups: { string }, said: { models.Said } }
): (boolean?, string?)
	local dir = conversations(s.root)
	local id = s.session_id
	if dir == nil or id == nil then
		return nil, "there's nowhere to keep it"
	end
	local entries: { any } = {}
	for i = math.max(1, #s.entries - MAX_ENTRIES + 1), #s.entries do
		table.insert(entries, plain(s.entries[i]))
	end
	local conversation: Conversation = {
		id = id,
		agent = s.agent,
		root = s.root,
		title = title_of(s),
		time = os.time(),
		role = state.role,
		groups = greed.json.array(state.groups),
		-- A copy, since marking a table an array changes it.
		said = greed.json.array(table.move(state.said, 1, #state.said, 1, {})),
		entries = greed.json.array(entries),
	}
	-- Text that isn't UTF-8, like a binary file read, can't be JSON.
	local ok, text = pcall(greed.json.encode, conversation)
	if not ok then
		return nil, tostring(text)
	end
	local written, err = greed.fs.write(`{dir}/{id}.json`, text, { private = true })
	if not written then
		return nil, err
	end
	local index: { Saved } = {
		{
			agent = s.agent,
			root = s.root,
			session_id = id,
			title = conversation.title,
			time = conversation.time,
		},
	}
	local most = most_kept()
	for _, entry in index_of(dir) do
		if entry.session_id == id then
			continue
		elseif #index < most then
			table.insert(index, entry)
		else
			greed.fs.remove(`{dir}/{entry.session_id}.json`)
		end
	end
	write_index(dir, index)
	return true, nil
end

--- Greed's own session `id` for the project at `root` as it was written
--- down, ready to show again; nil if it's gone.
function M.load(root: string, id: string): Conversation?
	local dir = conversations(root)
	local kept = if dir then read_json(`{dir}/{id}.json`) else nil
	if type(kept) ~= "table" or type(kept.said) ~= "table" then
		return nil
	end
	local entries: { any } = if type(kept.entries) == "table" then kept.entries else {}
	for _, entry in entries do
		if entry.permission then
			entry.permission.options = {}
			entry.permission.answer = greed.signal()
		end
		if entry.tool then
			entry.tool.detail = entry.tool.detail or {}
			entry.tool.output = entry.tool.output or {}
			entry.tool.open = false
		end
	end
	kept.entries = entries
	kept.groups = if type(kept.groups) == "table" then kept.groups else {}
	return kept
end

return M
