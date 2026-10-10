-- The agent benchmark's runner, loaded into a headless Greed by run.sh. For
-- each task and repeat it copies the task's project to a folder of its own,
-- starts a fresh session of Greed's own agent there, sends the task's
-- prompt and answers for the user (allowing what the agent asks to do,
-- installing what it asks to install, cancelling its questions), runs the
-- task's check, and appends a line of JSON to the results: whether it
-- passed, how long it took, the calls it made and the tokens it used.

local greed = require("@greed")
local acp = require("@acp")
local models = require("@models")
local core = require("@core")

local M = {}

-- An empty config, run again, so no task sees what one before it set.
local function fresh_config()
	local config = greed.fs.dirs().config
	if config then
		greed.fs.write(`{config}/init.luau`, "")
		core.config.reload()
	end
end

-- What run.sh asks for.
type Run = {
	tasks_dir: string,
	tasks: { string },
	work: string,
	results: string,
	done: string,
	label: string,
	url: string?,
	repeats: number,
	solutions: boolean?,
	role: { provider: string, model: string, edits: string?, context: number? },
}

type Task = {
	prompt: string,
	check: string?,
	luau_check: (string | { string })?,
	timeout_s: number?,
	-- A shell step after the copy, like a commit for blame to find.
	setup: string?,
	-- A file in the project to show before the Luau check.
	open: string?,
	-- What a solution says, for checks of an answer.
	solution_answer: string?,
}

type Totals = {
	requests: number,
	input: number,
	cached: number,
	output: number,
	edits_ok: number,
	edits_failed: number,
}

local function shell_quote(s: string): string
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- What `model` at `provider` used today, all hours together.
local function totals(provider: string, model: string): Totals
	local sum: Totals =
		{ requests = 0, input = 0, cached = 0, output = 0, edits_ok = 0, edits_failed = 0 }
	for key, used in models.usage(os.date("%Y-%m-%d")) do
		if string.match(key, "^%d+ (.+)$") == `{provider}/{model}` then
			sum.requests += used.requests
			sum.input += used.input
			sum.cached += used.cached or 0
			sum.output += used.output
			for _, tally in used.edits or {} do
				sum.edits_ok += tally.ok
				sum.edits_failed += tally.failed
			end
		end
	end
	return sum
end

-- The newest file under `dir`, looking into folders, if any.
local function newest(dir: string): string?
	local best: string?, best_at = nil, -1
	local function walk(path: string)
		local entries = greed.fs.list(path)
		if entries == nil then
			return
		end
		for _, entry in entries do
			local full = `{path}/{entry.name}`
			if entry.dir then
				walk(full)
			elseif string.match(entry.name, "%.json$") and entry.name ~= "index.json" then
				local info = greed.fs.stat(full)
				if info and info.modified and info.modified > best_at then
					best, best_at = full, info.modified
				end
			end
		end
	end
	walk(dir)
	return best
end

-- Calls that change something: before the first of these the agent was
-- only finding its way.
local CHANGES = {
	edit_file = true,
	write_file = true,
	move_file = true,
	delete_file = true,
	plugin_try = true,
	run = true,
	eval = true,
}

-- What the saved conversation, `text`, says about the calls the agent made.
local function calls_of(text: string?): { [string]: any }
	local out: { [string]: any } =
		{ calls = 0, by_tool = {}, before_change = 0, tool_errors = 0, turns = 0, asked = 0 }
	local ok, saved = pcall(greed.json.decode, text or "{}")
	if not ok or type(saved) ~= "table" or type(saved.said) ~= "table" then
		return out
	end
	local changed = false
	for _, said in saved.said do
		if said.role == "assistant" then
			out.turns += 1
			for _, call in said.calls or {} do
				out.calls += 1
				out.by_tool[call.name] = (out.by_tool[call.name] or 0) + 1
				if call.name == "ask" then
					out.asked += 1
				end
				if CHANGES[call.name] then
					changed = true
				elseif not changed then
					out.before_change += 1
				end
			end
		elseif said.role == "tool" and said.error then
			out.tool_errors += 1
		end
	end
	return out
end

-- Answers for the user while a task runs in `dir`: accepts the changes it
-- proposes, installs a plugin under review and cancels questions, as no
-- one is there to answer them.
local function answer_pages(dir: string, running: () -> boolean)
	local agent = require("@agent")
	greed.spawn(function()
		while running() do
			greed.sleep(500)
			pcall(function()
				local buffer = greed.view():buffer()
				if buffer:kind() == "plugin-review" then
					greed.run("plugin-review-accept")
				elseif string.find(buffer:text(), "When you're done:", 1, true) then
					greed.run("ask-cancel")
				elseif agent.pending() > 0 then
					for _, proposed in greed.buffers() do
						local path = proposed:path()
						if path and string.sub(path, 1, #dir) == dir then
							greed.open(path)
							greed.run("proposal-accept-all")
						end
					end
				end
			end)
		end
	end)
end

-- Copies task `name` to a folder of its own and makes it the project, as
-- when you work in it. Returns the task, its folder and the task's own.
local function prepare(run: Run, name: string, rep: number): (Task, string, string)
	local source = `{run.tasks_dir}/{name}`
	local task: Task = greed.json.decode(assert(greed.fs.read(`{source}/task.json`)))
	local dir = `{run.work}/{name}-{rep}`
	assert(greed.process.run({ "cp", "-R", `{source}/project`, dir }))
	-- A repository of its own, as a project is, so the project is this
	-- folder and not the Greed repository the work folder may sit in.
	assert(greed.process.run({ "git", "init", "-q" }, { cwd = dir }))
	if task.setup then
		assert(greed.process.run({ "sh", "-c", task.setup }, { cwd = dir }))
	end
	fresh_config()
	-- Notes of its own, never yours.
	greed.option.set("notes-folder", `{dir}-notes`)
	-- Showing one of its files makes it the editor's project: Greed's tools
	-- for agents find files from there.
	local entries = greed.fs.list(dir) or {}
	table.sort(entries, function(a, b)
		return a.name < b.name
	end)
	for _, entry in entries do
		if not entry.dir then
			greed.open(`{dir}/{entry.name}`)
			break
		end
	end
	return task, dir, source
end

-- Runs Greed's agent on `task` in `dir` until it's done or out of time, and
-- returns how it went: whether it answered, why not, seconds, timing out,
-- its conversation and what it said last.
local function run_agent(task: Task, dir: string): { [string]: any }
	local data = greed.fs.dirs().data or ""
	local started = os.time()
	local agent = assert(acp.installed("greed"), "Greed's own agent isn't there")
	local s = assert(acp.start(agent, dir))
	local finished, timed_out = false, false
	answer_pages(dir, function()
		return not finished
	end)
	local prompted, err = false, nil
	greed.spawn(function()
		prompted, err = acp.prompt(s, task.prompt)
		finished = true
	end)
	-- Past its time it's stopped; a turn stuck in a tool after that is left.
	local limit = os.time() + (task.timeout_s or 600)
	while not finished and os.time() < limit + 30 do
		if os.time() >= limit and not timed_out then
			timed_out = true
			acp.stop(s)
		end
		greed.sleep(1000)
	end
	finished = true
	local last = ""
	for _, entry in s.entries do
		if entry.kind == "agent" and entry.text then
			last = entry.text
		end
	end
	local conversation = newest(`{data}/agent-sessions`)
	local text = conversation and greed.fs.read(conversation)
	acp.close(s)
	return {
		failed = if prompted then nil else err,
		seconds = os.time() - started,
		timed_out = timed_out,
		conversation = text,
		calls = calls_of(text),
		answer = last,
	}
end

-- Puts the task's own solution in place of the agent, to show its check
-- can pass: `solution.luau` becomes the config, and `solution_answer`
-- what it said.
local function run_solution(task: Task, source: string): { [string]: any }
	local solution = greed.fs.read(`{source}/solution.luau`)
	local config = greed.fs.dirs().config
	if solution and config then
		greed.fs.write(`{config}/init.luau`, solution)
		core.config.reload()
	end
	return {
		failed = if solution then nil else "no solution.luau",
		seconds = 0,
		timed_out = false,
		calls = calls_of(nil),
		answer = task.solution_answer or "",
	}
end

-- Whether `task` in `dir` passes its check, and what the check said.
local function check(task: Task, dir: string, source: string): (boolean, string)
	if task.check then
		local done = greed.process.run(
			{ "sh", "-c", `export TASK_DIR={shell_quote(source)}; {task.check}` },
			{ cwd = dir }
		)
		return done ~= nil and done.code == 0, if done then done.stdout .. done.stderr else ""
	end
	-- A config saved a moment ago reloads first.
	greed.sleep(1500)
	if task.open then
		greed.open(`{dir}/{task.open}`)
		greed.sleep(1500)
	end
	-- One step, or several with a pause between, as when one runs a command
	-- and the next looks at what it showed; the last says true to pass.
	local steps: { string } = if type(task.luau_check) == "table"
		then task.luau_check
		else { task.luau_check :: string }
	local said = ""
	for n, step in steps do
		local ok, result = greed.eval(`local TASK_DIR = {string.format("%q", dir)}\n{step}`)
		said = result
		if not ok then
			return false, `step {n}: {result}`
		end
		if n < #steps then
			greed.sleep(1500)
		end
	end
	return said == "true", said
end

-- Runs `name` once in a folder of its own, and returns what happened.
local function run_task(run: Run, name: string, rep: number): { [string]: any }
	local task, dir, source = prepare(run, name, rep)
	local before = totals(run.role.provider, run.role.model)
	local ran = if run.solutions then run_solution(task, source) else run_agent(task, dir)
	-- What it said last, for checks of an answer.
	greed.fs.write(`{dir}/.bench-answer`, ran.answer)
	local passed, output = check(task, dir, source)
	local after = totals(run.role.provider, run.role.model)
	-- Kept beside the results, to see what happened in a run.
	if ran.conversation then
		local kept = string.gsub(run.results, "%.jsonl$", "")
		greed.fs.write(`{kept}/{name}-{rep}.json`, ran.conversation)
	end
	local calls = ran.calls
	return {
		label = run.label,
		task = name,
		rep = rep,
		provider = run.role.provider,
		model = run.role.model,
		edits = run.role.edits or "replace",
		passed = passed,
		timed_out = ran.timed_out,
		failed = ran.failed,
		seconds = ran.seconds,
		turns = calls.turns,
		calls = calls.calls,
		by_tool = calls.by_tool,
		before_change = calls.before_change,
		tool_errors = calls.tool_errors,
		asked = calls.asked,
		requests = after.requests - before.requests,
		input = after.input - before.input,
		cached = after.cached - before.cached,
		output = after.output - before.output,
		edits_ok = after.edits_ok - before.edits_ok,
		edits_failed = after.edits_failed - before.edits_failed,
		check_output = string.sub(output, -2000),
	}
end

--- Runs the benchmark `path` (run.sh's bench.json) describes, in the
--- background, and returns at once. Each result is a line in the results
--- file; the `done` file says it's over.
function M.start(path: string): string
	local run: Run = greed.json.decode(assert(greed.fs.read(path)))
	-- A server elsewhere, like Ollama on another machine, by the provider's name.
	if run.url and run.url ~= "" then
		models.provider(run.role.provider, { kind = "openai", url = run.url })
	end
	if run.role.context == 0 then
		run.role.context = nil
	end
	models.role("agent", run.role)
	-- No one is here to look at code before it runs.
	greed.option.set("agent-eval", "allow")
	-- Allow whatever the agent asks to do, for the rest of its session.
	acp.policy(function(_, permission)
		for _, kind in { "allow_always", "allow_once" } do
			for _, option in permission.options do
				if option.kind == kind then
					return option.id
				end
			end
		end
		return nil
	end)
	greed.spawn(function()
		local lines = {}
		for rep = 1, run.repeats do
			for _, name in run.tasks do
				local ok, result = pcall(run_task, run, name, rep)
				if not ok then
					result = {
						label = run.label,
						task = name,
						rep = rep,
						passed = false,
						failed = tostring(result),
					}
				end
				table.insert(lines, greed.json.encode(result))
				greed.fs.write(run.results, table.concat(lines, "\n") .. "\n")
			end
		end
		greed.fs.write(run.done, "")
	end)
	return `running {#run.tasks} tasks, {run.repeats} times`
end

-- run.sh puts the runner among the default plugins and what to run in the
-- profile's config; it starts once the editor has.
local config = greed.fs.dirs().config
local path = if config then `{config}/bench.json` else nil
if path and greed.fs.stat(path) then
	greed.on("editor.started", function()
		local ok, err = pcall(M.start, path)
		if not ok then
			-- run.sh waits for `done`; say why it came early.
			local run = greed.json.decode(greed.fs.read(path) or "{}")
			greed.fs.write(run.done, tostring(err))
		end
	end)
end

return M
