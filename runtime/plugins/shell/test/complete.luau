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

-- Puts `text` at the prompt and presses tab, waiting for what it does:
-- a menu, or the prompt completed in place. What completes a program's
-- arguments may come from programs.
local function tab(t: test.TestContext, sh: Shell, text: string): string
	shell.log.set_prompt(sh, text, { greed.view() })
	greed.mode.set(core.style.typing_mode())
	t:keys("tab")
	t:wait_for(function()
		return #t:floats() > 0 or at_prompt(sh) ~= text
	end, ASK_MS)
	return table.concat(t:floats(), "\n")
end

-- Types `keys` at an empty prompt and waits for the menu that opens by
-- itself once typing pauses.
local function pause(t: test.TestContext, keys: string): string
	greed.mode.set(core.style.typing_mode())
	if keys ~= "" then
		t:keys(keys)
	end
	t:wait(greed.option.get("completion-delay") :: number)
	t:wait_for(function()
		return #t:floats() > 0
	end, ASK_MS)
	return table.concat(t:floats(), "\n")
end

test(
	"tab completes the only match at once, then what several start with, then the menu",
	function(t)
		local dir = t:tempdir({
			["bin/greedtestprog"] = "",
			["bin/greedtestother"] = "",
			["bin/zzz"] = "",
		})
		local sh = open(t, dir)
		shell.run(sh, `export PATH={dir}/bin`)
		tab(t, sh, "greedtestp")
		assert(at_prompt(sh) == "greedtestprog", at_prompt(sh))
		assert(#t:floats() == 0, "no menu for the only match")
		assert(#sh.blocks == 1, "nothing ran")
		tab(t, sh, "greedt")
		assert(at_prompt(sh) == "greedtest", "what both start with: " .. at_prompt(sh))
		assert(#t:floats() == 0, "no menu yet")
		-- Nothing more in common: the menu, with nothing chosen.
		local menu = tab(t, sh, "greedtest")
		assert(at_prompt(sh) == "greedtest", at_prompt(sh))
		assert(
			string.find(menu, "greedtestprog", 1, true)
				and string.find(menu, "greedtestother", 1, true),
			menu
		)
		-- tab again puts each in place, shift-tab goes back.
		t:keys("tab")
		local first = at_prompt(sh)
		assert(first == "greedtestprog" or first == "greedtestother", first)
		assert(#t:floats() == 1, "the menu stays")
		t:keys("tab")
		local second = at_prompt(sh)
		assert(second ~= first and string.sub(second, 1, 9) == "greedtest", second)
		t:keys("shift-tab")
		assert(at_prompt(sh) == first, at_prompt(sh))
		-- enter keeps it, without running.
		t:keys("enter")
		assert(at_prompt(sh) == first and #t:floats() == 0, at_prompt(sh))
		assert(#sh.blocks == 1, "enter kept the item without running")
		-- So does typing on.
		tab(t, sh, "greedtest")
		t:keys("tab space x")
		assert(at_prompt(sh) == first .. " x", at_prompt(sh))
		assert(#t:floats() == 0)
		tab(t, sh, "expo")
		assert(at_prompt(sh) == "export", at_prompt(sh))
	end
)

test("tab completes files and folders from the shell's folder", function(t)
	local dir = t:tempdir({ ["subdir/inner.txt"] = "", ["other.txt"] = "" })
	local sh = open(t, dir)
	tab(t, sh, "cat subd")
	assert(at_prompt(sh) == "cat subdir/", at_prompt(sh))
	tab(t, sh, "cat subdir/in")
	assert(at_prompt(sh) == "cat subdir/inner.txt", at_prompt(sh))
	local both = items_for(t, sh, "cat ")
	assert(both["subdir/"] and both["other.txt"], "both")
end)

test("tab completes variables, earlier blocks and open files", function(t)
	local dir = t:tempdir({ ["notes.md"] = "hi" })
	local sh = open(t, dir)
	shell.run(sh, "export GREED_COMPLETE_ME=1")
	tab(t, sh, "echo $GREED_COMPLETE")
	assert(at_prompt(sh) == "echo $GREED_COMPLETE_ME", at_prompt(sh))
	local blocks = items_for(t, sh, "echo $1")
	assert(
		blocks["$1"] and string.find(blocks["$1"].detail or "", "export GREED", 1, true),
		"block 1, with its command"
	)
	greed.load(dir .. "/notes.md")
	assert(items_for(t, sh, "cat buf:no")["buf:notes.md"], "an open file")
	local done = assert(shell.run(sh, "echo x > buf:made-here"))
	t:wait_for(function()
		return done.status ~= "running"
	end)
	assert(items_for(t, sh, "buf:ma")["buf:made-here"], "a buffer > buf: made")
	assert(items_for(t, sh, "@s")["@sel"], "@sel")
end)

test("output streaming above the prompt leaves the completion menu working", function(t)
	local dir = t:tempdir({ ["subdir/inner.txt"] = "", ["subway.txt"] = "" })
	local sh = open(t, dir)
	local block = assert(shell.run(sh, "sh -c 'echo started; read x; echo more; echo lines'", {
		view = greed.view(),
	}))
	t:wait_for(function()
		return string.find(sh.buffer:text(), "started", 1, true) ~= nil
	end)
	local menu = tab(t, sh, "cat sub")
	assert(string.find(menu, "subdir/", 1, true), menu)
	local term = assert(assert(block.job).terminal)
	term:key("enter")
	t:wait_for(function()
		return block.status ~= "running"
	end)
	assert(#t:floats() == 1, "the menu stays open")
	t:keys("tab enter")
	local typed = at_prompt(sh)
	assert(typed == "cat subdir/" or typed == "cat subway.txt", typed)
end)

test("a menu that opened by itself leaves enter and the arrows to the prompt", function(t)
	local dir = t:tempdir({ ["subdir/inner.txt"] = "", ["subway.txt"] = "" })
	local sh = open(t, dir)
	shell.run(sh, "echo older")
	-- Not before typing pauses.
	greed.mode.set(core.style.typing_mode())
	t:keys("c a t space s u")
	assert(#t:floats() == 0, "no menu while typing")
	local menu = pause(t, "")
	assert(string.find(menu, "subdir/", 1, true), menu)
	-- enter runs what's typed: nothing in the menu was chosen.
	t:keys("enter")
	assert(#sh.blocks == 2, "enter ran the line")
	assert(sh.blocks[2].command == "cat su", sh.blocks[2].command)
	-- Its output comes in first.
	t:wait_for(function()
		return sh.blocks[2].status ~= "running"
	end)
	t:wait(0)
	-- up goes through the history, not the menu.
	pause(t, "e c h")
	t:keys("up")
	assert(#t:floats() == 0, "the menu closed")
	assert(at_prompt(sh) == "echo older", at_prompt(sh))
	-- Once tab moved into the menu, enter takes the item and the arrows
	-- move through it.
	shell.log.set_prompt(sh, "", { greed.view() })
	pause(t, "c a t space s u")
	t:keys("tab")
	local first = at_prompt(sh)
	t:keys("down")
	assert(at_prompt(sh) ~= first and #t:floats() == 1, at_prompt(sh))
	t:keys("enter")
	assert(#sh.blocks == 2, "enter kept the item")
	assert(at_prompt(sh) == "cat subdir/" or at_prompt(sh) == "cat subway.txt", at_prompt(sh))
end)

test("completion-enter first makes enter take the first item of any menu", function(t)
	local dir = t:tempdir({ ["subdir/inner.txt"] = "", ["subway.txt"] = "" })
	local sh = open(t, dir)
	greed.option.set("completion-enter", "first")
	pause(t, "c a t space s u")
	t:keys("enter")
	assert(#sh.blocks == 0, "enter took the item")
	assert(at_prompt(sh) == "cat subdir/" or at_prompt(sh) == "cat subway.txt", at_prompt(sh))
	greed.option.set("completion-enter", "auto")
end)

test("command names starting with what's typed come before other matches", function(t)
	local dir = t:tempdir({ ["bin/hcisecfilter"] = "", ["bin/zhistory"] = "" })
	local sh = open(t, dir)
	shell.run(sh, `export PATH={dir}/bin`)
	local lsp = require("@lsp")
	local found = items_for(t, sh, "hist")
	local labels: { string } = {}
	for _, one in found do
		table.insert(labels, one.label)
	end
	local order = lsp.completion.rank("hist", labels)
	local ranked: { string } = {}
	for _, index in order do
		table.insert(ranked, labels[index])
	end
	assert(ranked[1] == "history", table.concat(ranked, " "))
	local holding = assert(table.find(ranked, "zhistory"), "zhistory")
	local fuzzy = assert(table.find(ranked, "hcisecfilter"), "hcisecfilter")
	assert(holding < fuzzy, table.concat(ranked, " "))
	tab(t, sh, "hist")
	assert(at_prompt(sh) == "history", at_prompt(sh))
end)

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
	shell.log.set_prompt(sh, "", { greed.view() })
	local menu = pause(t, "e x p o")
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
		page = greed.fs.read(`{dir}/runtime/docs/shell.md`)
		if page then
			break
		end
		dir ..= "/.."
	end
	local text = assert(page, "runtime/docs/shell.md")
	local function listed(usage: string, doc: string)
		local row = `| \`{(string.gsub(usage, "|", "\\|"))}\` | {doc} |`
		assert(string.find(text, row, 1, true), row)
	end
	-- The shell's own; plugins document theirs.
	for _, name in shell.parse.builtin_names() do
		local builtin = shell.parse.BUILTINS[name]
		if builtin.plugin == nil then
			listed(builtin.usage, builtin.doc)
		end
	end
	for _, stage in shell.tables.STAGES do
		if stage.plugin == nil then
			listed(stage.usage, stage.doc)
		end
	end
end)

test("after $3 | on JSON, get completes its fields and the stages an object's columns", function(t)
	local list = [[{"kind": "List", "items": [{"name": "a", "phase": "Running"}]}]]
	local dir = t:tempdir({ ["list.json"] = list })
	local sh = open(t, dir)
	run_and_wait(t, sh, "cat list.json")
	assert(names(items_for(t, sh, "$1 | get ")) == "items kind", "the object's fields")
	assert(item(items_for(t, sh, "$1 | get items"), "items").detail == "array")
	assert(names(items_for(t, sh, "$1 | get items.")) == "items.0", "the array's items")
	assert(names(items_for(t, sh, "$1 | get items.0.")) == "items.0.name items.0.phase")
	local columns = items_for(t, sh, "$1 | where ")
	assert(columns.kind and columns.phase and columns.name, names(columns))
end)
