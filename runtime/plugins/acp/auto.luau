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

--- How many blocks in a row before auto mode asks you instead.
M.BLOCKS = 3

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
--- asked `now` (after `before`, oldest first); nil and why without an
--- answer. It isn't told what Greed thinks is risky (told so, it blocks
--- what you asked for too), and the command goes as it is: the state is
--- data to it, never instructions, and wrapped in tags a harmless command
--- looked suspect.
function M.judged(
	folder: string,
	now: string?,
	before: { string },
	command: string
): (number?, string?)
	local rules = greed.option.get("agent-auto-rules")
	local state = {
		project_folder = folder,
		user_asks_now = now,
		user_asked_before = if #before > 0 then before else nil,
		user_rules = if type(rules) == "string" and rules ~= "" then rules else nil,
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
local function judge(s: Session, command: string): Verdict?
	local now, before, count = asked(s)
	local known = decided[s] or {}
	decided[s] = known
	local key = `{count}\0{command}`
	if known[key] then
		return known[key]
	end
	local safe = M.judged(s.cwd, now, before, command)
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

--- What auto mode says of `s` doing what `permission` asks: "allow" or
--- "block" and why, or nil to leave it to you. It may wait for the decision
--- model.
function M.decide(s: Session, permission: session.Permission): ("allow" | "block" | nil, string?)
	if not M.on(s) then
		return nil, nil
	end
	local kind = permission.kind or ""
	if LOOKS[kind] then
		return "allow", "auto: only looks"
	elseif EDITS[kind] then
		local locations = permission.locations
		if locations and #locations > 0 and not session.outside(s, locations) then
			return "allow", "auto: in the project"
		end
		return nil, nil
	end
	local command = permission.command
	if kind ~= "execute" or command == nil or M.hard(command) then
		return nil, nil
	elseif not core.risk.of(command) and core.risk.safe(command) then
		return "allow", "auto: only looks, builds or tests"
	elseif (s.auto_blocks or 0) >= M.BLOCKS then
		-- Blocked a few times in a row: you decide until you've answered.
		return nil, nil
	end
	local verdict = judge(s, command)
	if verdict == nil then
		return nil, nil
	elseif verdict.allow then
		s.auto_blocks = 0
		return "allow", `auto: {verdict.why}`
	end
	s.auto_blocks = (s.auto_blocks or 0) + 1
	return "block", `auto: {verdict.why}`
end

return M
