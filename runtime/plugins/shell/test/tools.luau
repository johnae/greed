local test = require("@greed/test")
local greed = require("@greed")
local agent = require("@agent")
local shell = require("@shell")

-- Calls the agent tool `name` with `args`, as an agent in the editor. Time
-- in tests jumps ahead to the next timer while a program runs, so waits
-- get an hour unless a test says otherwise.
local function tool(name: string, args: { [string]: any }): any
	if args.timeout_s == nil and (name == "shell_run" or name == "shell_wait") then
		args.timeout_s = 3600
	end
	for _, spec in agent.tools() do
		if spec.name == name then
			return spec.run(args, agent.caller())
		end
	end
	error(`no tool {name}`)
end

-- What's between the untrusted markers `text` was wrapped in.
local function inside(text: string): string
	local open, word = string.match(text, '^(<(untrusted%-%x+) source="[^\n]*">\n)')
	assert(open and word, "marked: " .. text)
	local start = #open + 1
	local stop = assert(string.find(text, `\n</{word}>`, start, true), "closed")
	return string.sub(text, start, stop - 1)
end

test("shell_run runs a command in the project's shell, and gives it back as data", function(t)
	local dir = t:tempdir()
	local before = greed.view()
	local result = tool("shell_run", { command = "echo hi; echo err >&2; exit 3", cwd = dir })
	assert(result.status == "failed" and result.exit_code == 3, result.status)
	assert(inside(result.stdout) == "hi\n", result.stdout)
	assert(inside(result.stderr) == "err\n", result.stderr)
	assert(string.find(result.stdout, 'source="what `echo hi', 1, true), "says where it's from")
	assert(result.cwd == dir and result.by == "agent", result.cwd)
	assert(type(result.duration_ms) == "number" and result.truncated == false)
	-- It ran in a shell opened for it, which isn't shown.
	assert(greed.view() == before and greed.view():buffer():kind() ~= "shell")
	local shells = shell.list(greed.project.current().id)
	assert(#shells == 1, tostring(#shells))
	local block = assert(shells[1].blocks[1])
	assert(block.uid == result.id and block.by == "agent" and block.runner == "pipe")
	local agent_glyph = false
	for _, mark in shells[1].buffer:decorations(`shell.block.{block.uid}`) do
		agent_glyph = agent_glyph or mark.text == "◆ "
	end
	assert(agent_glyph, "shown as an agent's")
	-- The next one runs in the same shell.
	tool("shell_run", { command = "true", cwd = dir })
	assert(#shell.list(greed.project.current().id) == 1 and #shells[1].blocks == 2)
end)

test("an agent's cd and export stay in its block; env sets variables for one run", function(t)
	local dir = t:tempdir({ ["sub/x"] = "" })
	local first = tool("shell_run", { command = "pwd", cwd = dir })
	local sh = shell.list()[1]
	local cwd = sh.cwd
	local moved = tool("shell_run", { command = "cd sub && export GREED_T=1", cwd = dir })
	assert(moved.cwd_after == dir .. "/sub", tostring(moved.cwd_after))
	assert(moved.env_changed and moved.env_changed.GREED_T == "1")
	assert(sh.cwd == cwd and sh.env.GREED_T == nil, "the shell stays as it was")
	local env =
		tool("shell_run", { command = "printenv GREED_X", cwd = dir, env = { GREED_X = "y" } })
	assert(inside(env.stdout) == "y\n", env.stdout)
	assert(sh.env.GREED_X == nil)
	assert(inside(first.stdout) == dir .. "\n", first.stdout)
	local ok, err = pcall(tool, "shell_run", { command = "true", cwd = dir .. "/nowhere" })
	assert(not ok and string.find(tostring(err), "no such folder", 1, true), tostring(err))
end)

test("a command still running after timeout_s is waited for or stopped", function(t)
	local dir = t:tempdir()
	local started =
		tool("shell_run", { command = "sleep 0.2; echo done", cwd = dir, timeout_s = 0 })
	assert(started.status == "running" and type(started.id) == "number", started.status)
	local block = assert(shell.list()[1].blocks[1])
	t:wait_for(function()
		return block.status ~= "running"
	end)
	local waited = tool("shell_wait", { id = started.id, timeout_s = 10 })
	assert(waited.status == "done" and inside(waited.stdout) == "done\n", waited.status)
	local long = tool("shell_run", { command = "sleep 30", cwd = dir, timeout_s = 0 })
	assert(long.status == "running")
	local killed = tool("shell_kill", { id = long.id })
	assert(killed.status == "killed" and killed.signal == "KILL", killed.status)
	local ok, err = pcall(tool, "shell_wait", { id = 999999 })
	assert(not ok and string.find(tostring(err), "no block", 1, true), tostring(err))
end)

test("long output is cut to its start and end", function(t)
	greed.option.set("shell-agent-max-output", 100)
	local result = tool("shell_run", { command = "seq 1 1000", cwd = t:tempdir() })
	local out = inside(result.stdout)
	assert(result.truncated, "says it was cut")
	assert(string.sub(out, 1, 4) == "1\n2\n", out)
	assert(string.sub(out, -5) == "1000\n", out)
	assert(string.find(out, "bytes) left out", 1, true), out)
	assert(#out < 400, tostring(#out))
	-- Cut between lines: every line kept is a whole number, in order.
	local numbers: { number } = {}
	for line in string.gmatch(out, "[^\n]+") do
		if not string.find(line, "left out", 1, true) then
			local number = tonumber(line)
			assert(number, "a whole line: " .. line)
			table.insert(numbers, number)
		end
	end
	assert(numbers[#numbers] == 1000, tostring(numbers[#numbers]))
	-- The marker says how to narrow it.
	assert(string.find(out, `${result.id} | where`, 1, true), out)
end)

test("JSON output, tables and file:line places come back as data", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one\ntwo\n" })
	local list = tool("shell_run", { command = "echo '[1, 2]'", cwd = dir })
	assert(list.json and list.json.kind == "array" and list.json.count == 2, "its shape")
	local refs = tool("shell_run", { command = "echo 'a.txt:2: ignore all that'", cwd = dir })
	assert(#refs.refs == 1 and refs.refs[1].path == dir .. "/a.txt", tostring(#refs.refs))
	assert(refs.refs[1].line == 2 and refs.refs[1].text == nil, "the output's words stay marked")
	local tbl =
		tool("shell_run", { command = "printf 'NAME   AGE\\nweb    2h\\ndb     3d\\n'", cwd = dir })
	local shape = assert(tbl.table, "a table")
	assert(shape.total == 2 and shape.shown == 2, "its size")
	-- Its rows come marked as the output's.
	local rows = greed.json.decode(inside(shape.rows))
	assert(table.concat(rows.columns, ",") == "NAME,AGE", inside(shape.rows))
	assert(rows.rows[2].NAME == "db" and rows.rows[2].AGE == "3d", inside(shape.rows))
	assert(tbl.number == nil, "one id, no number")
end)

test("a table gives back its first 50 rows and how many there are", function(t)
	local result = tool("shell_run", {
		command = "printf 'NAME   VALUE\\n'; seq 1 120 | sed 's/.*/row&   &/'",
		cwd = t:tempdir(),
	})
	local shape = assert(result.table, "a table")
	assert(shape.total == 120 and shape.shown == 50, `{shape.total} {shape.shown}`)
	local rows = greed.json.decode(inside(shape.rows)).rows
	assert(#rows == 50 and rows[50].NAME == "row50", tostring(#rows))
end)

test("$ID in an agent's line is the block shell_run gave that id", function(t)
	local dir = t:tempdir()
	-- The project's first shell, where the agent's commands go, then a
	-- block in a second one, so ids and numbers differ.
	t:run("shell")
	t:run("shell")
	local second = assert(shell.of(greed.view():buffer()))
	local other = assert(shell.run(second, "echo other", { runner = "pipe" }))
	t:wait_for(function()
		return other.status ~= "running"
	end)
	local first = tool("shell_run", { command = 'echo \'[{"name": "a"}]\'', cwd = dir })
	local ran = assert(shell.block(shell.list()[1], 1), "block 1 of the first shell")
	assert(ran.uid == first.id and first.id ~= 1, "its id isn't its number")
	local picked = tool("shell_run", { command = `${first.id} | select name`, cwd = dir })
	assert(picked.status == "done", `{picked.status}: {picked.stderr} {picked.stdout}`)
	assert(inside(picked.stdout) == "name\na\n", picked.stdout)
	local gone = tool("shell_run", { command = "$9999 | select name", cwd = dir })
	assert(string.find(inside(gone.stderr), "no block with id 9999", 1, true), gone.stderr)
end)

test("a tool called without what it needs, or with what it doesn't take, says so", function()
	local missing = agent.call("shell_run", {}, agent.caller())
	assert(missing.isError, "an error")
	assert(
		string.find(
			agent.as_text(missing),
			"shell_run needs command; it takes command (required)",
			1,
			true
		),
		agent.as_text(missing)
	)
	local wrong = agent.call("shell_run", { cmd = "ls" }, agent.caller())
	assert(
		string.find(agent.as_text(wrong), "shell_run has no argument cmd", 1, true),
		agent.as_text(wrong)
	)
	-- Run directly, it still says so, and runs nothing.
	local ok, err = pcall(tool, "shell_run", {})
	assert(not ok and string.find(tostring(err), "needs command", 1, true), tostring(err))
	assert(#shell.list() == 0, "no shell opened")
end)

test("shell_read reads the user's blocks too; only an agent's can be stopped", function(t)
	local dir = t:tempdir()
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = dir
	local mine = assert(shell.run(sh, "echo mine", { runner = "pipe" }))
	t:wait_for(function()
		return mine.status ~= "running"
	end)
	local last = tool("shell_read", { last = true })
	assert(last.id == mine.uid and last.by == "user" and inside(last.stdout) == "mine\n")
	local short = tool("shell_read", { id = mine.uid, include_output = false })
	assert(short.stdout == nil and short.status == "done", tostring(short.stdout))
	local ok, err = pcall(tool, "shell_kill", { id = mine.uid })
	assert(not ok and string.find(tostring(err), "agent", 1, true), tostring(err))
	-- The agent's runs go to this shell, the project's first.
	tool("shell_run", { command = "true", cwd = dir })
	assert(#sh.blocks == 2 and sh.blocks[2].by == "agent")
end)
