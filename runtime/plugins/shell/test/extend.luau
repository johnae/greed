local test = require("@greed/test")
local greed = require("@greed")
local shell = require("@shell")

type Shell = typeof(shell.open())
type Block = typeof(assert(shell.run(shell.open(), "true")))

local function open(t: test.TestContext): Shell
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = t:tempdir()
	return sh
end

local function ran(t: test.TestContext, sh: Shell, line: string): Block
	local block = assert(shell.run(sh, line, { runner = "pipe" }))
	t:wait_for(function()
		return block.status ~= "running"
	end)
	return block
end

local TABLE = "printf 'NAME  SIZE\\nann   2\\nbob   5\\n'"

test("a plugin's stage runs on tables, after $3 | and after programs", function(t)
	shell.stage({
		name = "double",
		usage = "double COL",
		doc = "Each number in a column twice over",
		args = "column",
		starts = true,
	}, function(tbl: shell.Table, rest: string)
		local column = shell.tables.column(tbl, rest)
		if column == nil then
			return nil, `no column {rest}`
		end
		local rows = {}
		for i, row in tbl.rows do
			local copy = table.clone(row)
			copy[column] = tostring((tonumber(row[column]) or 0) * 2)
			rows[i] = copy
		end
		return { columns = tbl.columns, rows = rows }, nil
	end)
	local sh = open(t)
	local block = ran(t, sh, TABLE)
	local doubled = ran(t, sh, `${block.number} | double SIZE | where SIZE > 5`)
	assert(doubled.table and #doubled.table.rows == 1, doubled.output)
	assert(doubled.table.rows[1].SIZE == "10", doubled.output)
	local after = ran(t, sh, `{TABLE} | double size`)
	assert(after.table and after.table.rows[1].SIZE == "4", after.output)
	local wrong = ran(t, sh, `${block.number} | double NOPE`)
	assert(
		wrong.status == "failed" and string.find(wrong.stderr, "double: no column NOPE", 1, true)
	)
	local which = ran(t, sh, "which double")
	assert(string.find(which.stdout, "double: a table stage", 1, true), which.stdout)
	local ok, err = pcall(function()
		shell.stage({ name = "where", usage = "where", doc = "mine" }, function(tbl: shell.Table)
			return tbl, nil
		end)
	end)
	assert(not ok and string.find(tostring(err), "shell's own stages", 1, true), tostring(err))
end)

test("a plugin's builtin runs ahead of programs, and ^NAME skips it", function(t)
	shell.builtin({ name = "greet", usage = "greet NAME", doc = "Say hello" }, function(args, ctx)
		if args[1] == nil then
			ctx.error("greet: who?\n")
			return 2
		end
		ctx.write(`hello {args[1]} from {ctx.cwd == ctx.block.cwd and "here" or "?"}\n`)
		return nil
	end)
	shell.builtin({ name = "explode", usage = "explode", doc = "Fail" }, function()
		error("it went wrong", 0)
	end)
	local sh = open(t)
	local hello = ran(t, sh, "greet bob")
	assert(hello.status == "done" and hello.output == "hello bob from here\n", hello.output)
	local who = ran(t, sh, "greet")
	assert(who.code == 2 and string.find(who.output, "greet: who?", 1, true), who.output)
	local boom = ran(t, sh, "explode")
	assert(boom.status == "failed" and string.find(boom.output, "it went wrong", 1, true))
	local program = ran(t, sh, "^greet")
	assert(program.code == 127, "no program called greet: " .. tostring(program.code))
	assert(shell.parse.BUILTINS.greet.doc == "Say hello", "for help and completion")
	local ok, err = pcall(function()
		shell.builtin({ name = "cd", usage = "cd", doc = "mine" }, function()
			return 0
		end)
	end)
	assert(not ok and string.find(tostring(err), "shell's own builtins", 1, true), tostring(err))
end)

test("a builtin that waits stops with ctrl-c, and what it does after goes nowhere", function(t)
	local go = greed.signal()
	local saw_stop = false
	shell.builtin({ name = "hang", usage = "hang", doc = "Wait for a go" }, function(_, ctx)
		go:wait()
		saw_stop = ctx.stopped()
		ctx.write("too late\n")
		return 0
	end)
	local sh = open(t)
	-- Run aside, since it waits.
	greed.spawn(function()
		shell.run(sh, "hang")
	end)
	t:wait(10)
	local block = sh.blocks[#sh.blocks]
	assert(block and block.command == "hang", "it runs")
	local function status(): string
		return block.status
	end
	assert(status() == "running", status())
	shell.interrupt(block)
	assert(status() == "killed" and block.signal == "INT", `{status()} {block.signal}`)
	go:send(true)
	t:wait(10)
	assert(saw_stop, "it can tell")
	assert(status() == "killed", status())
	assert(not string.find(block.output or "", "too late", 1, true), block.output)
end)
