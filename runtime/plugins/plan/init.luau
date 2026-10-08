-- A plan and decisions you share with agents, as notes in the project's
-- notes folder (`.greed/notes`, see the notes plugin), so they're searched,
-- linked and in the agenda like any note.
--
-- The plan (`project:plan`) is an agent's checklist where you can see and
-- change it: tick, reorder, add or delete items, and the agent reads what
-- you did. An agent replaces the whole plan when it writes, giving the
-- version it read, so it can't write over changes you made since.
--
-- Decisions (`project:decisions/*`) are what you settled, kept across
-- sessions: "use sqlite", "never touch the generated code". Ones an agent
-- adds stay proposed until you accept them, and agents are told so, so an
-- agent can't make itself rules the next one follows.

local greed = require("@greed")
local core = require("@core")
local notes = require("@notes")
local agent = require("@agent")
agent.group("plan", "The plan you share with the user, and what was decided for the project")
local picker = require("@picker")

local M = {}

local PLAN_START = "# Plan\n\n"

--- Where the plan is.
function M.plan_path(): string
	return `{notes.project_folder()}/plan.md`
end

--- Where decisions are.
function M.decisions_dir(): string
	return `{notes.project_folder()}/decisions`
end

-- Where the decision kept as `name` is.
local function decision_path(name: string): string
	return `{M.decisions_dir()}/{name}`
end

-- An agent's note tools can't write decisions: one it wrote itself would
-- read as accepted.
notes.guard(function(path: string): string?
	if core.project.inside(path, M.decisions_dir()) then
		return "decisions are the user's to write; propose one with decision_propose"
	end
	return nil
end)

--- A short fingerprint of `text`, for telling whether it changed.
function M.version(text: string): string
	return string.sub(greed.hash.sha256(text), 1, 16)
end

export type Task = { line: number, done: boolean, text: string, depth: number }

--- The checklist items in `text`, with their 1-based lines.
function M.tasks(text: string): { Task }
	local tasks = {}
	local n = 0
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		n += 1
		local indent, mark, rest = string.match(line, "^(%s*)[-*] %[([ xX])%] (.*)$")
		if indent and mark and rest then
			table.insert(tasks, { line = n, done = mark ~= " ", text = rest, depth = #indent // 2 })
		end
	end
	return tasks
end

--- The plan as you have it, and its version; empty if there's none yet.
function M.read_plan(): (string, string)
	local text = core.file.text(M.plan_path()) or ""
	return text, M.version(text)
end

--- Replaces the plan with `text`, unless it changed since `version` was
--- read. Returns whether it did, and the plan as it is if it didn't.
function M.write_plan(text: string, version: string): (boolean, string?)
	local current, now = M.read_plan()
	if now ~= version then
		return false, current
	end
	core.file.write(M.plan_path(), text)
	return true, nil
end

export type Decision = { name: string, title: string, status: string, text: string }

-- The decision in `text`, kept as `name`.
local function decision(name: string, text: string): Decision
	return {
		name = name,
		title = string.match(text, "^#%s*([^\n]+)") or name,
		status = string.lower(string.match(text, "\nStatus:%s*(%a+)") or "accepted"),
		text = text,
	}
end

--- Every decision, oldest first.
function M.decisions(): { Decision }
	local list = {}
	local entries: { greed.DirEntry } = greed.fs.list(
		M.decisions_dir(),
		{ hidden = true, ignored = true }
	) or {}
	for _, entry in entries do
		if not entry.dir and string.match(entry.name, "%.md$") then
			local text = core.file.text(decision_path(entry.name))
			if text then
				table.insert(list, decision(entry.name, text))
			end
		end
	end
	table.sort(list, function(a: Decision, b: Decision)
		return a.name < b.name
	end)
	return list
end

-- `title` as a file name: lowercase words joined by dashes.
local function slug(title: string): string
	local words = string.gsub(string.lower(title), "[^%w]+", "-")
	words = string.gsub(words, "^%-+", "")
	words = string.gsub(words, "%-+$", "")
	return string.sub(if words == "" then "decision" else words, 1, 60)
end

--- Adds a decision, `proposed` (by an agent) or accepted (by you), and
--- returns its file name.
function M.decide(title: string, text: string, proposed: boolean): string
	local name = string.format("%04d-%s.md", #M.decisions() + 1, slug(title))
	local status = if proposed then "proposed" else "accepted"
	local body = `# {title}\n\nStatus: {status}\nDate: {os.date("%Y-%m-%d")}\n\n{text}\n`
	core.file.write(decision_path(name), body)
	return name
end

local object = agent.schema.object

agent.tool({
	name = "plan_read",
	group = "plan",
	description = "The plan you share with the user, a Markdown checklist in the project's notes "
		.. "(project:plan), as they have it: they may have ticked, reordered, added or removed "
		.. "items. Returns its text, its tasks and a version to give plan_write",
	run = function()
		local text, version = M.read_plan()
		return { text = text, version = version, tasks = greed.json.array(M.tasks(text)) }
	end,
})

agent.tool({
	name = "plan_write",
	kind = "edit",
	group = "plan",
	description = "Replace the plan with new Markdown: a checklist ('- [ ] step', '- [x] done', "
		.. "indented for sub-steps) and any notes. Give the version plan_read returned; if the "
		.. "user changed the plan since, nothing is written and you get the plan as it is now, "
		.. "to read and try again. Keep their changes. Returns whether it was written and the "
		.. "version to give next time",
	input = object({
		text = { type = "string" },
		version = { type = "string" },
	}, { "text", "version" }),
	run = function(args)
		local text = args.text
		if not string.match(text, "^#") then
			text = PLAN_START .. text
		end
		local done, current = M.write_plan(text, args.version)
		local _, version = M.read_plan()
		if done then
			return { written = true, version = version }
		end
		return {
			written = false,
			reason = "the user changed the plan since you read it",
			text = current,
			version = version,
		}
	end,
})

-- A decision as agents see it: proposed ones say so.
local function shown(d: Decision): { [string]: any }
	return {
		name = d.name,
		title = d.title,
		status = d.status,
		note = if d.status == "proposed"
			then "proposed by an agent and not accepted by the user: don't rely on it"
			else nil,
	}
end

agent.tool({
	name = "decisions",
	group = "plan",
	description = "Decisions settled for this project, kept in the project's notes "
		.. "(project:decisions/...): what was decided and why. Follow the accepted ones; proposed "
		.. "ones aren't agreed yet. With `query`, only those whose text has it",
	input = object({ query = { type = "string" } }),
	run = function(args)
		local list = {}
		for _, d in M.decisions() do
			if
				args.query == nil
				or string.find(string.lower(d.text), string.lower(args.query), 1, true)
			then
				table.insert(list, shown(d))
			end
		end
		return greed.json.array(list)
	end,
})

agent.tool({
	name = "decision_read",
	group = "plan",
	description = "One decision's whole text, by the name `decisions` gave",
	input = object({ name = { type = "string" } }, { "name" }),
	run = function(args)
		for _, d in M.decisions() do
			if d.name == args.name then
				local result = shown(d)
				result.text = d.text
				return result
			end
		end
		error(`no decision called {args.name}`, 0)
	end,
})

agent.tool({
	name = "decision_propose",
	kind = "edit",
	-- It stays proposed until the user accepts it.
	reviews = true,
	group = "plan",
	description = "Propose a decision to keep for later sessions, e.g. after the user settled a "
		.. "question. It stays proposed until the user accepts it",
	input = object({
		title = { type = "string", description = "What was decided, in a line" },
		text = { type = "string", description = "Why, and anything that goes with it" },
	}, { "title", "text" }),
	run = function(args)
		return M.decide(args.title, args.text, true)
	end,
})

-- Opens `path` beside your files, made with `start` if it isn't there.
local function show(path: string, start: string)
	if greed.fs.stat(path) == nil and greed.buffer_for(path) == nil then
		greed.fs.write(path, start)
	end
	greed.open(path)
end

greed.command({
	name = "plan",
	doc = "Open the plan you share with agents, in the project's notes",
	run = function()
		show(M.plan_path(), PLAN_START)
	end,
})

-- The line of `buffer` saying its decision's status, if it has one.
local function status_line(buffer: greed.Buffer): number?
	for line = 0, buffer:line_count() - 1 do
		if string.match(buffer:line_text(line), "^Status:%s*%a+") then
			return line
		end
	end
	return nil
end

-- A proposed decision open in `buffer` says beside its status how to
-- accept it; once accepted, it says nothing.
local function show_status(buffer: greed.Buffer)
	-- Only decisions: any other file, however big, isn't read at all.
	local path = buffer:path()
	if path == nil or not core.project.inside(path, M.decisions_dir()) then
		return
	end
	local line = status_line(buffer)
	local marks: { greed.Mark } = {}
	if line and string.match(buffer:line_text(line), "^Status:%s*proposed") then
		local at = buffer:line_start(line)
		table.insert(marks, {
			from = at,
			to = at,
			eol = true,
			style = "ui.button",
			text = "accept",
			action = "decision-accept",
		})
		table.insert(marks, {
			from = at,
			to = at,
			eol = true,
			style = "comment",
			text = "an agent proposed it; :decision-accept accepts it",
		})
	end
	buffer:decorate("decision", marks)
end

greed.on("buffer.opened", function(event: greed.BufferChanged)
	show_status(event.buffer)
end)

greed.command({
	name = "decisions",
	doc = "Pick a decision kept for this project to open it",
	run = function()
		local items = {}
		for _, d in M.decisions() do
			local status = if d.status == "accepted" then "" else ` ({d.status})`
			table.insert(items, { label = d.title .. status, value = decision_path(d.name) })
		end
		picker.pick("Decisions", items, function(item)
			greed.open(item.value)
			show_status(greed.view():buffer())
		end)
	end,
})

greed.command({
	name = "decision-new",
	doc = "Write down a decision for this project, kept for you and agents",
	args = { { name = "title", doc = "What was decided, in a line" } },
	run = function(ctx)
		local title = table.concat(ctx.args, " ")
		if title == "" then
			greed.echo("say what was decided: :decision-new use sqlite for storage")
			return
		end
		local name = M.decide(title, "Why: ", false)
		greed.open(decision_path(name))
	end,
})

greed.command({
	name = "decision-accept",
	doc = "Accept the proposed decision you're in, so agents follow it",
	run = function(ctx)
		local buffer = ctx.buffer
		local line = status_line(buffer)
		if line == nil then
			greed.echo("this isn't a decision")
			return
		end
		local title = string.match(buffer:line_text(0), "^#%s*(.-)%s*$") or "the decision"
		if string.match(buffer:line_text(line), "^Status:%s*accepted") then
			greed.echo(`"{title}" is accepted already`)
			return
		end
		buffer:edit(function(e)
			e:replace(buffer:line_start(line), buffer:line_end(line), "Status: accepted")
		end)
		buffer:save()
		show_status(buffer)
		greed.echo(`accepted "{title}"; agents follow it from now on`)
	end,
})

return M
