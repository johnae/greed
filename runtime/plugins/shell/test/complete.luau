local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")
local shell = require("@shell")

type Shell = typeof(shell.open())

-- How long an ask for completions may take: it can start programs, slow
-- while every plugin's tests run at once.
local ASK_MS = 20000

local function open(t: test.TestContext, dir: string): Shell
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = dir
	return sh
end

local function at_prompt(sh: Shell): string
	return shell.log.prompt_text(sh)
end

-- Puts `text` at the prompt and asks what could complete it, with tab
-- while typing, waiting for the menu: what completes a program's
-- arguments may come from programs.
local function complete(t: test.TestContext, sh: Shell, text: string): string
	shell.log.set_prompt(sh, text, { greed.view() })
	greed.mode.set(core.style.typing_mode())
	t:keys("tab")
	t:wait_for(function()
		return #t:floats() > 0
	end, ASK_MS)
	return table.concat(t:floats(), "\n")
end

test("tab completes programs on PATH and builtins for a command's first word", function(t)
	local dir = t:tempdir({ ["bin/greedtestprog"] = "", ["bin/other"] = "" })
	local sh = open(t, dir)
	shell.run(sh, `export PATH={dir}/bin`)
	local menu = complete(t, sh, "greedtest")
	assert(string.find(menu, "greedtestprog", 1, true), menu)
	t:keys("enter")
	assert(at_prompt(sh) == "greedtestprog", "enter takes it, without running: " .. at_prompt(sh))
	assert(#sh.blocks == 1)
	local builtins = complete(t, sh, "expo")
	assert(string.find(builtins, "export", 1, true), builtins)
end)

test("tab completes files and folders from the shell's folder", function(t)
	local dir = t:tempdir({ ["subdir/inner.txt"] = "", ["other.txt"] = "" })
	local sh = open(t, dir)
	local menu = complete(t, sh, "cat subd")
	assert(string.find(menu, "subdir/", 1, true), menu)
	t:keys("enter")
	assert(at_prompt(sh) == "cat subdir/", at_prompt(sh))
	local inner = complete(t, sh, "cat subdir/in")
	assert(string.find(inner, "subdir/inner.txt", 1, true), inner)
	t:keys("enter")
	assert(at_prompt(sh) == "cat subdir/inner.txt", at_prompt(sh))
end)

test("tab completes variables, earlier blocks and open files", function(t)
	local dir = t:tempdir({ ["notes.md"] = "hi" })
	local sh = open(t, dir)
	shell.run(sh, "export GREED_COMPLETE_ME=1")
	local vars = complete(t, sh, "echo $GREED_COMPLETE")
	assert(string.find(vars, "$GREED_COMPLETE_ME", 1, true), vars)
	t:keys("enter")
	assert(at_prompt(sh) == "echo $GREED_COMPLETE_ME", at_prompt(sh))
	t:keys("esc")
	local blocks = complete(t, sh, "echo $1")
	assert(
		string.find(blocks, "$1", 1, true) and string.find(blocks, "export GREED", 1, true),
		blocks
	)
	t:keys("esc")
	greed.load(dir .. "/notes.md")
	local bufs = complete(t, sh, "cat buf:no")
	assert(string.find(bufs, "buf:notes.md", 1, true), bufs)
	t:keys("esc")
	local done = assert(shell.run(sh, "echo x > buf:made-here"))
	t:wait_for(function()
		return done.status ~= "running"
	end)
	local made = complete(t, sh, "buf:ma")
	assert(string.find(made, "buf:made-here", 1, true), made)
	t:keys("esc")
	local editor = complete(t, sh, "@s")
	assert(string.find(editor, "@sel", 1, true), editor)
end)

test("output streaming above the prompt leaves the completion menu working", function(t)
	local dir = t:tempdir({ ["subdir/inner.txt"] = "" })
	local sh = open(t, dir)
	local block = assert(shell.run(sh, "sh -c 'echo started; read x; echo more; echo lines'", {
		view = greed.view(),
	}))
	t:wait_for(function()
		return string.find(sh.buffer:text(), "started", 1, true) ~= nil
	end)
	local menu = complete(t, sh, "cat subd")
	assert(string.find(menu, "subdir/", 1, true), menu)
	local term = assert(assert(block.job).terminal)
	term:key("enter")
	t:wait_for(function()
		return block.status ~= "running"
	end)
	assert(#t:floats() == 1, "the menu stays open")
	t:keys("enter")
	assert(at_prompt(sh) == "cat subdir/", at_prompt(sh))
end)

type Item = { label: string, text: string, detail: string?, badge: string?, from: number? }

-- What completes `text` at `sh`'s prompt, by label.
local function items_for(t: test.TestContext, sh: Shell, text: string): { [string]: Item }
	shell.log.set_prompt(sh, text, { greed.view() })
	local found: { Item }? = nil
	greed.spawn(function()
		found = shell.completion.items(greed.view(), { explicit = true }) or {}
	end)
	t:wait_for(function()
		return found ~= nil
	end, ASK_MS)
	local by: { [string]: Item } = {}
	for _, one in assert(found) do
		by[one.label] = one
	end
	return by
end

-- The item labelled `label`, which has to be there.
local function item(items: { [string]: Item }, label: string): Item
	local found = items[label]
	if found == nil then
		error(`no {label}`, 2)
	end
	return found
end

type Block = typeof(assert(shell.run(shell.open(), "true")))

-- Runs `line` in `sh` and waits for it.
local function run_and_wait(t: test.TestContext, sh: Shell, line: string): Block
	local block = assert(shell.run(sh, line, { view = greed.view() }))
	t:wait_for(function()
		return block.status ~= "running"
	end)
	return block
end

local function names(items: { [string]: Item }): string
	local list: { string } = {}
	for label in items do
		table.insert(list, label)
	end
	table.sort(list)
	return table.concat(list, " ")
end

test("the shell's own builtins are marked as Greed's, with what they do", function(t)
	local sh = open(t, t:tempdir())
	local first = items_for(t, sh, "")
	local export = assert(first.export, "a builtin")
	assert(
		export.badge == "greed" and export.detail == shell.parse.BUILTINS.export.doc,
		tostring(export.detail)
	)
	assert(first.sh and first.sh.badge == nil, "a program on PATH isn't Greed's")
	-- The menu shows the badge and the doc.
	local menu = complete(t, sh, "expo")
	assert(
		string.find(menu, "greed", 1, true) and string.find(menu, "Set variables", 1, true),
		menu
	)
	t:keys("esc")
	-- So are $3, buf: and @sel.
	run_and_wait(t, sh, "true")
	assert(item(items_for(t, sh, "echo $1"), "$1").badge == "greed")
	assert(item(items_for(t, sh, "@s"), "@sel").badge == "greed")
end)

test("builtins' arguments complete as they're declared", function(t)
	local dir = t:tempdir({ ["sub/x"] = "", ["file.txt"] = "" })
	local sh = open(t, dir)
	assert(names(items_for(t, sh, "cd ")) == "sub/", "folders only")
	greed.load(dir .. "/file.txt")
	local opened = items_for(t, sh, "open ")
	assert(opened["file.txt"] and opened["sub/"] and opened["buf:file.txt"], names(opened))
	assert(item(opened, "buf:file.txt").badge == "greed")
	shell.run(sh, "export GREED_MINE=1")
	local exported = items_for(t, sh, "export GREED_M")
	assert(
		exported["GREED_MINE="] and exported["GREED_MINE="].detail == "set in this shell",
		names(exported)
	)
	assert(items_for(t, sh, "unset GREED_M")["GREED_MINE"], "unset names variables")
	local topics = items_for(t, sh, "help ")
	assert(names(topics) == "builtins keys line prompt tables", names(topics))
	assert(topics.tables.badge == "greed")
	assert(names(items_for(t, sh, "history ")) == "", "history takes nothing")
	-- help with a topic shows that part.
	local tables = run_and_wait(t, sh, "help tables")
	assert(string.find(tables.output, "where COL OP VALUE", 1, true), tables.output)
	assert(not string.find(tables.output, "Run by the shell itself", 1, true), tables.output)
	assert(run_and_wait(t, sh, "help nothing").status == "failed")
end)

local PODS = table.concat({
	"NAME           READY   STATUS             RESTARTS   AGE",
	"api-1          1/1     Running            0          3d",
	"worker-2       0/1     CrashLoopBackOff   4          2h",
	"",
}, "\n")

test("after $3 |, the stages, the columns of the table, comparisons and cells complete", function(t)
	local dir = t:tempdir({ ["pods.txt"] = PODS })
	local sh = open(t, dir)
	run_and_wait(t, sh, "cat pods.txt")
	local stages = items_for(t, sh, "$1 | ")
	assert(
		stages.where and stages.where.badge == "greed" and stages.sort and stages.from,
		names(stages)
	)
	assert(
		stages.where.detail == "The rows passing a test: = != ~ !~ < > <= >=",
		tostring(stages.where.detail)
	)
	assert(stages.cat and stages.cat.badge == nil, "programs too")
	local columns = items_for(t, sh, "$1 | where ")
	assert(names(columns) == "AGE NAME READY RESTARTS STATUS", names(columns))
	local ops = items_for(t, sh, "$1 | where STATUS ")
	assert(ops["="] and ops["~"] and ops[">="], names(ops))
	local cells = items_for(t, sh, "$1 | where STATUS = ")
	assert(names(cells) == "CrashLoopBackOff Running", names(cells))
	-- `COL=` and what's after it.
	local typed = items_for(t, sh, "$1 | where STATUS=Ru")
	local running = item(typed, "Running")
	assert(sh.buffer:slice(assert(running.from), sh.buffer:len()) == "Ru", "after the =")
	local selected = items_for(t, sh, "$1 | select NAME,")
	assert(not selected.NAME and selected.AGE, names(selected))
	assert(
		sh.buffer:slice(assert(item(selected, "AGE").from), sh.buffer:len()) == "",
		"after the comma"
	)
	local sorted = items_for(t, sh, "$1 | sort ")
	assert(sorted.AGE and sorted["-r"], names(sorted))
	assert(names(items_for(t, sh, "$1 | from ")) == "csv json tsv")
	assert(names(items_for(t, sh, "$1 | columns ")) == "-H")
	-- Through the stages before: select left two columns.
	assert(names(items_for(t, sh, "$1 | select NAME,AGE | sort ")) == "-r AGE NAME")
	-- Not after a program.
	assert(items_for(t, sh, "$1 | cat | ").where == nil)
end)

test("the shell's page in the docs lists every builtin and stage as declared", function()
	-- The page, from the folder the tests run in or one above it.
	local page: string? = nil
	local dir = greed.fs.cwd()
	for _ = 1, 4 do
		page = greed.fs.read(`{dir}/docs/shell.md`)
		if page then
			break
		end
		dir ..= "/.."
	end
	local text = assert(page, "docs/shell.md")
	local function listed(usage: string, doc: string)
		local row = `| \`{(string.gsub(usage, "|", "\\|"))}\` | {doc} |`
		assert(string.find(text, row, 1, true), row)
	end
	for _, name in shell.parse.builtin_names() do
		local builtin = shell.parse.BUILTINS[name]
		listed(builtin.usage, builtin.doc)
	end
	for _, stage in shell.tables.STAGES do
		listed(stage.usage, stage.doc)
	end
end)
