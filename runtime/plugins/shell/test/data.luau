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

local function finished(t: test.TestContext, block: Block?): Block
	local b = assert(block, "a block")
	t:wait_for(function()
		return b.status ~= "running"
	end)
	return b
end

-- Runs `line` in `sh` as typed and waits for it.
local function run(t: test.TestContext, sh: Shell, line: string): Block
	return finished(t, shell.run(sh, line, { view = greed.view() }))
end

-- The status text shown after `block`'s command.
local function status(sh: Shell, block: Block): string
	for _, mark in sh.buffer:decorations(`shell.block.{block.uid}`) do
		if mark.eol then
			return mark.text or ""
		end
	end
	return ""
end

test("data going in and out is read off the line", function()
	local p = shell.parse.parse("$3 | sort -r > buf:out")
	assert(p.kind == "argv" and p.input == "$3" and p.into, p.kind)
	assert(p.into.name == "out" and not p.into.append)
	assert(p.argv and p.argv[1] == "sort" and p.argv[2] == "-r")
	local appended = shell.parse.parse("ls *.log >> buf:logs")
	assert(appended.kind == "shell" and appended.line == "ls *.log", appended.line)
	assert(appended.into and appended.into.append)
	local alone = shell.parse.parse("@sel > buf:keep")
	assert(alone.kind == "source" and alone.input == "@sel", alone.kind)
	-- `||` and a `>` to a file are left to a real shell.
	assert(shell.parse.parse("$3 || true").input == nil)
	assert(shell.parse.parse("echo hi > out.txt").into == nil)
	assert(shell.parse.parse("!cat > buf:x").error, "a terminal can't write a buffer")
	assert(shell.parse.parse("$1 |").error, "nothing after |")
end)

test("$N sends a block's output to a command, through a pipe", function(t)
	local sh = open(t, t:tempdir())
	run(t, sh, "printf 'b\\na\\nc\\n'")
	local sorted = run(t, sh, "$1 | sort")
	assert(sorted.output == "a\nb\nc\n", sorted.output)
	assert(sorted.runner == "pipe" and sorted.input == "$1", sorted.runner)
	-- Through a real shell too.
	local counted = run(t, sh, "$1 | grep a | wc -l")
	assert(counted.via == "shell", counted.via)
	assert(string.match(counted.output, "^%s*1\n$"), counted.output)
	-- Alone, it shows it again.
	local again = run(t, sh, "$2")
	assert(again.output == "a\nb\nc\n" and again.status == "done", again.output)
	local missing = run(t, sh, "$9 | cat")
	assert(missing.status == "failed", missing.status)
	assert(string.find(missing.stderr, "no block 9", 1, true), missing.stderr)
end)

test("buf:NAME, @file and @sel send what the editor has to a command", function(t)
	local dir = t:tempdir({ ["notes.txt"] = "one\ntwo words\nthree\n" })
	greed.open(`{dir}/notes.txt`)
	local file_view = greed.view()
	file_view:set_selection({ ranges = { { anchor = 4, head = 13 } }, primary = 1 })
	file_view:split("right")
	local sh = open(t, dir)
	assert(greed.view() ~= file_view)
	local lines = run(t, sh, "buf:notes.txt | wc -l")
	assert(string.match(lines.output, "^%s*3%s*$"), lines.output)
	local file = run(t, sh, "@file | head -1")
	assert(file.output == "one\n", file.output)
	local selected = run(t, sh, "@sel | tr a-z A-Z")
	assert(selected.output == "TWO WORDS", selected.output)
	local missing = run(t, sh, "buf:nothing-here | cat")
	assert(missing.status == "failed", missing.status)
end)

test("> buf:NAME sends a command's output to a buffer, and >> adds to it", function(t)
	local sh = open(t, t:tempdir())
	local first = run(t, sh, "printf 'a\\n' > buf:out")
	local out = assert(shell.data.buffer("out"), "a buffer made")
	assert(out:text() == "a\n", out:text())
	assert(first.into == "buf:out" and first.runner == "pipe", tostring(first.into))
	-- The output went to the buffer, so the block shows only the command.
	assert(sh.buffer:text() == "printf 'a\\n' > buf:out\n", sh.buffer:text())
	assert(string.find(status(sh, first), "> buf:out", 1, true), status(sh, first))
	run(t, sh, "sh -c 'echo b; echo oops >&2' >> buf:out")
	assert(out:text() == "a\nb\n", out:text())
	local errors = sh.blocks[2]
	assert(errors.stderr == "oops\n", errors.stderr)
	assert(string.find(sh.buffer:text(), "\noops\n", 1, true), "errors still show")
	run(t, sh, "$1 > buf:out")
	assert(out:text() == "a\n", "> empties it first: " .. out:text())
	run(t, sh, "echo c > buf:out")
	assert(out:text() == "c\n", out:text())
	-- open shows it.
	run(t, sh, "open buf:out")
	assert(greed.view():buffer() == out, "shown")
end)

test("output that's JSON is kept as a value, and says so", function(t)
	local sh = open(t, t:tempdir())
	local list = run(t, sh, "echo '[1, 2, 3]'")
	assert(type(list.value) == "table" and #list.value == 3, "an array")
	assert(string.find(status(sh, list), "JSON · 3 items", 1, true), status(sh, list))
	local object = run(t, sh, 'printf \'{"a": 1, "b": [2]}\'')
	assert(type(object.value) == "table" and object.value.a == 1, "an object")
	assert(string.find(status(sh, object), "JSON · 2 keys", 1, true), status(sh, object))
	local plain = run(t, sh, "echo '[not json'")
	assert(plain.value == nil and not string.find(status(sh, plain), "JSON", 1, true))
	local number = run(t, sh, "echo 42")
	assert(number.value == nil, "only objects and arrays")
	-- $N of a JSON block gives its value in Luau.
	local text, value = shell.data.read(sh, "$1", sh.cwd)
	assert(text == "[1, 2, 3]\n" and value and value[2] == 2)
end)

test("file:line in a block's output is a link, ] e goes to it and enter opens it", function(t)
	local dir = t:tempdir({ ["src/a.rs"] = "fn a() {}\nfn b() {}\n", ["other/x"] = "" })
	local sh = open(t, dir)
	local block = run(t, sh, "printf 'error here\\n --> src/a.rs:2:4\\n'")
	local refs = assert(block.refs)
	assert(#refs == 1 and refs[1].path == `{dir}/src/a.rs` and refs[1].line == 2, tostring(#refs))
	assert(refs[1].col == 4 and string.find(refs[1].text, "error here", 1, true), refs[1].text)
	local links = sh.buffer:decorations(`shell.ref.{block.uid}`)
	assert(#links == 1 and sh.buffer:slice(links[1].from, links[1].to) == "src/a.rs:2:4")
	-- Paths are from the folder the block ran in, after the shell moved.
	run(t, sh, "cd other")
	t:keys("esc")
	greed.view():set_cursor(0)
	t:keys("] e")
	local range = greed.view():selection().ranges[1]
	assert(sh.buffer:slice(range.anchor, range.head + 1) == "src/a.rs:2:4", "selected")
	t:keys("[ e")
	assert(string.find(table.concat(t:messages(), "\n"), "no more", 1, true) ~= nil)
	greed.view():set_cursor(range.anchor + 2)
	t:keys("enter")
	local view = greed.view()
	assert(view:buffer():path() == `{dir}/src/a.rs`, tostring(view:buffer():path()))
	local cursor = view:cursor()
	assert(view:buffer():line_of(cursor) == 1, tostring(cursor))
end)

test("$3 after a command's first word is a file holding what block 3 printed", function(t)
	local sh = open(t, t:tempdir())
	local one = run(t, sh, "printf 'a\\nb\\n'")
	local two = run(t, sh, "printf 'a\\nc\\n'")
	local diff = run(t, sh, `diff ${one.number} ${two.number}`)
	assert(diff.status == "failed" and diff.code == 1, diff.status)
	assert(string.find(diff.output, "< b", 1, true) and string.find(diff.output, "> c", 1, true))
	assert(diff.command == `diff ${one.number} ${two.number}`, "the block shows what was typed")
	local cat = run(t, sh, `cat "${one.number}"`)
	assert(string.gsub(cat.output, "\r", "") == "a\nb\n", cat.output)
	local quoted = run(t, sh, `echo '${one.number}'`)
	assert(string.find(quoted.output, `${one.number}`, 1, true), "single quotes keep it")
	local inside = run(t, sh, `echo "it's ${one.number}"`)
	assert(
		string.find(inside.output, "it's /", 1, true),
		"a ' in double quotes is a ': " .. inside.output
	)
	local json = run(t, sh, `printf '\{"a": 1\}'`)
	local named = run(t, sh, `echo ${json.number}`)
	assert(string.find(named.output, "%.json"), "JSON goes in a .json file: " .. named.output)
	local missing = run(t, sh, "cat $99")
	assert(missing.status == "failed" and string.find(missing.stderr, "no block 99", 1, true))
	-- As the first word it's still what goes in.
	local piped = run(t, sh, `${one.number} | wc -l`)
	assert(string.match(piped.output, "^%s*2%s*$"), piped.output)
	-- An agent names blocks by id, in any shell.
	local agent = finished(t, shell.run(sh, `cat ${two.uid}`, { by = "agent", runner = "pipe" }))
	assert(agent.stdout == "a\nc\n", agent.stdout)
	-- open shows it in the editor.
	run(t, sh, `open ${one.number}`)
	assert(greed.view():buffer():text() == "a\nb\n", greed.view():buffer():text())
end)
