-- Greed's own agent: a loop in the editor with a model from the models
-- plugin, rather than a program speaking ACP. It talks to any provider
-- the models plugin knows (Anthropic, or anything with OpenAI's API, like
-- berget or a local Ollama), uses the tools Greed offers every agent plus
-- editing files and running commands, and asks before it edits or runs
-- anything, the same way ACP agents ask. Its session is like theirs, so
-- the transcript, the session list and subagents work the same. Each
-- session is written down as it goes, to take up again (saved.luau), and
-- compacted as it nears the model's limit (compact.luau).

local greed = require("@greed")
local core = require("@core")
local agent = require("@agent")
local models = require("@models")
local vcs = require("@vcs")
local session = require("./session")
local saved = require("./saved")
local compact = require("./compact")
local transcript = require("./transcript")
local workspaces = require("./workspaces")
local auto = require("./auto")

type Session = session.Session

local M = {}

--- The role played by the model it uses, unless it's started with
--- another; without a model in that role it uses `reasoning`.
M.ROLE = "agent"
models.fallback(M.ROLE, "reasoning", "Greed's own agent")
models.fallback(compact.ROLE, M.ROLE, "compacting long conversations with Greed's agent")

-- How many steps go by between notes saying a prompt is still going; the
-- `agent-max-turns` option stops it, if set.
M.CHECK_IN = 200

-- Answers in a row that may be cut off at their length before it stops,
-- and what the model hears after one.
local MAX_CUTS = 2
local CUT_OFF = "Your answer was cut off: it was longer than one answer may be, so any tool "
	.. "call in it was lost and nothing ran. Go on in smaller pieces: write a long file with "
	.. "write_file holding its first part, then add the rest with edit_file, a part at a time."

-- What the model hears after a thought it was stopped in, at `size`
-- tokens (the `agent-max-thought` option); such thoughts count as cut
-- off too.
local function thought_cut(size: string): string
	return `Your thinking ran past {size} tokens before you acted, so it was stopped and nothing `
		.. "ran. Don't design it all in your head: write a short plan with plan_write if it "
		.. "helps, then take the first small step now and let tests and tools answer the rest."
end

-- Empty answers after a tool's result it goes on from in one prompt, and
-- what the model hears of one.
local MAX_EMPTIES = 2
local EMPTY = "\n\n(Your answer after this came back empty, with no text and no tool call. "
	.. "Go on with the task, or say what you found.)"

-- How many times a request the provider turns down as too long is compacted
-- and tried again.
local MAX_OVERFLOWS = 3

-- Calls the user rejects in one prompt before the turn stops to ask them:
-- a model told no can go round trying other ways to do the same.
local MAX_REJECTED = 2
local NOT_RUN_REJECTED = "not run: the user rejected a call before this"
local ASK_NOW = "\n\n(The turn stops here: no more calls run. Ask the user what they want, "
	.. "in a sentence or two, and say plainly what wasn't done.)"

-- What the model hears after a call that only reads which it made
-- already, and which came back the same.
local REPEATED = "\n\n(You made this same call already and got the same result. "
	.. "Asking again won't change it: try something else.)"

-- Calls in a row that only read or search before the model hears it's been
-- a while: models can go on looking long after trying would have told them
-- more.
local READS = 40
local READING = `\n\n({READS} calls reading and searching in a row. If you're making something, `
	.. "try a first version now and let its checks and tests answer the rest; if something's "
	.. "in the way, tell the user what. If you're only answering a question, carry on.)"

-- The most of a tool's result the model gets back, in characters and lines;
-- the rest of a longer one is in a file it can read on in. Such files go
-- after `OUTPUT_DAYS`.
local MAX_RESULT = 30000
local MAX_LINES = 2000
local OUTPUT_DAYS = 7

-- Takes away results kept longer than OUTPUT_DAYS.
local function clear_old_output(dir: string)
	local before = os.time() - OUTPUT_DAYS * 86400
	local entries = greed.fs.list(dir)
	if entries == nil then
		return
	end
	for _, entry in entries do
		local path = `{dir}/{entry.name}`
		local info = greed.fs.stat(path)
		if info and info.modified and info.modified < before then
			greed.fs.remove(path)
		end
	end
end

--- `text`, a tool's result, as the model gets it: whole when it's short
--- enough, else its start and where the whole of it is kept (under `name`),
--- to read on with `read` or search with `grep`, so nothing is lost.
function M.fit(text: string, name: string): string
	local _, breaks = string.gsub(text, "\n", "")
	if #text <= MAX_RESULT and breaks < MAX_LINES then
		return text
	end
	local lines = string.split(text, "\n")
	local shown, size = {}, 0
	for _, line in lines do
		if #shown >= MAX_LINES or size + #line + 1 > MAX_RESULT then
			break
		end
		table.insert(shown, line)
		size += #line + 1
	end
	local head = table.concat(shown, "\n")
	local dir = agent.output_dir()
	-- Only yours to read, as the conversations kept are.
	if dir == nil or not greed.fs.write(`{dir}/{name}.txt`, text, { private = true }) then
		return `{head}\n\n[showing lines 1-{#shown} of {#lines}; the rest was left out]`
	end
	clear_old_output(dir)
	return `{head}\n\n[showing lines 1-{#shown} of {#lines}; the whole result is in {dir}/{name}.txt: `
		.. `read it from line {#shown + 1} on with read's from_line, or search it with grep and that path]`
end

-- How long `run` waits for a command in the shell before it gets back that
-- it still runs, in seconds.
local RUN_SECONDS = 600

-- The most of a project's instructions (AGENTS.md, CLAUDE.md) it reads.
local MAX_INSTRUCTIONS = 20000

local ALLOW = {
	{ id = "once", name = "Allow once", kind = "allow_once" },
	{ id = "always", name = "Allow always", kind = "allow_always" },
	{ id = "no", name = "Reject", kind = "reject_once" },
}

-- What each session keeps between prompts.
type State = {
	said: { models.Said },
	role: string,
	cancelled: boolean,
	--- Kinds of tool calls you allowed for the rest of the session. They
	--- aren't kept with it: a session taken up again asks again.
	allowed: { [string]: boolean },
	--- The tool groups it switched on.
	caller: agent.Caller,
	--- Where it works, for its prompt: worked out at its first prompt.
	env: string?,
	--- The tokens the provider last said the conversation takes, and how
	--- many messages of `said` that counted.
	reported: { tokens: number, at: number }?,
	--- The tools' names in the order it first had them, which stays.
	order: { string },
	--- How its model edits files (models.edits), worked out each prompt.
	edits: string?,
	--- Goes up each time a turn is stopped, so what a stopped turn left
	--- running (a stream, a tool call) changes nothing when it ends.
	run: number,
	--- What the model's answer or the tool call going on now is waited
	--- for with, and what closes the answer's stream: stopping the turn
	--- uses them to end it at once.
	waiting: greed.Signal?,
	close: (() -> ())?,
	--- It only reads and searches: it's offered no tool that changes
	--- anything, as a helper working in the project (`read_only`).
	reads_only: boolean?,
}

--- The tool groups Greed's own agent has from the start, besides those
--- the `agent-tool-groups` option gives every agent.
M.GROUPS = { "subagents" }

-- What the model hears of a call stopped as it ran, and of those after it.
local STOPPED = "the user stopped the turn while this ran; it may have done part of its work"
local NOT_RUN = "not run: the user stopped the turn first"

-- Runs `f` in a task of its own and waits for what it returns, unless the
-- turn is stopped first: then it's false at once, and `f` is left to end
-- on its own.
local function unless_stopped(state: State, f: () -> (any, any, any)): (boolean, any, any, any)
	if state.cancelled then
		return false, nil, nil, nil
	end
	local done = greed.signal()
	state.waiting = done
	greed.spawn(function()
		local ok, a, b, c = pcall(f)
		done:send({ ok = ok, a = a, b = b, c = c })
	end)
	local got = done:wait()
	state.waiting = nil
	if got == false then
		return false, nil, nil, nil
	elseif not got.ok then
		error(got.a, 0)
	end
	return true, got.a, got.b, got.c
end

-- Whether call `c` may run at once with calls like it next to it: its tool
-- says so, and it doesn't ask you first.
local function side_by_side(by_name: { [string]: any }, c: models.Call): boolean
	local found = by_name[c.name]
	return found ~= nil and found.parallel == true and not agent.asks(found)
end

-- Runs `f` on each of `items` at once, each in a task of its own, waits
-- for them all and returns what each gave, in order. One failing fails it.
local function together(items: { any }, f: (any) -> any): { any }
	if #items == 1 then
		return { f(items[1]) }
	end
	local out = table.create(#items)
	local left = #items
	local all = greed.signal()
	local failure = nil
	for k, item in items do
		greed.spawn(function()
			local ok, value = pcall(f, item)
			if ok then
				out[k] = value
			else
				failure = failure or value
			end
			left -= 1
			if left == 0 then
				all:send(true)
			end
		end)
	end
	all:wait()
	if failure then
		error(failure, 0)
	end
	return out
end

local states: { [number]: State } = {}

--- Who Greed's agent in `s` calls Greed's tools as, or nil for another
--- agent's session.
function M.caller(s: Session): agent.Caller?
	local state = states[s.id]
	return if state then state.caller else nil
end

-- The session and the row of each of Greed's tools running for Greed's
-- agent, by the thread it runs in.
local calling: { [thread]: { session: Session, tool: session.Tool } } = setmetatable(
	{},
	{ __mode = "k" }
) :: any

--- The session of Greed's agent whose call of one of Greed's tools runs
--- in this thread, and that call's row in its transcript, e.g. for the
--- tool to show how it's going there.
function M.calling(): (Session?, session.Tool?)
	local found = calling[coroutine.running()]
	if found == nil then
		return nil, nil
	end
	return found.session, found.tool
end

-- What a tool says after changing the file at `path` (in full) through
-- `buffer`, with what its language server reports about it then.
local function changed(said: string, buffer: greed.Buffer?, path: string): string
	local found = if buffer then agent.problems_after({ buffer }) else nil
	if found then
		said ..= `\n{found}`
	end
	-- The user's config runs again now, so a mistake in it shows here: the
	-- language server can't tell a setting that doesn't exist.
	if core.config.is_config(path) then
		local ok, err = core.config.reload()
		said ..= if ok
			then "\nthe config ran again without errors"
			else `\nthe config failed when it ran again: {err}`
	end
	return said
end

-- A tool of the agent's own: what the model is told, the kind of call it
-- is (for asking you), and what it does.
type Own = {
	--- Offered only when the model edits this way (models.edits).
	edits: string?,
	spec: models.ToolSpec,
	kind: string,
	title: (args: any) -> string,
	run: (s: Session, args: any) -> string,
	--- What the call would let a plugin do that it couldn't (agent.widens).
	widens: ((s: Session, args: any) -> string?)?,
	--- Why the call is risky (`kubectl delete`), as a tool's `danger` says.
	danger: ((args: any) -> string?)?,
	--- The change it would make, as lines starting "- " (gone) and "+ "
	--- (new), shown on its row before you're asked.
	preview: ((s: Session, args: any) -> { string })?,
	--- The files it changes, as full paths, which its questions name. One
	--- outside the project asks apart (session.may_write).
	paths: ((s: Session, args: any) -> { string })?,
}

-- What gives the full paths in the fields `keys` of a call's arguments,
-- those that are strings.
local function paths_in(keys: { string }): (s: Session, args: any) -> { string }
	return function(s, args)
		local out = {}
		for _, key in keys do
			if type(args[key]) == "string" then
				table.insert(out, core.project.resolve(args[key], s.cwd))
			end
		end
		return out
	end
end
local PATH = paths_in({ "path" })

-- The most lines of a change shown before you're asked.
local PREVIEW_LINES = 200

-- `text`'s lines, each after `mark`, into `out`, up to PREVIEW_LINES in all.
local function marked(out: { string }, mark: string, text: string)
	for _, line in string.split(text, "\n") do
		if #out >= PREVIEW_LINES then
			return
		end
		table.insert(out, mark .. line)
	end
end

-- What changes from `old` to `new`, marked as above.
local function diffed(old: string, new: string): { string }
	local out = {}
	for _, hunk in greed.diff(old, new) do
		local gone = string.sub(old, hunk.from + 1, hunk.to)
		if gone ~= "" then
			marked(out, "- ", (string.gsub(gone, "\n$", "")))
		end
		if hunk.text ~= "" then
			marked(out, "+ ", (string.gsub(hunk.text, "\n$", "")))
		end
	end
	return out
end

local object = agent.schema.object

-- What each session's agent last saw of each file, by session and full
-- path, as a hash of the file's whole text: from reading, editing or
-- writing it. write_file won't write over a file that changed since, or
-- that it never saw.
local seen_by: { [number]: { [string]: string } } = {}

local function seen(s: Session): { [string]: string }
	local files = seen_by[s.id]
	if files == nil then
		files = {}
		seen_by[s.id] = files
	end
	return files
end

local function saw(s: Session, path: string, text: string)
	seen(s)[core.project.resolve(path, s.cwd)] = greed.hash.sha256(text)
end

local function last_seen(s: Session, path: string): string?
	return seen(s)[core.project.resolve(path, s.cwd)]
end

-- Whether `text` of `path` is other than what `s`'s agent last saw of it.
local function changed_since(s: Session, path: string, text: string): boolean
	local last = last_seen(s, path)
	return last ~= nil and last ~= greed.hash.sha256(text)
end

-- The 1-based line of byte `at` in `text`.
local function line_at(text: string, at: number): number
	local _, breaks = string.gsub(string.sub(text, 1, at - 1), "\n", "")
	return breaks + 1
end

-- Where `needle` is in `text`, as byte offsets, without overlaps.
local function places(text: string, needle: string): { number }
	local out = {}
	local from = 1
	while true do
		local at = string.find(text, needle, from, true)
		if at == nil then
			return out
		end
		table.insert(out, at)
		from = at + #needle
	end
end

-- `s` without the spaces around it.
local function trimmed(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or s
end

-- Words a model writes in place of code it left out, like
-- "// ... existing code ..." or "# rest of file unchanged".
local ELIDED = { "existing code", "unchanged", "rest of", "remaining", "omitted", "same as before" }

-- The first line of `new` that stands in for text left out, with its number,
-- unless `old` has it too: written to the file it would take the text's place.
local function elision(new: string, old: string): (number?, string?)
	for n, line in string.split(new, "\n") do
		local bare = string.lower(trimmed(line))
		local comment = string.match(bare, "^[/#%-;%*<%(%[]") ~= nil
			or string.find(bare, "^%.%.%.") ~= nil
		local dots = string.find(bare, "...", 1, true) or string.find(bare, "…", 1, true)
		if comment and dots and #bare < 80 and not string.find(old, trimmed(line), 1, true) then
			for _, words in ELIDED do
				if string.find(bare, words, 1, true) then
					return n, trimmed(line)
				end
			end
		end
	end
	return nil, nil
end

-- Fails when `new`, going into `path` in place of `old`, leaves text out.
local function check_elision(path: string, new: string, old: string)
	local n, line = elision(new, old)
	if n then
		error(
			`line {n} of what you'd write to {path}, "{line}", stands in for text left out; `
				.. "it would replace that text in the file. Give the text itself, or change only "
				.. "the parts that change with edit_file",
			0
		)
	end
end

-- Why `old` isn't in `text` of `path`, with what's nearest, so the model
-- can put it right without reading the whole file again.
local function missing(path: string, text: string, old: string, stale: boolean): string
	local said = `old_text isn't in {path}`
	if stale then
		return said
			.. "; the file changed since you last read it (the user may be editing it), so read it again"
	end
	local wanted = {}
	for _, line in string.split(old, "\n") do
		if trimmed(line) ~= "" then
			table.insert(wanted, trimmed(line))
		end
	end
	if #wanted == 0 then
		return said
	end
	local lines = string.split(text, "\n")
	local starts = {}
	for n, line in lines do
		if trimmed(line) == wanted[1] then
			table.insert(starts, n)
		end
	end
	for _, n in starts do
		-- The same lines with other spacing or indentation.
		local i, w = n, 1
		while i <= #lines and w <= #wanted do
			if trimmed(lines[i]) == wanted[w] then
				w += 1
			elseif trimmed(lines[i]) ~= "" then
				break
			end
			i += 1
		end
		if w > #wanted then
			return `{said} as written, but it is on line {n} with other spacing or indentation: `
				.. "copy it exactly as read gives it"
		end
	end
	if #starts > 0 then
		local at = table.concat(starts, ", ", 1, math.min(#starts, 5))
		return `{said}: its first line is on line {at}, but what follows differs; read from there`
	end
	return `{said}, nor its first line: read the file again`
end

-- `text` with each place `old` is (just the first unless `all`) made `new`.
local function replaced(text: string, old: string, new: string, all: boolean): string
	local out = {}
	local from = 1
	for _, at in places(text, old) do
		table.insert(out, string.sub(text, from, at - 1))
		table.insert(out, new)
		from = at + #old
		if not all then
			break
		end
	end
	table.insert(out, string.sub(text, from))
	return table.concat(out)
end

type Change = { old_text: string, new_text: string, replace_all: boolean? }

-- The changes an edit_file call asks for: its `edits`, or the one it gives.
-- `value`, the list of edits a model gave: some send it as JSON text, which
-- is read; anything else fails, with what one looks like (`example`).
local function edits_list(value: any, example: string): { any }
	if type(value) == "string" then
		local ok, decoded = pcall(greed.json.decode, value)
		value = if ok then decoded else nil
	end
	if type(value) ~= "table" then
		error(`edits should be a list of edits, like [{example}]`, 0)
	end
	return value
end

local function changes_of(args: any): { Change }
	local changes: { Change } = {}
	if args.old_text ~= nil or args.new_text ~= nil then
		table.insert(
			changes,
			{ old_text = args.old_text, new_text = args.new_text, replace_all = args.replace_all }
		)
	end
	if args.edits ~= nil then
		local more = edits_list(args.edits, '{"old_text": "...", "new_text": "..."}')
		table.move(more, 1, #more, #changes + 1, changes)
	end
	if #changes == 0 then
		error("old_text and new_text are missing: the text to change, and what it becomes", 0)
	end
	-- Weaker models leave a part out; say which.
	for n, change in changes do
		local which = if #changes > 1 then `edit {n}: ` else ""
		if type(change.old_text) ~= "string" then
			error(`{which}old_text is missing: the text to change, as the file has it`, 0)
		elseif type(change.new_text) ~= "string" then
			error(`{which}new_text is missing: the text old_text becomes ("" to delete it)`, 0)
		end
	end
	return changes
end

-- `text` of `path` with `changes` made in order; fails saying which and why
-- when one can't be, and then none is.
local function apply(path: string, text: string, changes: { Change }, stale: boolean): string
	for n, change in changes do
		local which = if #changes > 1 then `edit {n} of {#changes}: ` else ""
		local none = if #changes > 1 then " (none of the edits were made)" else ""
		if change.old_text == "" then
			error(`{which}old_text is empty{none}`, 0)
		end
		check_elision(path, change.new_text, text)
		local at = places(text, change.old_text)
		if #at == 0 then
			error(which .. missing(path, text, change.old_text, stale) .. none, 0)
		elseif #at > 1 and not change.replace_all then
			local lines = {}
			for i = 1, math.min(#at, 10) do
				table.insert(lines, tostring(line_at(text, at[i])))
			end
			error(
				`{which}old_text is in {path} {#at} times, on lines {table.concat(lines, ", ")}: `
					.. `give more of it to pick one, or set replace_all{none}`,
				0
			)
		end
		text = replaced(text, change.old_text, change.new_text, change.replace_all == true)
	end
	return text
end

-- How many bytes `a` and `b` share at their start and, after that, at
-- their end, kept to whole characters.
local function shared(a: string, b: string): (number, number)
	local most = math.min(#a, #b)
	local head = 0
	-- A block at a time first: files are long and edits small.
	while
		head + 4096 <= most
		and string.sub(a, head + 1, head + 4096) == string.sub(b, head + 1, head + 4096)
	do
		head += 4096
	end
	while head < most and string.byte(a, head + 1) == string.byte(b, head + 1) do
		head += 1
	end
	-- Not in the middle of a character.
	while head > 0 and bit32.band(string.byte(a, head + 1) or 0, 0xC0) == 0x80 do
		head -= 1
	end
	local tail = 0
	local left = most - head
	while
		tail + 4096 <= left
		and string.sub(a, #a - tail - 4095, #a - tail)
			== string.sub(b, #b - tail - 4095, #b - tail)
	do
		tail += 4096
	end
	while tail < left and string.byte(a, #a - tail) == string.byte(b, #b - tail) do
		tail += 1
	end
	while tail > 0 and bit32.band(string.byte(a, #a - tail + 1) or 0, 0xC0) == 0x80 do
		tail -= 1
	end
	return head, tail
end

-- The most lines an edit's result shows of what it changed.
local SHOWN_LINES = 30

-- The lines of `text`; an empty file is one empty line, for a hashline
-- edit to name.
local function lines_of(text: string): { string }
	return if text == "" then { "" } else core.text.split_lines(text)
end

-- A short hash of `line`, which with its number names it in hashline
-- edits: three hex digits of its FNV-1a hash.
local function line_hash(line: string): string
	local h = 2166136261
	for i = 1, #line do
		h = bit32.bxor(h, string.byte(line, i))
		-- Times FNV's prime, 2^24 + 403, kept to 32 bits without losing any.
		h = (bit32.lshift(h, 24) + h * 403) % 4294967296
	end
	return string.format("%03x", bit32.band(h, 0xFFF))
end

-- Line `n` of `lines` as the model sees it: numbered, and with its hash
-- when it edits by hashlines ("12#a3f|text": the bar, not spaces, so the
-- line's own leading spaces can't be mistaken for padding).
local function shown_line(lines: { string }, n: number, anchors: boolean): string
	if anchors then
		return `{n}#{line_hash(lines[n])}|{lines[n]}`
	end
	return string.format("%6d  %s", n, lines[n])
end

-- `text`, a read from line `first` on, with each line named by its number
-- and hash, as a model editing by hashlines reads files.
local function anchored(text: string, first: number): string
	local lines = lines_of(text)
	local out = table.create(#lines)
	for n, line in lines do
		out[n] = `{first + n - 1}#{line_hash(line)}|{line}`
	end
	return table.concat(out, "\n")
end

-- Lines `first` to `last` (1-based) of `text`, numbered as an editor shows
-- them, with two more on each side.
local function numbered(text: string, first: number, last: number, anchors: boolean): string
	local lines = lines_of(text)
	local from, to = math.max(first - 2, 1), math.min(last + 2, #lines)
	local out = {}
	for n = from, math.min(to, from + SHOWN_LINES - 1) do
		table.insert(out, shown_line(lines, n, anchors))
	end
	if to > from + SHOWN_LINES - 1 then
		table.insert(out, `       (… to line {to})`)
	end
	return table.concat(out, "\n")
end

-- Writes `new` in place of `text`, the file at `path`, changing only the
-- part that differs, and returns what the model hears: the changed lines,
-- numbered (with hashes when `anchors`), and new problems.
local function write_change(
	s: Session,
	path: string,
	text: string,
	new: string,
	anchors: boolean
): string
	agent.memory.guard(path, s.cwd)
	-- Through its buffer (opened if need be), so undo takes it back, cursors
	-- elsewhere stay put and its language server sees it.
	local head, tail = shared(text, new)
	local buffer = core.file.write(
		path,
		string.sub(new, head + 1, #new - tail),
		{ root = s.cwd, from = head, to = #text - tail, load = true }
	)
	saw(s, path, new)
	local first = line_at(new, head + 1)
	local last = math.max(line_at(new, #new - tail), first)
	return changed(
		`edited {path}:\n{numbered(new, first, last, anchors)}`,
		buffer,
		core.project.resolve(path, s.cwd)
	)
end

-- An edit by hashlines: lines `from` to `to` (or just `from`) replaced by
-- `text`, or `text` put in after line `after` ("0" for the top).
type LineEdit = { from: string?, to: string?, after: string?, text: string }

-- The line of `lines` that `anchor` ("12#a3f") names: line 12 if its hash
-- is still a3f, else the one line nearest it that has that hash (lines
-- moved by an edit above); fails when it's gone.
local function resolve_anchor(path: string, lines: { string }, anchor: string): number
	local number, hash = string.match(anchor, "^%s*(%d+)#(%x%x%x)")
	local n = tonumber(number)
	if string.match(anchor, "^%s*%d+%s*$") then
		error(
			`"{anchor}" needs its hash too: copy the line's name as read gives it, like 12#a3f`,
			0
		)
	elseif n == nil or hash == nil then
		error(`"{anchor}" isn't a line as read gives them, like 12#a3f`, 0)
	end
	hash = string.lower(hash)
	if lines[n] and line_hash(lines[n]) == hash then
		return n
	end
	local nearest: number? = nil
	for i, line in lines do
		if
			line_hash(line) == hash and (nearest == nil or math.abs(i - n) < math.abs(nearest - n))
		then
			nearest = i
		end
	end
	if nearest then
		return nearest
	end
	local now = if lines[n] then `; it's now "{lines[n]}"` else ""
	error(`line {anchor} of {path} isn't as you read it{now}: read it again`, 0)
end

-- `text` of `path` with `edits` made, or a failure saying which and why,
-- and then none is made.
local function apply_lines(path: string, text: string, given: any): string
	local edits: { LineEdit } = edits_list(given, '{"from": "12#a3f", "text": "..."}')
	local lines = string.split(text, "\n")
	type Span = { from: number, to: number, lines: { string }, n: number }
	local spans: { Span } = {}
	for n, e in edits do
		local which = if #edits > 1 then `edit {n} of {#edits}: ` else ""
		local ok, err = pcall(function()
			if type(e.text) ~= "string" then
				error("give each edit its text", 0)
			end
			check_elision(path, e.text, text)
			local new: { string } = if e.text == ""
				then {}
				else string.split((string.gsub(e.text, "\n$", "")), "\n")
			-- With both, from: models name the line they replace as where
			-- the text goes, too.
			if e.from then
				local from = resolve_anchor(path, lines, e.from)
				local to = if e.to then resolve_anchor(path, lines, e.to) else from
				if to < from then
					error(`{e.to} comes before {e.from}`, 0)
				end
				table.insert(spans, { from = from, to = to, lines = new, n = n })
			elseif e.after then
				local at = if e.after == "0" then 0 else resolve_anchor(path, lines, e.after)
				table.insert(spans, { from = at + 1, to = at, lines = new, n = n })
			else
				error("give from (and to) for lines to replace, or after for where to add lines", 0)
			end
		end)
		if not ok then
			local none = if #edits > 1 then " (none of the edits were made)" else ""
			error(which .. tostring(err) .. none, 0)
		end
	end
	table.sort(spans, function(a: Span, b: Span)
		return a.from < b.from
	end)
	for i = 2, #spans do
		if spans[i].from <= spans[i - 1].to then
			error(
				`edits {spans[i - 1].n} and {spans[i].n} change the same lines (none were made)`,
				0
			)
		end
	end
	-- From the bottom up, so the lines above keep their numbers.
	for i = #spans, 1, -1 do
		local span = spans[i]
		for _ = span.from, span.to do
			table.remove(lines, span.from)
		end
		for k, line in span.lines do
			table.insert(lines, span.from + k - 1, line)
		end
	end
	return table.concat(lines, "\n")
end

local OWN: { Own } = {
	{
		edits = "replace",
		spec = {
			name = "edit_file",
			description = "Replace text in a file: `old_text` must appear in it exactly once (give enough "
				.. "lines around it to be sure), and becomes `new_text`; with replace_all, every place "
				.. "it is does. More changes to the same file can follow in `edits`: they're all made "
				.. "in order, as one change, or none is. An open file is edited as the user has it, and "
				.. "saved. Returns the changed lines, numbered, and new problems the language server sees",
			input = object({
				path = { type = "string" },
				old_text = { type = "string" },
				new_text = { type = "string" },
				replace_all = {
					type = "boolean",
					description = "Change every place old_text is, not just one",
				},
				edits = {
					type = "array",
					description = "More changes to the same file, made after this one",
					items = object({
						old_text = { type = "string" },
						new_text = { type = "string" },
						replace_all = { type = "boolean" },
					}, { "old_text", "new_text" }),
				},
			}, { "path", "old_text", "new_text" }),
		},
		kind = "edit",
		paths = PATH,
		title = function(args)
			return `Edit {args.path}`
		end,
		preview = function(_, args)
			local out = {}
			local ok, changes = pcall(changes_of, args)
			if ok then
				for _, change in changes do
					marked(out, "- ", change.old_text)
					marked(out, "+ ", change.new_text)
				end
			end
			return out
		end,
		widens = function(s, args)
			local text = core.file.text(args.path, s.cwd)
			if text == nil then
				return nil
			end
			local ok, new = pcall(function()
				return apply(args.path, text, changes_of(args), false)
			end)
			return if ok then agent.widens(args.path, text, new) else nil
		end,
		run = function(s, args)
			local text = core.file.text(args.path, s.cwd)
			if text == nil then
				error(`there's no file {args.path}`, 0)
			end
			local new = apply(args.path, text, changes_of(args), changed_since(s, args.path, text))
			return write_change(s, args.path, text, new, false)
		end,
	},
	{
		edits = "hashline",
		spec = {
			name = "edit_file",
			description = "Change lines of a file, named as read gives them: in `12#a3f|  let x = 1;` "
				.. "the name is 12#a3f (the line's number and a hash of its text), and after the bar "
				.. "is the line itself, its indentation included. `text` is whole lines, indented as "
				.. "they should be. Each edit replaces lines `from` to `to` (or just "
				.. "`from`) with `text`, which may be several lines or empty to delete them, or puts "
				.. '`text` in after line `after` ("0" for the top). Copy the names exactly; never '
				.. "retype the old lines. The edits are made together, or none is. An open file is "
				.. "edited as the user has it, and saved. Returns the changed lines with their new "
				.. "names, for more edits without reading again, and new problems the language "
				.. "server sees",
			input = object({
				path = { type = "string" },
				edits = {
					type = "array",
					items = object({
						from = {
							type = "string",
							description = "The first line to replace, e.g. 12#a3f",
						},
						to = {
							type = "string",
							description = "The last line to replace; from if left out",
						},
						after = {
							type = "string",
							description = "The line to add text after, in place of from",
						},
						text = { type = "string" },
					}, { "text" }),
				},
			}, { "path", "edits" }),
		},
		kind = "edit",
		paths = PATH,
		title = function(args)
			return `Edit {args.path}`
		end,
		preview = function(s, args)
			local text = core.file.text(args.path, s.cwd)
			if text == nil then
				return {}
			end
			local ok, new = pcall(apply_lines, args.path, text, args.edits or {})
			return if ok then diffed(text, new) else {}
		end,
		widens = function(s, args)
			local text = core.file.text(args.path, s.cwd)
			if text == nil then
				return nil
			end
			local ok, new = pcall(apply_lines, args.path, text, args.edits or {})
			return if ok then agent.widens(args.path, text, new) else nil
		end,
		run = function(s, args)
			local text = core.file.text(args.path, s.cwd)
			if text == nil then
				error(`there's no file {args.path}`, 0)
			end
			return write_change(s, args.path, text, apply_lines(args.path, text, args.edits), true)
		end,
	},
	{
		spec = {
			name = "write_file",
			description = "Write a file's whole text, making it (and its folders) if it's new",
			input = object(
				{ path = { type = "string" }, text = { type = "string" } },
				{ "path", "text" }
			),
		},
		kind = "edit",
		paths = PATH,
		title = function(args)
			return `Write {args.path}`
		end,
		preview = function(s, args)
			-- Only what changes, for a file that's there already.
			return diffed(core.file.text(args.path, s.cwd) or "", args.text)
		end,
		widens = function(s, args)
			return agent.widens(args.path, core.file.text(args.path, s.cwd), args.text)
		end,
		run = function(s, args)
			-- Writing over a file needs its agent to have seen it as it is
			-- now: the user may have changed it, and their change would go.
			local old = core.file.text(args.path, s.cwd)
			if old and old ~= args.text then
				if last_seen(s, args.path) == nil then
					error(
						`{args.path} is there already and you haven't read it: read it first, `
							.. "or change it with edit_file",
						0
					)
				elseif changed_since(s, args.path, old) then
					error(
						`{args.path} changed since you last read it (the user may be editing it): `
							.. "read it again, then change it with edit_file",
						0
					)
				end
			end
			check_elision(args.path, args.text, old or "")
			agent.memory.guard(args.path, s.cwd)
			local buffer = core.file.write(args.path, args.text, { root = s.cwd, load = true })
			saw(s, args.path, args.text)
			local said = `wrote {args.path}`
			-- Much shorter than it was, which may not be what it meant.
			local before = if old then #string.split(old, "\n") else 0
			local after = #string.split(args.text, "\n")
			if before >= 40 and after < before / 2 then
				said ..= ` (it went from {before} lines to {after})`
			end
			return changed(said, buffer, core.project.resolve(args.path, s.cwd))
		end,
	},
	{
		spec = {
			name = "move_file",
			description = "Move or rename a file or folder; files open in the editor go along",
			input = object(
				{ from = { type = "string" }, to = { type = "string" } },
				{ "from", "to" }
			),
		},
		kind = "move",
		paths = paths_in({ "from", "to" }),
		title = function(args)
			return `Move {args.from} to {args.to}`
		end,
		run = function(s, args)
			local from = core.project.resolve(args.from, s.cwd)
			local to = core.project.resolve(args.to, s.cwd)
			if greed.fs.stat(from) == nil then
				error(`there's no {args.from}`, 0)
			end
			agent.memory.guard(args.from, s.cwd)
			agent.memory.guard(args.to, s.cwd)
			core.file.rename(from, to)
			return `moved {args.from} to {args.to}`
		end,
	},
	{
		spec = {
			name = "delete_file",
			description = "Delete a file, or a folder and everything in it",
			input = object({ path = { type = "string" } }, { "path" }),
		},
		kind = "delete",
		paths = PATH,
		title = function(args)
			return `Delete {args.path}`
		end,
		run = function(s, args)
			local path = core.project.resolve(args.path, s.cwd)
			agent.memory.guard(args.path, s.cwd)
			core.file.remove(path)
			return `deleted {args.path}`
		end,
	},
	{
		spec = {
			name = "run",
			description = "Run a shell command in the project's folder and get what it printed and how "
				.. "it exited: for tests, builds, version control. Don't use it to read or search files; "
				.. "read, grep and files see unsaved changes",
			input = object({ command = { type = "string" } }, { "command" }),
		},
		kind = "execute",
		title = function(args)
			return `Run {args.command}`
		end,
		danger = function(args)
			return if type(args.command) == "string" then core.risk.of(args.command) else nil
		end,
		run = function(s, args)
			-- As a block of the project's shell when there is one: you see
			-- it there (◆), and it runs with the project's environment.
			for _, tool in agent.tools() do
				if tool.name == "shell_run" then
					local call = { command = args.command, cwd = s.cwd, timeout_s = RUN_SECONDS }
					return agent.as_text(tool.run(call, agent.caller()))
				end
			end
			local done, err = greed.process.run({ "sh", "-c", args.command }, { cwd = s.cwd })
			if done == nil then
				error(err or "it didn't start", 0)
			end
			local out = done.stdout .. (if done.stderr ~= "" then "\n" .. done.stderr else "")
			-- Someone else wrote it, and it may hold secrets.
			local said = agent.untrusted(`what \`{args.command}\` printed`, out)
			return `{said}\n(exit {done.code or "killed"})`
		end,
	},
}

-- The project's own instructions for agents, if it has them.
local function instructions(root: string): string?
	for _, name in { "AGENTS.md", "CLAUDE.md", ".github/copilot-instructions.md" } do
		local text = greed.fs.read(`{root}/{name}`)
		if text then
			return `{name}:\n\n{string.sub(text, 1, MAX_INSTRUCTIONS)}`
		end
	end
	return nil
end

-- What `command` (a shell command line) prints in `cwd`, trimmed, or nil
-- when it fails.
local function output(command: string, cwd: string): string?
	local done = greed.process.run({ "sh", "-c", command }, { cwd = cwd })
	if done == nil or done.code ~= 0 then
		return nil
	end
	local text = string.match(done.stdout, "^%s*(.-)%s*$")
	return if text and text ~= "" then text else nil
end

-- How many lines `args` print in `repo`, or "?" when they fail.
local function count(repo: vcs.Repo, args: { string }): string
	local text = vcs.repo.run(repo, args)
	return if text then tostring(select(2, string.gsub(text, "\n", ""))) else "?"
end

-- Where the agent works, as lines for its prompt: the system and shell,
-- and the project's version control. Worked out once a session.
local function environment(root: string): string
	local lines = {}
	local system_name = output("uname -sr", root)
	local shell_name = output('basename "${SHELL:-sh}"', root)
	if system_name then
		table.insert(lines, `The system is {system_name}; the shell is {shell_name or "sh"}.`)
	end
	local repo = vcs.repo.repo_of(root .. "/.")
	if repo and repo.kind == "jj" then
		local described = vcs.repo.trimmed(
			repo,
			{ "log", "-r", "@", "--no-graph", "-T", "description.first_line()" }
		)
		table.insert(
			lines,
			`The project is a jj repository (use jj, not git). The working copy's change `
				.. (if described then `is "{described}"` else "has no description yet")
				.. `, with {count(repo, { "diff", "--name-only" })} files changed when the session started.`
		)
	elseif repo then
		local branch = vcs.repo.trimmed(repo, { "rev-parse", "--abbrev-ref", "HEAD" })
		local changed = count(repo, { "status", "--porcelain" })
		table.insert(
			lines,
			`The project is a git repository on branch {branch or "?"}, with {changed} `
				.. "files changed when the session started."
		)
	end
	return table.concat(lines, " ")
end

-- What the model is told about where it is and how to work.
-- Where the user's config is and how settings change there, for asks like
-- "make tabs 2 spaces in Lua".
local function config_note(): string
	local config = greed.fs.dirs().config
	if config == nil then
		return "The user has no config folder, so settings can't be kept."
	end
	return `The user's Greed config is {config}/init.luau, Luau that runs as Greed starts and `
		.. 'again when saved. Settings go there: options with require("@greed").option.set '
		.. '(describe an option to see its name and values), a language\'s with require("@languages"), '
		.. 'the theme with require("@theme").use(name). Edit it with edit_file or write_file, '
		.. "keeping what's there; don't look for it anywhere else."
end

local function system(
	s: Session,
	env: string?,
	edits: string?,
	helpers: boolean,
	model: string?
): string
	local how = if edits == "hashline"
		then "Read gives each line a name (12#a3f): edit with edit_file by those names."
		else "Edit with edit_file, giving enough of the old text to match once."
	-- Models know little of themselves, and a conversation that went on
	-- from another model would have them say they're that one.
	local running = if model then ` The model answering is {model}.` else ""
	local lines = {
		"You are Greed's coding agent, working in the Greed editor with the user. You can read and "
			.. "search the project, edit files and run commands with the tools you have."
			.. running,
		(
			if s.workspace
				then workspaces.note(s.workspace, s.root)
				else `The project is at {s.root}; paths are relative to it.`
		) .. (if env and env ~= "" then " " .. env else ""),
		"A user's message starts with a <time> tag, when they sent it, and may have an "
			.. "<editor-context> block: what they had on screen as they wrote it, and a "
			.. "<pinned-context> block: what they pinned for you, as it is now. They're left out "
			.. "when nothing changed since their last message.",
		"Before answering how something works, why it behaves as it does, or how to build or "
			.. "change something, read the code and docs the answer depends on; don't reason from "
			.. "names or memory. Say plainly when you haven't checked something. A plain request "
			.. "(add a todo, open a file, run a command) you just do.",
		"Find your way with focus (what the user is looking at), symbols, grep and files before "
			.. "reading whole files. Files are read as the user has them, unsaved changes included. "
			.. how,
		"More tools come in groups you switch on with the tools tool when you need them. Look "
			.. "there first for what they cover, like the user's notes and todos, rather than "
			.. "searching the project:\n"
			.. agent.groups_text(),
		"When the user asks for something new in Greed itself (a command, keys, a panel, an "
			.. "integration like a GitHub client), build it as a plugin with the plugins group: "
			.. "plugin_guide, then plugin_try until it passes, then plugin_install, which installs "
			.. "it in their own config after they review it. Don't write it into the project, even "
			.. "when the project is Greed's own code, unless they ask you to change the project.",
		config_note(),
		"Keep your plan for bigger tasks with plan_read and plan_write, where the user sees and "
			.. "changes it. Follow the decisions the decisions tool lists as accepted.",
		"Keep your thoughts short: plan in a few lines with plan_write rather than designing "
			.. "everything in your head, then work in small steps and let tests and tools answer "
			.. "questions.",
		"When the user rejects a call, don't make it again or get the same effect another way "
			.. "(another tool, a command or eval): ask them what they want, and don't say it was "
			.. "done.",
		agent.untrusted_note,
		"Be brief: say what you did and what's left, not every step.",
		agent.memory.prompt(s.root),
	}
	if helpers then
		table.insert(
			lines,
			"Hand a wide search or survey whose details would fill your context, a side task or "
				.. "a second opinion to a helper with subagent; calls of it in one answer run at "
				.. "once. Not for one quick lookup."
		)
	end
	if greed.option.get("agent-care") ~= "quick" then
		table.insert(
			lines,
			"For design, architecture and explain-the-system questions, or a task touching several "
				.. "areas, first map what exists"
				.. (if helpers
					then ": hand a survey of each relevant area to a helper, several at once, and "
						.. "answer from their findings."
					else ".")
				.. ' End such answers with a short "Checked:" line (files or areas read) and '
				.. '"Not checked:" where it applies. Prefer a correct answer to a fast one.'
		)
	end
	local found = instructions(s.root)
	if found then
		table.insert(lines, "The project's instructions for agents follow.\n\n" .. found)
	end
	return table.concat(lines, "\n\n")
end

-- Greed's tools for agents it doesn't get: its own edits ask first and show
-- the change, and a proposal left for review let a model think it had
-- changed a file it hadn't.
local LEFT_OUT = { propose = true }

-- What a tool (one of its own, or Greed's) does, as ACP names tool kinds.
local function kind_of(tool: Own | agent.Tool): string
	return (tool :: any).kind or "read"
end

-- The tools the model is told about now (Greed's tools for agents in the
-- groups it has, and its own), and every tool it may call, by name, with
-- what to do for each.
local function tools(state: State): ({ models.ToolSpec }, { [string]: Own | agent.Tool })
	local offered: { [string]: models.ToolSpec } = {}
	local by_name: { [string]: Own | agent.Tool } = {}
	local function may(tool: agent.Tool): boolean
		return not LEFT_OUT[tool.name] and not (state.reads_only and kind_of(tool) ~= "read")
	end
	for _, tool in agent.offered(state.caller) do
		if may(tool) then
			offered[tool.name] =
				{ name = tool.name, description = tool.description, input = tool.input }
		end
	end
	for _, tool in agent.tools() do
		if may(tool) and not tool.shell_only then
			by_name[tool.name] = tool
		end
	end
	-- Its own tools all change something.
	if not state.reads_only then
		for _, own in OWN do
			if own.edits == nil or own.edits == (state.edits or "replace") then
				offered[own.spec.name] = own.spec
				by_name[own.spec.name] = own
			end
		end
	end
	-- In the order the session first had them: tools of a group switched on
	-- later come last, so the list before them, which providers cache, stays.
	local order = state.order
	local known: { [string]: boolean } = {}
	for _, name in order do
		known[name] = true
	end
	local fresh = {}
	for name in offered do
		if not known[name] then
			table.insert(fresh, name)
		end
	end
	table.sort(fresh)
	table.move(fresh, 1, #fresh, #order + 1, order)
	local specs: { models.ToolSpec } = {}
	for _, name in order do
		local spec = offered[name]
		if spec then
			table.insert(specs, spec)
		end
	end
	return specs, by_name
end

-- Whether you let `kind` of call happen, asking unless you allowed it for
-- the session (or a policy answers).
local function allowed(
	s: Session,
	state: State,
	title: string,
	kind: string,
	locations: { string }?,
	command: string?
): (boolean, string?, string?)
	if state.allowed[kind] then
		return true, nil, nil
	end
	local chosen, note, by = session.ask(s, title, kind, ALLOW, locations, nil, command)
	if chosen == "always" then
		state.allowed[kind] = true
	end
	return chosen == "once" or chosen == "always", note, by
end

-- A call by its tool and arguments, to tell when it's made again.
local function call_key(c: models.Call): string
	return c.name .. " " .. greed.json.encode(c.input)
end

-- The call you rejected this prompt that `c` could do the same as: the
-- same call again (`rejected` holds them by call_key), or, after you
-- rejected one without saying what to do instead, one that runs code or
-- commands (eval, run_command). Nil when `c` may run.
local function like_rejected(
	refused: { agent.Refusal },
	rejected: { [string]: string },
	by_name: { [string]: any },
	c: models.Call
): string?
	local again = rejected[call_key(c)]
	if again then
		return again
	end
	local found = by_name[c.name]
	if found == nil or kind_of(found) ~= "execute" then
		return nil
	end
	-- Only one that ran code or commands itself: rejecting an edit doesn't
	-- stop the tests that follow.
	for _, one in refused do
		local was = by_name[one.tool]
		if one.note == nil and was and kind_of(was) == "execute" then
			return one.title
		end
	end
	return nil
end

-- Runs one call the model asked for and returns what it gets back, and
-- whether that's an error.
local function call(
	s: Session,
	state: State,
	by_name: { [string]: any },
	c: models.Call
): (string, boolean)
	local run = state.run
	local found = by_name[c.name]
	if found == nil then
		return `there's no tool called {c.name}`, true
	end
	local own = if found.spec then found :: Own else nil
	local registered = if own then nil else found :: agent.Tool
	-- Its own tools look up their file by `path` before they run, to ask
	-- you and show the change: without one, the model hears what's missing.
	local input = own and own.spec.input
	local properties = input and input.properties
	if
		properties
		and properties.path
		and (type(c.input) ~= "table" or type(c.input.path) ~= "string")
	then
		return `{c.name} needs path, the file it works on`, true
	end
	local kind = kind_of(found)
	-- The files it touches, as its questions name them: its own tools say,
	-- Greed's name one by their path.
	local locations = if own and own.paths
		then own.paths(s, c.input)
		elseif type(c.input.path) == "string" then { core.project.resolve(c.input.path, s.cwd) }
		else nil
	if locations and #locations == 0 then
		locations = nil
	end
	local tool: session.Tool = {
		id = c.id,
		title = if own then own.title(c.input) else agent.title(c.name, c.input, s.root),
		kind = kind,
		status = "pending",
		locations = locations,
		detail = {},
		output = {},
		open = false,
	}
	s.tools[c.id] = tool
	table.insert(s.entries, { kind = "tool", tool = tool })
	s.tool = tool.title
	if locations then
		s.where = { path = locations[1] }
	end
	s.changed()
	-- Its own tools all change something; Greed's ask unless they only
	-- read or put what they do in front of you themselves.
	local asks = own ~= nil or (registered ~= nil and agent.asks(registered))
	-- What it would change, on its row before you're asked: tab shows it.
	local before = if own and own.preview then own.preview(s, c.input) else nil
	if before and #before > 0 then
		local removed, added = 0, 0
		for _, line in before do
			if string.sub(line, 1, 1) == "-" then
				removed += 1
			else
				added += 1
			end
		end
		tool.output = before
		tool.detail = { `-{removed} +{added} · tab shows the change` }
		s.changed()
	end
	-- One letting a plugin do more asks you, and only you, every time.
	local widens = if own and own.widens then own.widens(s, c.input) else nil
	-- A risky call asks you, and only you, every time.
	local danger = if own
		then (if own.danger then own.danger(c.input) else nil)
		else agent.danger(registered :: agent.Tool, c.input)
	-- A change outside the project asks apart, whatever you allowed always;
	-- in a workspace of its own it can't change anything outside.
	local outside = if own and own.paths and locations then session.outside(s, locations) else nil
	local refused, blocked_by = nil, nil
	if outside and locations then
		refused, blocked_by = session.may_write(s, tool.title, kind, locations)
	end
	if refused and auto.said(blocked_by) then
		-- Auto mode said no, not you: the agent hears why, to find another way.
		refused = auto.refusal(blocked_by :: string)
	end
	-- Whether you were asked and said no, and what you wrote then.
	local rejected: boolean, told: string? =
		refused ~= nil and s.workspace == nil and not auto.said(blocked_by), nil
	if refused == nil then
		local title = if widens
			then `{tool.title}, which {widens}`
			elseif danger then `{tool.title}: {danger}`
			else nil
		local command = if kind == "execute" and type(c.input.command) == "string"
			then c.input.command
			else nil
		local ok, note, by = true, nil, nil
		if title then
			-- Only you answer, unless it's a risky command auto mode may
			-- leave to the decision model.
			local firm = widens ~= nil
				or command == nil
				or not auto.on(s)
				or auto.hard(command) ~= nil
			local chosen, said, policy =
				session.ask(s, title, kind, session.ONCE, locations, firm, command)
			ok, note, by = chosen == "once", said, policy
		elseif asks and not outside then
			ok, note, by = allowed(s, state, tool.title, kind, locations, command)
		end
		if not ok and auto.said(by) then
			-- Auto mode blocked it: the agent hears why, to find another
			-- way, and it isn't counted as you saying no.
			refused = auto.refusal(by :: string)
		elseif not ok then
			local why = if widens then session.NOT_WIDENED else "the user didn't allow it"
			refused = session.refused(why, note)
			rejected, told = true, note
		end
	end
	if refused then
		if rejected then
			local list = state.caller.refused or {}
			state.caller.refused = list
			table.insert(list, { tool = c.name, title = tool.title, note = told })
		end
		tool.status = "failed"
		s.tool = nil
		return refused, true
	end
	tool.status = "in_progress"
	s.changed()
	local ok, result = pcall(function(): string
		if own then
			return own.run(s, c.input)
		end
		local spec = registered :: agent.Tool
		local wrong = agent.check(spec, c.input)
		if wrong then
			error(wrong, 0)
		end
		-- A path from where it works, as its own tools take them: Greed's
		-- shared ones go from the project shown, which may be another. An
		-- object's id (buffer:12) stays as it is.
		local input = c.input
		local path = input.path
		if
			type(path) == "string"
			and not string.match(path, "^[/~]")
			and not core.objects.is_id(path)
		then
			input = table.clone(input)
			input.path = core.project.resolve(path, s.cwd)
		end
		local thread = coroutine.running()
		calling[thread] = { session = s, tool = tool }
		-- In a workspace of its own, Greed's tools search and read there.
		local ran, value = pcall(function()
			return if s.workspace
				then core.project.within(s.cwd, function()
					return spec.run(input, state.caller)
				end)
				else spec.run(input, state.caller)
		end)
		calling[thread] = nil
		if not ran then
			error(value, 0)
		end
		local said = agent.as_text(value)
		-- Each line named, for a model that edits by hashlines.
		if c.name == "read" and state.edits == "hashline" then
			said = anchored(said, tonumber(input.from_line) or 1)
		end
		return said
	end)
	local text = if ok then result else agent.error_text(result)
	-- The turn was stopped while it ran, and its row says so already.
	if state.run ~= run then
		return text, not ok
	end
	-- How edits go, by model and how they're made, to tell which way works.
	if own and own.spec.name == "edit_file" then
		local chosen = models.resolve(models.playing(state.role))
		if chosen then
			models.count_edit(chosen.provider, chosen.model, state.edits or "replace", ok)
		end
	end
	tool.status = if ok then "completed" else "failed"
	local lines = string.split(text, "\n")
	while #lines > 0 and lines[#lines] == "" do
		table.remove(lines)
	end
	-- A failure's first line says why; the rest is there unfolded.
	local summary = session.summary(if ok then lines else { lines[1] }, s.root)
	tool.detail = if summary then { summary } else {}
	tool.output = lines
	s.tool = nil
	return M.fit(text, `{s.id}-{c.id}`), not ok
end

-- Adds `text` to the agent's last words in the transcript (or what it
-- thought, by `kind`), or starts them.
local function say(s: Session, text: string, kind: string?)
	session.append(s, kind or "agent", text)
	s.doing = if kind == "thought" then "thinking" else "writing"
	s.changed()
end

-- What `s` does now, for its status, redrawn when it changes.
local function doing(s: Session, what: string)
	if s.doing ~= what then
		s.doing = what
		s.changed()
	end
end

-- Writes `s` down to take up again, once it has been asked something.
-- When each session was last written down, so a long tool loop writes its
-- whole conversation every couple of seconds rather than at every step.
local kept_at: { [number]: number } = {}
local KEEP_EVERY = 2000

local function keep(s: Session, state: State, soon: boolean?)
	if saved.first_asked(s) == nil then
		return
	end
	local now = greed.now()
	if soon and now - (kept_at[s.id] or 0) < KEEP_EVERY then
		return
	end
	kept_at[s.id] = now
	local groups = {}
	for group, on in state.caller.groups do
		if on then
			table.insert(groups, group)
		end
	end
	table.sort(groups)
	saved.store(s, { role = state.role, groups = groups, said = state.said })
end

-- About how many tokens the next request takes, with `extra` characters
-- (its system prompt and tools) when the provider hasn't said yet.
local function estimate(state: State, extra: number): number
	local reported = state.reported
	if reported then
		return reported.tokens + compact.tokens(state.said, reported.at + 1)
	end
	return compact.tokens(state.said, 1, extra)
end

-- Replaces all but the end of what `s` said (as much as `tail` tokens hold)
-- with the model's summary of it, shown in the transcript as a folded row
-- with the summary in it. False and why when it can't.
local function compact_now(s: Session, state: State, tail: number?): (boolean, string?)
	local upto = compact.cut(state.said, tail or compact.keep((models.window(state.role))))
	if upto == nil then
		return false, "there's too little to compact yet"
	end
	local before = s.tool
	s.tool = "compacting the conversation"
	s.changed()
	local role = if models.roles[compact.ROLE] then compact.ROLE else state.role
	local summary, err = compact.summarise(role, state.said, upto)
	s.tool = before
	if summary == nil then
		table.insert(
			s.entries,
			{ kind = "note", text = `couldn't compact the conversation: {err}` }
		)
		s.changed()
		return false, err
	end
	state.said = compact.replace(state.said, upto, summary)
	state.reported = nil
	s.tokens = compact.tokens(state.said)
	local tool: session.Tool = {
		id = `compact-{greed.now()}-{#s.entries}`,
		title = `conversation compacted ({upto - 1} messages → summary)`,
		kind = "other",
		status = "completed",
		detail = {},
		output = string.split(summary, "\n"),
		open = false,
	}
	s.tools[tool.id] = tool
	table.insert(s.entries, { kind = "tool", tool = tool })
	keep(s, state)
	s.changed()
	return true, nil
end

-- Turns a prompt into an answer: the model's turns, and the tools it asks
-- for between them, until it's done.
local function prompt(
	s: Session,
	text: string,
	context: string?,
	shown: string?,
	images: { session.Attachment }?
): (boolean, string?)
	local state = states[s.id]
	if s.status == "working" or s.status == "waiting" then
		return false, "the agent is still working; stop it first"
	end
	state.cancelled = false
	s.failed = nil
	table.insert(s.entries, { kind = "user", text = shown or text })
	local fresh = session.fresh_context(s, context)
	local sent = `<time>{os.date("%A %Y-%m-%d %H:%M %Z")}</time>`
	local said = if fresh then `{sent}\n{fresh}\n\n{text}` else `{sent}\n{text}`
	-- Images go by their files' paths, read each time a request is made.
	local paths: { string } = {}
	if images then
		for _, image in images do
			table.insert(paths, image.path)
		end
	end
	table.insert(
		state.said,
		{ role = "user", text = said, images = if #paths > 0 then paths else nil } :: models.Said
	)
	s.status = "working"
	s.since = greed.now()
	s.changed()
	state.env = state.env or environment(s.cwd)
	-- The same from turn to turn, so providers can cache it: the time goes
	-- in each of your messages instead.
	state.edits = models.edits(state.role)
	local playing = models.resolve(models.playing(state.role))
	local model = if playing then `{playing.model}, served by {playing.provider}` else nil
	local said_system = system(s, state.env, state.edits, not state.reads_only, model)
	-- Once a summary fails, it isn't asked for again until the next prompt.
	local may_compact = true
	-- Answers cut off at their length in a row.
	local cuts = 0
	-- Empty answers after a tool's result, sent back to go on from.
	local empties = 0
	-- Requests the provider turned down as too long, compacted and tried again.
	local overflows = 0
	-- What each call (tool and arguments) gave back this prompt.
	local seen: { [string]: string } = {}
	-- Calls that only read in a row, and whether it heard about them.
	local reads, nudged = 0, false
	-- What you rejected this prompt, also by call_key; once the turn stops
	-- over them, the model's next answer, to ask you, is its last.
	local refused: { agent.Refusal } = {}
	state.caller.refused = refused
	local rejected_calls: { [string]: string } = {}
	local asking = false
	local most = tonumber(greed.option.get("agent-max-turns")) or 0
	local turns = 0
	-- The session's token limit, once it's reached.
	local spent_all: number? = nil
	while most <= 0 or turns < most do
		local budget = tonumber(greed.option.get("agent-max-tokens")) or 0
		if budget > 0 and (s.spent or 0) >= budget then
			spent_all = budget
			break
		end
		turns += 1
		if turns % M.CHECK_IN == 0 then
			table.insert(
				s.entries,
				{ kind = "note", text = `this has taken {turns} steps; carrying on` }
			)
		end
		-- Again each turn, for the groups it switched on in the last.
		local specs, by_name = tools(state)
		local window = models.window(state.role)
		local room = compact.room(window, models.output(state.role))
		local at = greed.option.get("agent-compact-at")
		if type(at) == "number" and at > 0 then
			room = math.min(room, at)
		end
		local extra = #said_system + #greed.json.encode(specs)
		local tail = compact.keep(window)
		if may_compact and estimate(state, extra) > room and compact.cut(state.said, tail) then
			may_compact = compact_now(s, state, tail)
		end
		local run = state.run
		local chosen = models.resolve(state.role)
		local waiting = `waiting for {if chosen then chosen.provider else "the model"}`
		doing(s, waiting)
		-- A thought past `cap` tokens stops the request; what it thought is kept.
		local max_thought = greed.option.get("agent-max-thought")
		local cap = if type(max_thought) == "number" then max_thought else 0
		local thought: { string } = {}
		local thought_size = 0
		local overthought = false
		local answered, answer, err, again = unless_stopped(state, function()
			return models.turn(state.role, {
				system = said_system,
				said = state.said,
				tools = specs,
				cache_key = s.session_id,
				effort = s.effort,
			}, function(piece)
				if state.run == run then
					say(s, piece)
				end
			end, function(close)
				if state.run == run then
					state.close = close
				else
					close()
				end
			end, function(piece)
				if state.run ~= run or overthought then
					return
				end
				say(s, piece, "thought")
				table.insert(thought, piece)
				thought_size += #piece
				if cap > 0 and compact.estimate(thought_size) > cap then
					overthought = true
					if state.close then
						state.close()
					end
				end
			end, function()
				if state.run == run then
					doing(s, "writing")
				end
			end, function(why, ms)
				if state.run == run then
					local wait = if ms >= 1000 then ` in {math.floor(ms / 1000 + 0.5)}s` else ""
					table.insert(s.entries, { kind = "note", text = `{why}; trying again{wait}` })
					s.doing = waiting
					s.changed()
				end
			end)
		end)
		state.close = nil
		-- Stopped for thinking too long, which this prompt treats as an
		-- answer that ran out of room. The thought goes back to the model,
		-- with `thinking_back`, without Anthropic's signatures: a thought
		-- cut short has none.
		local turn: models.Turn? = if answered and overthought
			then {
				text = if answer then answer.text else "",
				calls = {},
				stop = "length",
				thinking = table.concat(thought),
			} :: models.Turn
			else answer
		if not answered then
			break
		elseif turn == nil then
			-- Too long for the model after all, as the estimate can be off:
			-- compacted, keeping half as much of the end each time, it's
			-- tried again, a few times at most.
			local smaller = tail * 0.5 ^ (overflows + 1)
			if
				compact.too_long(err)
				and overflows < MAX_OVERFLOWS
				and compact.cut(state.said, smaller)
			then
				overflows += 1
				if compact_now(s, state, smaller) then
					continue
				end
			end
			local failed = `the model failed: {err}`
			if again then
				failed ..= "; say go on to try again"
			end
			s.failed = failed
			table.insert(s.entries, { kind = "note", text = failed })
			break
		end
		-- It answered, so nothing keeps it from working.
		s.problem = nil
		-- An answer cut off at its length may end in half a tool call, so
		-- none of its calls run; the model hears why and goes on in parts.
		local cut = turn.stop == "length"
		-- Asked to ask you, it gets no more calls.
		local calls = if cut or asking then {} else turn.calls
		table.insert(
			state.said,
			{
				role = "assistant",
				text = turn.text,
				calls = calls,
				thinking = turn.thinking,
				signed = turn.signed,
			} :: models.Said
		)
		if turn.tokens then
			state.reported = { tokens = turn.tokens, at = #state.said }
		end
		s.tokens = turn.tokens or s.tokens
		s.spent = (s.spent or 0) + (turn.input or 0) + (turn.output or 0)
		if asking then
			break
		elseif cut then
			cuts += 1
			if cuts > MAX_CUTS then
				local why = if overthought
					then "stopped: its thoughts kept running too long"
					else "stopped: the answer ran out of room"
				table.insert(s.entries, { kind = "note", text = why })
				break
			end
			local note, heard = "the answer ran out of room; going on", CUT_OFF
			if overthought then
				-- 8k rather than 8.0k.
				local size = (string.gsub(transcript.tokens(cap), "%.0k$", "k"))
				note = `stopped a thought at {size} tokens; asking for smaller steps`
				heard = thought_cut(size)
			end
			table.insert(s.entries, { kind = "note", text = note })
			table.insert(state.said, { role = "user", text = heard } :: models.Said)
			s.changed()
			continue
		end
		cuts = 0
		-- An empty answer right after a tool's result: models that think
		-- first sometimes stop there. The empty answer goes (providers turn
		-- one down), and the result says so, to go on from.
		local previous = state.said[#state.said - 1]
		if
			#turn.calls == 0
			and not string.find(turn.text, "%S")
			and previous
			and previous.role == "tool"
			and empties < MAX_EMPTIES
		then
			empties += 1
			table.remove(state.said)
			previous.text = (previous.text or "") .. EMPTY
			continue
		end
		if turn.stop ~= "tools" or #turn.calls == 0 then
			break
		end
		-- Stops the turn over `title`, which you rejected: calls from
		-- `from` on don't run, and the model hears it must ask you.
		local function stop_to_ask(from: number, title: string)
			for k = from, #turn.calls do
				table.insert(
					state.said,
					{
						role = "tool",
						call = turn.calls[k].id,
						text = NOT_RUN_REJECTED,
						error = true,
					} :: models.Said
				)
			end
			local last = state.said[#state.said]
			last.text = (last.text or "") .. ASK_NOW
			table.insert(
				s.entries,
				{ kind = "note", text = `stopped: you rejected {title}; asking what you want` }
			)
			asking = true
			s.changed()
		end
		-- Gives the model what call `c` came back with, and says whether the
		-- turn stops to ask you: you rejected calls too often.
		local function took(
			c: models.Call,
			result: string,
			failed: boolean,
			rejected: boolean
		): boolean
			local tool = s.tools[c.id]
			local key = call_key(c)
			if rejected then
				rejected_calls[key] = refused[#refused].title
			end
			-- A call that only reads, made already this prompt and coming back
			-- the same, says so: a model can go round asking the same thing.
			-- One that changes something, or that you rejected, doesn't: told
			-- to try something else, a model tries to get past you.
			if tool and tool.kind == "read" and not rejected then
				local before = seen[key]
				seen[key] = result
				if before == result then
					result ..= REPEATED
				end
			end
			-- What it read is what it saw, for writing over it later.
			if c.name == "read" and not failed and type(c.input.path) == "string" then
				local now = core.file.text(c.input.path, s.cwd)
				if now then
					saw(s, c.input.path, now)
				end
			end
			-- Asking the user counts as doing something, as an edit does.
			reads = if tool and tool.kind == "read" and c.name ~= "ask" then reads + 1 else 0
			if reads >= READS and not nudged then
				nudged = true
				result ..= READING
			end
			table.insert(
				state.said,
				{ role = "tool", call = c.id, text = result, error = failed } :: models.Said
			)
			s.changed()
			return rejected and #refused >= MAX_REJECTED
		end
		local i = 1
		while i <= #turn.calls do
			local like = like_rejected(refused, rejected_calls, by_name, turn.calls[i])
			if like then
				stop_to_ask(i, like)
				break
			end
			-- Calls that may run at once, like helpers each on a task, start
			-- together.
			local batch = { turn.calls[i] }
			while side_by_side(by_name, batch[1]) do
				local after = turn.calls[i + #batch]
				if after == nil or not side_by_side(by_name, after) then
					break
				end
				table.insert(batch, after)
			end
			local rejections = #refused
			local ran, results = unless_stopped(state, function()
				return together(batch, function(one: models.Call): { any }
					return { call(s, state, by_name, one) }
				end)
			end)
			if not ran then
				-- Every call the model asked for gets a result, or the next
				-- request is turned down.
				for k = i, #turn.calls do
					local id = turn.calls[k].id
					local tool = s.tools[id]
					if tool and tool.status ~= "completed" and tool.status ~= "failed" then
						tool.status = "failed"
						tool.detail = { "stopped" }
					end
					table.insert(
						state.said,
						{
							role = "tool",
							call = id,
							text = if tool then STOPPED else NOT_RUN,
							error = true,
						} :: models.Said
					)
				end
				s.tool = nil
				break
			end
			local stopped = false
			for k, c in batch do
				local result: string, failed: boolean = results[k][1], results[k][2]
				-- Calls that run together don't ask you, so only one alone
				-- can have been rejected.
				local rejected = #batch == 1 and #refused > rejections
				if took(c, result, failed, rejected) then
					stop_to_ask(i + k, refused[#refused].title)
					stopped = true
					break
				end
			end
			if stopped then
				break
			end
			i += #batch
		end
		if state.cancelled then
			keep(s, state)
			break
		end
		-- What you sent while it worked goes with the last result, as a
		-- word from you: a message of yours after a tool's result would end
		-- the model's turn for some providers.
		local queued, pasted = session.take_queued(s)
		if queued then
			local last = state.said[#state.said]
			local words, entry = queued, queued
			if pasted then
				-- The images go with the result too, to a model that sees them.
				local sees = models.sees_images(state.role)
				words = `{queued}\n\n{session.about_images(pasted, sees)}`
				entry = if queued == ""
					then session.chips(pasted)
					else `{queued}\n{session.chips(pasted)}`
				if sees then
					local files: { string } = last.images or {}
					for _, image in pasted do
						table.insert(files, image.path)
					end
					last.images = files
				end
			end
			last.text = `{last.text or ""}\n\n[The user, while you worked: {words}]`
			table.insert(s.entries, { kind = "user", text = entry })
			s.changed()
		end
		keep(s, state, true)
	end
	if state.cancelled then
		table.insert(s.entries, { kind = "note", text = "stopped: cancelled" })
	end
	-- Stopped at the session's token limit, or still waiting for the
	-- model's answer to its tools' results: it ran out of turns.
	local last = state.said[#state.said]
	if spent_all then
		table.insert(s.entries, {
			kind = "note",
			text = `stopped: this session has used {s.spent} tokens, its limit is {spent_all} (agent-max-tokens); raise it with :set agent-max-tokens, then say go on`,
		})
	elseif last and last.role == "tool" and not state.cancelled and not s.failed then
		table.insert(s.entries, {
			kind = "note",
			text = `stopped: it took {most} turns without finishing (agent-max-turns); say go on to let it carry on`,
		})
	end
	s.status = "idle"
	keep(s, state)
	s.changed()
	return true, nil
end

-- The roles the models plugin knows, as the models to pick from.
local function roles(): { session.Mode }
	local list = {}
	for name, role in models.roles do
		if role then
			table.insert(
				list,
				{ id = name, name = name, description = `{role.model} at {role.provider}` }
			)
		end
	end
	table.sort(list, function(a: session.Mode, b: session.Mode)
		return a.id < b.id
	end)
	return list
end

-- Has `s` use the model playing `role`.
local function use(s: Session, state: State, role: string)
	state.role = role
	s.model = role
	s.window = models.window(role)
end

local DRIVER: session.Driver = {
	keeps = true,
	prompt = prompt,
	-- At once: the answer streaming in or the tool call running is left
	-- behind, and the stream closed.
	cancel = function(s)
		local state = states[s.id]
		state.cancelled = true
		state.run += 1
		local close, waiting = state.close, state.waiting
		state.close = nil
		if close then
			close()
		end
		if waiting then
			waiting:send(false)
		end
	end,
	set_model = function(s, id)
		if models.roles[id] == nil then
			return false, `no model plays the role "{id}"`
		end
		-- The role may be new, as when a model was just picked for it.
		s.models = roles()
		use(s, states[s.id], id)
		session.check(s)
		s.changed()
		return true, nil
	end,
	sees_images = function(s)
		return models.sees_images(states[s.id].role)
	end,
	check = function(s)
		return models.check(states[s.id].role)
	end,
	-- What was allowed for the session, like eval, goes with it.
	stop = function(s)
		agent.done(states[s.id].caller)
	end,
}

-- A new session's id: when it started, and a few letters to tell apart
-- sessions started in the same second.
local function new_id(): string
	local salt = greed.hash.sha256(`{greed.now()} {math.random()}`)
	return `{os.date("%Y%m%d-%H%M%S")}-{string.sub(salt, 1, 8)}`
end

--- A session of Greed's own agent for the project at `root`, using the
--- model in role `role` (by default `M.ROLE`, else `reasoning`). With
--- `resume`, the id of a session kept from before, it takes that up where
--- it left off: its transcript, what was said, its model and tool groups.
--- In `workspace`, it works there instead of in the project. With `from`,
--- a running session of Greed's agent, it's a fork of that one: it goes on
--- from what was said there, showing `entries`.
function M.start(opts: {
	name: string,
	agent: string,
	root: string,
	workspace: session.Workspace?,
	role: string?,
	resume: string?,
	from: Session?,
	entries: { session.Entry }?,
	decide: ((permission: session.Permission) -> (string?, string?))?,
	changed: () -> (),
}): (Session?, string?)
	local kept = if opts.resume then saved.load(opts.root, opts.resume) else nil
	if opts.resume and kept == nil then
		return nil, "its conversation isn't kept any more"
	end
	-- A fork goes on from what `from` has said so far, with its model and
	-- tool groups, as a session of its own.
	local source = if opts.from then states[opts.from.id] else nil
	local s = session.start_driven({
		name = opts.name,
		agent = opts.agent,
		root = opts.root,
		cwd = if opts.workspace then opts.workspace.path else opts.root,
		workspace = opts.workspace,
		entries = if kept then kept.entries elseif source then opts.entries else nil,
		decide = opts.decide,
		changed = opts.changed,
		driver = DRIVER,
	})
	local role = opts.role or models.playing(M.ROLE)
	local state: State = {
		said = {},
		role = role,
		cancelled = false,
		allowed = {},
		caller = agent.caller(),
		order = {},
		run = 0,
	}
	states[s.id] = state
	s.session_id = if kept then kept.id else new_id()
	if kept then
		table.insert(s.entries, { kind = "note", text = "taken up again" })
		state.said = kept.said
		s.spent = kept.spent
		if models.roles[kept.role] then
			role = kept.role
		end
		for _, group in kept.groups do
			state.caller.groups[group] = true
		end
	end
	if source then
		for _, said in source.said do
			table.insert(state.said, table.clone(said))
		end
		role = source.role
		for group in source.caller.groups do
			state.caller.groups[group] = true
		end
	end
	for _, group in M.GROUPS do
		state.caller.groups[group] = true
	end
	s.models = roles()
	use(s, state, role)
	session.check(s)
	return s, nil
end

--- Compacts the conversation of `s`, a session of Greed's own agent, now:
--- the model summarises all but its last few turns. False and why when it
--- can't.
function M.compact(s: Session): (boolean, string?)
	local state = states[s.id]
	if state == nil then
		return false, "only Greed's own agent can be compacted here"
	elseif s.status == "working" or s.status == "waiting" then
		return false, "the agent is working; wait for it or stop it first"
	end
	s.status = "working"
	s.since = greed.now()
	local ok, err = compact_now(s, state)
	s.status = "idle"
	s.changed()
	return ok, err
end

--- Whether `s` is a session of Greed's own agent.
function M.drives(s: Session): boolean
	return states[s.id] ~= nil
end

--- Has `s`, a session of Greed's own agent, use a model you pick from
--- those a provider lists: it plays the `agent` role from now on, kept as
--- :models keeps it. Returns what happened, to tell you, or nil when you
--- picked no provider.
function M.pick_model(s: Session): string?
	local said, changed = models.ask_role(M.ROLE)
	if changed then
		local ok, err = DRIVER.set_model(s, M.ROLE)
		if not ok then
			return `{said}; can't switch to it: {err}`
		end
	end
	return said
end

--- How hard the model of `s`, a session of Greed's own agent, thinks: as
--- set for the session (`/effort`), else as its role says, and what's
--- sent for that (models.effort). Nil when nothing says.
function M.effort(s: Session): (string?, string?)
	local state = states[s.id]
	if state == nil then
		return nil, nil
	end
	local role = models.roles[models.playing(state.role)]
	return s.effort or (role and role.effort), models.effort(state.role, s.effort)
end

--- The efforts to pick from for `s`, a session of Greed's own agent, as
--- `models.efforts` has them for its model, the one it has now marked;
--- none for another agent's session.
function M.efforts(s: Session): { models.EffortChoice }
	local state = states[s.id]
	if state == nil then
		return {}
	end
	return models.efforts(state.role, (M.effort(s)), "as the model's role says")
end

--- Has Greed's agent in `s` only read and search from now on: it's offered
--- no tool that changes anything, nor told about helpers. For a helper
--- working where its caller does, without a workspace of its own.
function M.read_only(s: Session)
	local state = states[s.id]
	if state then
		state.reads_only = true
	end
end

--- Switches tool group `group` on for the session `s`, as the agent would
--- with the tools tool, e.g. to start it with the tools a task needs.
function M.switch_on(s: Session, group: string)
	local state = states[s.id]
	if state then
		state.caller.groups[group] = true
	end
end

return M
