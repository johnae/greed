local test = require("@greed/test")
local greed = require("@greed")
local shell = require("@shell")

type Shell = typeof(shell.open())
type Block = typeof(assert(shell.run(shell.open(), "true")))

local function open(t: test.TestContext, dir: string): Shell
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = dir
	return sh
end

-- Runs `line` as typed at the prompt and waits for it to finish.
local function run(t: test.TestContext, sh: Shell, line: string): Block
	shell.log.set_prompt(sh, line, { greed.view() })
	t:keys("enter")
	local block = sh.blocks[#sh.blocks]
	t:wait_for(function()
		return block.status ~= "running"
	end)
	return block
end

-- What the shell sets `name` to: a value, false when it's left out, nil
-- when it's the editor's.
local function var(sh: Shell, name: string): string | false | nil
	return sh.env[name]
end

-- The checks every known shell family passes, given the lines that do
-- each thing in it.
local function carries(
	t: test.TestContext,
	program: string,
	lines: { cd: string, set: string, unset: string, fail: string }
)
	greed.option.set("shell-fallback", program)
	local dir = t:tempdir({ ["sub/x.txt"] = "x" })
	local sh = open(t, dir)
	local moved = run(t, sh, lines.cd)
	assert(moved.status == "done", `{program}: {moved.output}`)
	assert(moved.program == program, tostring(moved.program))
	assert(sh.cwd == dir .. "/sub", `{program}: {sh.cwd}`)
	assert(moved.cwd_after == dir .. "/sub")
	assert(string.find(moved.output, dir .. "/sub", 1, true), moved.output)
	shell.run(sh, "export GREED_GONE=x")
	local set = run(t, sh, lines.set)
	assert(var(sh, "GREED_SET") == "1", `{program}: {set.output}`)
	assert(set.env_changed and set.env_changed.GREED_SET == "1")
	local unset = run(t, sh, lines.unset)
	assert(var(sh, "GREED_GONE") == false, `{program}: {unset.output}`)
	assert(unset.env_changed and unset.env_changed.GREED_GONE == false)
	-- What changed carries over to programs after.
	local shown = run(t, sh, "printenv GREED_SET")
	assert(shown.output == "1\n", shown.output)
	local failed = run(t, sh, lines.fail)
	assert(failed.status == "failed" and failed.code ~= 0, `{program}: {failed.status}`)
	assert(sh.cwd == dir .. "/sub", "a failing line leaves the folder alone")
end

test("cd and export in a POSIX shell's line carry over, and its exit code survives", function(t)
	carries(t, "sh", {
		cd = "cd sub && pwd",
		set = "export GREED_SET=1 && true",
		unset = "unset GREED_GONE; true",
		fail = "false || (exit 7)",
	})
	local sh = assert(shell.of(greed.view():buffer()))
	local code = run(t, sh, "cd .. && (exit 3)")
	assert(code.code == 3, tostring(code.code))
	assert(string.find(sh.cwd, "/sub$") == nil, "moved before failing: " .. sh.cwd)
	local exited = run(t, sh, "echo bye; exit 5")
	assert(exited.code == 5 and exited.output == "bye\n", `{exited.code} {exited.output}`)
end)

test("fish's lines carry over too", function(t)
	if greed.which("fish") == nil then
		return
	end
	carries(t, "fish", {
		cd = "cd sub; and pwd",
		set = "set -gx GREED_SET 1; true",
		unset = "set -e GREED_GONE; true",
		fail = "false; or false",
	})
end)

test("nu's lines carry over too", function(t)
	if greed.which("nu") == nil then
		return
	end
	carries(t, "nu", {
		cd = "cd sub; pwd",
		set = '$env.GREED_SET = "1"; null',
		unset = "hide-env GREED_GONE; null",
		fail = "error make { msg: 'no' }; null",
	})
end)

test("an agent's lines run in sh and leave the shell where it was", function(t)
	greed.option.set("shell-fallback", "bash")
	local dir = t:tempdir({ ["sub/x.txt"] = "x" })
	local sh = open(t, dir)
	local block = assert(shell.run(sh, "cd sub && export GREED_SET=1 && pwd", { by = "agent" }))
	t:wait_for(function()
		return block.status ~= "running"
	end)
	assert(block.program == "sh" and block.runner == "pipe", `{block.program} {block.runner}`)
	assert(block.output == dir .. "/sub\n", block.output)
	assert(block.cwd_after == dir .. "/sub")
	assert(block.env_changed and block.env_changed.GREED_SET == "1")
	assert(sh.cwd == dir and var(sh, "GREED_SET") == nil, sh.cwd)
end)

test("a shell of another kind runs the line, and says cd doesn't carry over", function(t)
	local dir = t:tempdir({ ["sub/x.txt"] = "x", ["myshell"] = 'exec sh "$@"\n' })
	local sh = open(t, dir)
	-- Made runnable with the shell itself, before it runs the lines.
	run(t, sh, "chmod +x myshell")
	greed.option.set("shell-fallback", dir .. "/myshell")
	local block = run(t, sh, "cd sub && pwd")
	assert(block.output == dir .. "/sub\n", block.output)
	assert(block.program == "myshell", tostring(block.program))
	assert(sh.cwd == dir, sh.cwd)
	assert(
		block.note and string.find(block.note, "don't carry over", 1, true),
		tostring(block.note)
	)
end)

test("the fallback shell reads its startup files when asked", function(t)
	if greed.which("bash") == nil then
		return
	end
	local dir = t:tempdir({ [".bashrc"] = "alias greedhi='echo hi from rc'\n" })
	greed.option.set("shell-fallback", "bash")
	local sh = open(t, dir)
	shell.run(sh, "export HOME=" .. dir)
	local without = run(t, sh, "greedhi | cat")
	assert(not string.find(without.output, "hi from rc", 1, true), without.output)
	greed.option.set("shell-fallback-rc", true)
	local with = run(t, sh, "greedhi | cat")
	assert(string.find(with.output, "hi from rc", 1, true), with.output)
end)

test("without a shell named, an unknown $SHELL gives way to sh", function(t)
	greed.option.set("shell-fallback", "")
	local dir = t:tempdir({ ["sub/x.txt"] = "x" })
	local sh = open(t, dir)
	shell.run(sh, "export SHELL=/nowhere/elvish")
	local block = run(t, sh, "cd sub && pwd")
	assert(block.program == "sh", tostring(block.program))
	assert(sh.cwd == dir .. "/sub", sh.cwd)
	assert(block.note == nil, tostring(block.note))
end)

test("an error names the line of what you typed, and the shell it ran in", function(t)
	greed.option.set("shell-fallback", "sh")
	local sh = open(t, t:tempdir({}))
	local block = run(t, sh, "greed_no_such_command_x | cat")
	assert(
		string.find(block.output, "sh: line 1: greed_no_such_command_x", 1, true)
			or string.find(block.output, "sh: 1: greed_no_such_command_x", 1, true),
		block.output
	)
	assert(not string.find(block.output, "greed-shell", 1, true), block.output)
	greed.option.set("shell-fallback", "")
end)

test("a table a nu line gives back is data: its rows things, on their lines", function(t)
	if greed.which("nu") == nil then
		return
	end
	greed.option.set("shell-fallback", "nu")
	local dir = t:tempdir({ ["notes.txt"] = "hello\n", ["src/main.rs"] = "" })
	local sh = open(t, dir)
	local block = run(t, sh, "ls | sort-by name")
	local tbl = assert(block.table, block.output)
	assert(block.called and block.called.many == "files", block.output)
	assert(tbl.rows[1].name == "notes.txt" and tbl.rows[2].type == "dir")
	assert(type(block.value) == "table" and block.value[1].name == "notes.txt")
	-- Each row is an object that says the line it's on.
	local objects = require("@core").objects
	local here = assert(objects.get(`shell-block:{sh.buffer:id()}.{block.number}`))
	local rows = assert(objects.related(here).rows)
	local folder: any = assert(rows[2])
	assert(folder.id == `folder:{dir}/src`, folder.id)
	local line = sh.buffer:line_of(assert(folder.from))
	local text =
		string.sub(sh.buffer:text(), sh.buffer:line_start(line) + 1, sh.buffer:line_end(line))
	assert(string.find(text, "src", 1, true) and string.find(text, "1", 1, true), text)
	-- What isn't a table prints as it did, and keeps nothing.
	local said = run(t, sh, "echo hi | str upcase")
	assert(said.data == nil and string.find(said.output, "HI", 1, true), said.output)
	-- The shell's own stages after nu work on the table nu gave back, not
	-- on how nu drew it.
	local first = run(t, sh, "ls | sort-by name | first")
	assert(first.code == 0, first.output)
	local only = assert(first.table, first.output)
	assert(#only.rows == 1 and only.rows[1].name == "notes.txt", first.output)
	local small = run(t, sh, "ls | where type = file")
	assert(small.code == 0 and #assert(small.table).rows == 1, small.output)
end)
