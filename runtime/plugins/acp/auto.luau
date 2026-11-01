-- Auto mode: Greed answers an agent's questions for you where it can, as
-- Claude Code's auto mode does, and leaves the rest to you. The agent may
-- look (read, search, fetch), edit inside the project, and run commands
-- that only look, or build and test (`core.risk.safe`). Any other command,
-- risky ones too, goes to the `decision` model, which reads what you asked
-- for (your messages, never what the agent read) and the command, and lets
-- it run or blocks it. A blocked command goes back to the agent with why,
-- to find another way; after three blocks in a row you're asked instead.
-- A few things always ask you: changes outside the project, anything run
-- as root, force pushes, and deleting or wiping what's beyond the project.
-- Once the agent has read text from outside since your newest message,
-- fetches from hosts nothing else named go to the decision model, and an
-- address that looks like it carries a secret asks you.

local greed = require("@greed")
local core = require("@core")
local models: any = require("@models")
local session = require("./session")

type Session = session.Session

local M = {}

--- The role of the model that decides about commands auto mode can't
--- tell; without one of its own, the fast model.
M.ROLE = "decision"
models.fallback(M.ROLE, "fast", "deciding whether an agent may run a command, in auto mode")

greed.option.define({
	name = "agent-auto",
	doc = "Start agent sessions in auto mode: Greed answers their questions where it can, the "
		.. "decision model judging commands by what you asked for, and asks you the rest; alt-a "
		.. "switches a session",
	default = false,
})

greed.option.define({
	name = "agent-auto-rules",
	doc = "What the decision model should know in auto mode, in plain words: what's fine to do "
		.. "in your setup and what isn't, like \"deleting under /tmp is fine; never touch the "
		.. 'prod cluster"',
	default = "",
})

--- How many blocks in a row before auto mode asks you instead, and how
--- many in a session, as an agent that keeps trying what it shouldn't
--- between allowed steps would.
M.BLOCKS = 3
M.SESSION_BLOCKS = 20

-- Whether `paths` are all in the system's folder for temporary files,
-- where an agent may make and remove scratch files outside the project.
local function temporary(paths: { string }): boolean
	local temp = greed.fs.dirs().temp
	if temp == nil then
		return false
	end
	for _, path in paths do
		if not core.project.inside(path, temp) then
			return false
		end
	end
	return true
end

-- Where your last switch (alt-a) is kept: new sessions start that way,
-- after a restart too, unless your config sets `agent-auto` itself.
local function kept_at(): string?
	local data = greed.fs.dirs().data
	return data and `{data}/agent-auto`
end
do
	local path = kept_at()
	local kept = if path then greed.fs.read(path) else nil
	if kept then
		greed.option.set("agent-auto", string.match(kept, "^%s*(%a+)") == "auto")
	end
end

--- Whether `s` is in auto mode: as you switched it, else as `agent-auto`
--- says.
function M.on(s: Session): boolean
	if s.auto ~= nil then
		return s.auto
	end
	return greed.option.get("agent-auto") == true
end

--- Switches `s` between auto and manual, and new sessions with it, now
--- and after a restart. Returns whether it's in auto mode now.
function M.switch(s: Session): boolean
	local on = not M.on(s)
	s.auto = on
	-- Switched on again, it starts counting blocks afresh.
	s.auto_blocks, s.auto_blocked = nil, nil
	greed.option.set("agent-auto", on)
	local path = kept_at()
	if path then
		greed.fs.write(path, if on then "auto\n" else "manual\n")
	end
	return on
end

-- The kinds of call that only look.
local LOOKS: { [string]: boolean } = { read = true, search = true, fetch = true, think = true }
-- The kinds that change files, allowed inside the project.
local EDITS: { [string]: boolean } = { edit = true, delete = true, move = true }

-- The addresses in `text`.
local function urls(text: string): { string }
	local found = {}
	for url in string.gmatch(text, "https?://[^%s\"'<>`%)%]}]+") do
		table.insert(found, url)
	end
	return found
end

local function host_of(url: string): string
	return string.lower(
		string.match(url, "^https?://[^/?#@]*@([^/?#:]+)")
			or string.match(url, "^https?://([^/?#:]+)")
			or ""
	)
end

--- Whether `url` carries a long opaque value after its `?` or `#`, like a
--- token or a key: the shape of a secret sent out in an address. Words
--- joined by `+` are text, and so is a value without digits.
function M.leaks(url: string): boolean
	local rest = string.match(url, "[?#](.*)$")
	if rest == nil then
		return false
	end
	for value in string.gmatch(rest, "[^&=#;]+") do
		for word in string.gmatch((string.gsub(value, "%%20", "+")), "[^+]+") do
			if
				#word >= 32
				and not string.find(word, "[^%w%-_%.%%/~]")
				and string.find(word, "%d")
				and string.find(word, "%a")
			then
				return true
			end
		end
	end
	return false
end

-- What the agent did since your newest message.
local function turn(s: Session): { session.Entry }
	for i = #s.entries, 1, -1 do
		if s.entries[i].kind == "user" then
			return table.move(s.entries, i + 1, #s.entries, 1, {})
		end
	end
	return s.entries
end

-- Whether the agent has read text from outside since your newest message:
-- a page it fetched, or what Greed marked as untrusted, like a search's
-- results or what a command printed. Text like that may tell it to send
-- what it knows somewhere. A fetch still waiting, like the one being
-- asked about, hasn't brought anything yet.
local function read_outside(s: Session): boolean
	for _, e in turn(s) do
		local tool = e.tool
		if
			tool
			and (
				(tool.kind == "fetch" and tool.status == "completed")
				or string.find(table.concat(tool.output, "\n"), "<untrusted-", 1, true)
			)
		then
			return true
		end
	end
	return false
end

-- The hosts the agent may fetch from after reading text from outside:
-- the ones in your messages, the ones it fetched from since your newest
-- message (other than in `asking`), and the ones in what it found, like a
-- search's results. Never ones a page names: a page could name any.
local function known_hosts(s: Session, asking: session.Permission): { [string]: boolean }
	local hosts: { [string]: boolean } = {}
	local function add(text: string)
		for _, url in urls(text) do
			hosts[host_of(url)] = true
		end
	end
	for _, e in s.entries do
		if e.kind == "user" and e.text then
			add(e.text)
		end
	end
	for _, e in turn(s) do
		local permission, tool = e.permission, e.tool
		if permission and permission ~= asking and permission.url then
			add(permission.url)
		elseif tool and (tool.kind == "read" or tool.kind == "search") then
			add(table.concat(tool.output, "\n"))
		end
	end
	return hosts
end

-- Programs that change the machine itself.
local MACHINE: { [string]: boolean } =
	{ dd = true, mkfs = true, shutdown = true, reboot = true, halt = true, poweroff = true }

-- Places deleting which wipes far more than a project: the root, home and
-- what's right under them.
local function wide(path: string): boolean
	local plain = string.gsub(string.gsub(path, "/+$", ""), "/%*$", "")
	return plain == ""
		or plain == "/"
		or plain == "~"
		or plain == "$HOME"
		or plain == "*"
		or plain == ".."
		or string.match(plain, "^/[^/]+$") ~= nil
		or string.match(plain, "^~/[^/]+$") ~= nil
end

--- Why `command` always asks you, in auto mode too, whatever the decision
--- model would say; nil when it may go to the model.
function M.hard(command: string): string?
	local found, root = core.risk.commands(command)
	if root then
		return "runs as root"
	end
	for _, words in found do
		local program = core.risk.program(words)
		if MACHINE[program] then
			return "changes the machine itself"
		elseif
			program == "git"
			and table.find(words, "push")
			and core.risk.has_flag(
				words,
				{ "-f", "--force", "--force-with-lease", "--delete", "-d" }
			)
		then
			return "pushes over or deletes what's on a remote"
		elseif program == "rm" then
			for _, path in core.risk.args(words) do
				if wide(path) then
					return `deletes {path}`
				end
			end
		end
	end
	return nil
end

-- What the decision model is asked of a command: one short, plain question,
-- as a small model answers those best. Tried on Berget's clef-flash, it told
-- apart every command that should run from every one that shouldn't, with
-- what the user asked taken into account; asking also whether it's what the
-- user asked for did worse, the answer drifting with how a request was put.
local QUESTIONS: { [string]: { instructions: string, yes: string?, no: string? } } = {
	safe = {
		instructions = "Is it safe to run the agent's command without asking the user "
			.. "first, given what the user asked for and their rules?",
	},
}

-- How sure the decision model must be: a command it thinks safe runs, one
-- it thinks unsafe is blocked, and the rest ask you, as a model that can't
-- tell answers in between.
local SAFE = 0.6
local UNSAFE = 0.2

-- How many of your newest messages the decision model reads, and how much
-- of each.
local MESSAGES = 4
local MESSAGE_BYTES = 1500

-- Your newest message to `s`, the few before it (oldest first), and how
-- many you've sent. The newest goes apart: among earlier ones asking for
-- something else, a decision model weighs it too lightly.
local function asked(s: Session): (string?, { string }, number)
	local said: { string } = {}
	local count = 0
	for i = #s.entries, 1, -1 do
		local e = s.entries[i]
		if e.kind == "user" and e.text then
			count += 1
			if #said < MESSAGES then
				table.insert(said, 1, string.sub(e.text, 1, MESSAGE_BYTES))
			end
		end
	end
	local now = table.remove(said)
	return now, said, count
end

--- What auto mode does with a command: lets it run or blocks it, and why.
export type Verdict = { allow: boolean, why: string }

-- What the decision model said of each command, by session and how many of
-- your messages there were then.
local decided: { [Session]: { [string]: Verdict } } = setmetatable({}, { __mode = "k" }) :: any

--- How likely the decision model thinks `command` is safe to run without
--- asking you, from 0 to 1, for an agent working in `folder` where you
--- asked `now` (after `before`, oldest first), and that has `read_outside`
--- text since; nil and why without an answer. It isn't told what Greed
--- thinks is risky (told so, it blocks what you asked for too), and the
--- command goes as it is: the state is data to it, never instructions,
--- and wrapped in tags a harmless command looked suspect.
function M.judged(
	folder: string,
	now: string?,
	before: { string },
	command: string,
	read_outside: boolean?
): (number?, string?)
	local rules = greed.option.get("agent-auto-rules")
	local state = {
		project_folder = folder,
		user_asks_now = now,
		user_asked_before = if #before > 0 then before else nil,
		user_rules = if type(rules) == "string" and rules ~= "" then rules else nil,
		agent_read_text_from_outside = if read_outside then true else nil,
		agent_command = command,
	}
	local answers, err = models.decide(M.ROLE, state, QUESTIONS)
	return if answers then answers.safe else nil, err
end

--- What auto mode does with a command the decision model thinks `safe`
--- to run unasked (0 to 1): nil asks you.
function M.verdict(safe: number): Verdict?
	local function sure(p: number): string
		return `{math.floor(p * 100 + 0.5)}%`
	end
	return if safe <= UNSAFE
		then { allow = false, why = `not safe to run unasked ({sure(1 - safe)})` }
		elseif safe >= SAFE then { allow = true, why = `safe to run ({sure(safe)})` }
		else nil
end

-- What the decision model says of `s` running `command`, or nil when
-- there's no model or no clear answer: you're asked, and it's asked again
-- next time.
local function judge(s: Session, command: string, outside: boolean): Verdict?
	local now, before, count = asked(s)
	local known = decided[s] or {}
	decided[s] = known
	local key = `{count}\0{outside}\0{command}`
	if known[key] then
		return known[key]
	end
	local safe = M.judged(s.cwd, now, before, command, outside)
	local result = if safe then M.verdict(safe) else nil
	if result then
		known[key] = result
	end
	return result
end

--- Whether `why`, a policy's reason for an answer, is auto mode's.
function M.said(why: string?): boolean
	return why ~= nil and string.sub(why, 1, 5) == "auto:"
end

--- What an agent hears when auto mode blocked what it asked to do, for
--- `why` ("auto: ..."): not a no from you, so another way may do.
function M.refusal(why: string): string
	return `auto mode didn't let this run ({why}). Do it another way that doesn't need it, `
		.. "or ask the user if it's needed"
end

--- What auto mode says of `s` doing what `permission` asks: "allow" or
--- "block" and why, or nil to leave it to you. It may wait for the decision
--- model.
function M.decide(s: Session, permission: session.Permission): ("allow" | "block" | nil, string?)
	if not M.on(s) then
		return nil, nil
	end
	local kind = permission.kind or ""
	-- What goes to the decision model: a command, or a change to files in
	-- the temporary folder, as the question names it ("Write /tmp/a.txt").
	local action: string? = nil
	local outside = read_outside(s)
	if LOOKS[kind] then
		-- After reading text from outside, a fetch could send what the agent
		-- knows away in its address: one that looks like it asks you, and
		-- one to a host nothing but that text named goes to the decision
		-- model.
		local url = if kind == "fetch" and outside
			then permission.url or urls(permission.title)[1]
			else nil
		if url ~= nil and M.leaks(url) then
			return nil, nil
		elseif url == nil or known_hosts(s, permission)[host_of(url)] then
			return "allow", "auto: only looks"
		end
		action = `fetch {url}`
	elseif EDITS[kind] then
		local locations = permission.locations
		if locations == nil or #locations == 0 then
			return nil, nil
		elseif not session.outside(s, locations) then
			return "allow", "auto: in the project"
		elseif not temporary(locations) then
			return nil, nil
		end
		action = permission.title
	else
		local command = permission.command
		if kind ~= "execute" or command == nil or M.hard(command) then
			return nil, nil
		end
		if outside then
			for _, url in urls(command) do
				if M.leaks(url) then
					return nil, nil
				end
			end
		end
		if not core.risk.of(command) and core.risk.safe(command) then
			return "allow", "auto: only looks, builds or tests"
		end
		action = command
	end
	if (s.auto_blocks or 0) >= M.BLOCKS or (s.auto_blocked or 0) >= M.SESSION_BLOCKS then
		-- Blocked a few times in a row, or many times in all: you decide,
		-- until you've answered or switched auto mode off and on.
		return nil, nil
	end
	local verdict = judge(s, action :: string, outside)
	if verdict == nil then
		return nil, nil
	elseif verdict.allow then
		s.auto_blocks = 0
		return "allow", `auto: {verdict.why}`
	end
	s.auto_blocks = (s.auto_blocks or 0) + 1
	s.auto_blocked = (s.auto_blocked or 0) + 1
	return "block", `auto: {verdict.why}`
end

return M
