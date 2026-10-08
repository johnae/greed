local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")
local shell = require("@shell")

type Shell = typeof(shell.open())
type Block = typeof(assert(shell.run(shell.open(), "true")))

local tables = shell.tables

-- Output recorded from the real programs, names changed.
local PODS = [[
NAME                     READY   STATUS             RESTARTS        AGE
api-7d9f8b6c5-2xkqz      1/1     Running            0               3d16h
api-7d9f8b6c5-9wlmn      1/1     Running            3 (3d16h ago)   5d2h
worker-5c6b7d8f9-abcde   0/1     CrashLoopBackOff   12 (45s ago)    2h
redis-0                  1/1     Running            0               12m
db-migrate-x7k2p         0/1     Completed          0               45s
]]

local DOCKER = [[
CONTAINER ID   IMAGE          COMMAND                  CREATED        STATUS                    PORTS                    NAMES
3f2a1b4c5d6e   nginx:1.25     "/docker-entrypoint.…"   2 hours ago    Up 2 hours                0.0.0.0:8080->80/tcp     web
9a8b7c6d5e4f   postgres:16    "docker-entrypoint.s…"   3 days ago     Up 3 days (healthy)       5432/tcp                 db
1c2d3e4f5a6b   redis:7        "docker-entrypoint.s…"   5 weeks ago    Exited (0) 2 weeks ago                             cache
]]

-- RSS wider than its header pushes the rest of the line along, as ps does.
local PS = [[
USER        PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root          1  0.0  0.1 167744 11408 ?        Ss   Oct06   0:03 /sbin/init splash
root          2  0.0  0.0      0     0 ?        S    Oct06   0:00 [kthreadd]
john       4242 12.5  2.3 234567 389012 pts/1    Sl+  10:15   1:23 cargo test -q --workspace
postgres    811  0.3  1.1 221344 45120 ?        Ss   Oct06   2:41 postgres: checkpointer
]]

local DF = [[
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p2  468G  289G  156G  65% /
tmpfs            16G  1.2M   16G   1% /run
/dev/nvme0n1p1  511M   61M  451M  12% /boot/efi
]]

local LS = [[
total 16
drwxr-xr-x 2 john users 4096 Oct  8 12:00 src
-rw-r--r-- 1 john users 1234 Oct  7 09:30 Cargo.toml
-rw-r--r-- 1 john users  220 Sep 30  2025 my notes.txt
]]

local function columns(tbl: shell.Table?): string
	return if tbl then table.concat(tbl.columns, ",") else "no table"
end

-- A column's cells, top to bottom, in the rows given (all by default).
local function cells(tbl: shell.Table, column: string, rows: { number }?): string
	local out: { string } = {}
	for _, i in rows or tables.all(tbl) do
		table.insert(out, tbl.rows[i][column])
	end
	return table.concat(out, ",")
end

test("kubectl's, docker's and ps's columns are read as tables", function()
	local pods = assert(tables.detect(PODS, "kubectl get pods"))
	assert(columns(pods) == "NAME,READY,STATUS,RESTARTS,AGE", columns(pods))
	assert(#pods.rows == 5 and pods.first == 1 and pods.header)
	assert(pods.rows[2].RESTARTS == "3 (3d16h ago)", pods.rows[2].RESTARTS)
	assert(pods.rows[3].STATUS == "CrashLoopBackOff" and pods.rows[3].AGE == "2h")
	-- Capitals are enough, whatever printed it.
	assert(tables.detect(PODS, "cat pods.txt"), "from cat")
	-- A warning kubectl printed first comes before the table.
	local warned =
		assert(tables.detect("Warning: v1 Thing is deprecated\n" .. PODS, "kubectl get pods"))
	assert(warned.first == 2 and #warned.rows == 5, tostring(warned.first))

	local docker = assert(tables.detect(DOCKER, "docker ps -a"))
	assert(
		columns(docker) == "CONTAINER ID,IMAGE,COMMAND,CREATED,STATUS,PORTS,NAMES",
		columns(docker)
	)
	local cache = docker.rows[3]
	assert(cache.STATUS == "Exited (0) 2 weeks ago" and cache.PORTS == "", cache.STATUS)
	assert(docker.rows[1].COMMAND == '"/docker-entrypoint.…"', docker.rows[1].COMMAND)
	assert(docker.rows[1].CREATED == "2 hours ago" and docker.rows[1].NAMES == "web")

	local ps = assert(tables.detect(PS, "ps aux"))
	assert(columns(ps) == "USER,PID,%CPU,%MEM,VSZ,RSS,TTY,STAT,START,TIME,COMMAND", columns(ps))
	local john = ps.rows[3]
	assert(john.RSS == "389012" and john.TTY == "pts/1", `{john.RSS}|{john.TTY}`)
	assert(john.TIME == "1:23" and john.COMMAND == "cargo test -q --workspace", john.COMMAND)
	assert(ps.rows[1].COMMAND == "/sbin/init splash", ps.rows[1].COMMAND)
	assert(ps.rows[4].COMMAND == "postgres: checkpointer", ps.rows[4].COMMAND)
end)

test("df's header isn't in capitals, so only df's output is read as a table", function()
	local df = assert(tables.detect(DF, "df -h"))
	assert(columns(df) == "Filesystem,Size,Used,Avail,Use%,Mounted on", columns(df))
	assert(df.rows[3]["Mounted on"] == "/boot/efi" and df.rows[2].Size == "16G")
	assert(tables.detect(DF, "cat df.txt") == nil, "mixed case from elsewhere")
end)

test("ls -l's lines are a table without a header", function()
	local ls = assert(tables.detect(LS, "ls -l"))
	assert(columns(ls) == "MODE,LINKS,OWNER,GROUP,SIZE,MODIFIED,NAME", columns(ls))
	assert(ls.first == 2 and ls.header == false, tostring(ls.first))
	assert(ls.rows[3].NAME == "my notes.txt" and ls.rows[3].MODIFIED == "Sep 30 2025")
	assert(
		cells(ls, "NAME", tables.sorted(ls, tables.all(ls), "SIZE"))
			== "my notes.txt,Cargo.toml,src"
	)
	assert(tables.detect("Cargo.toml  README.md  src\n", "ls") == nil)
end)

test("prose and other output aren't tables", function()
	local texts = {
		"error[E0308]: mismatched types\n --> src/main.rs:12:5\n",
		"NOTE  THIS IS LOUD\nbut this is a sentence that goes on for a while\n",
		"WARNING  DEPRECATED\nok\n",
		"SUMMARY\nall good here\n",
		"USAGE  greed [OPTIONS]\n  -h  print help\n",
		"On branch main\nYour branch is up to date with 'origin/main'.\n",
		"A  B\n",
		"",
	}
	for _, text in texts do
		assert(tables.detect(text, "cat notes") == nil, text)
	end
	-- `ls` prints names in columns, some of them in capitals.
	assert(tables.detect("LICENSE    README    TODO\nCargo.toml  src     tests\n", "ls") == nil)
end)

test("a JSON array of objects is a table", function()
	local value = greed.json.decode('[{"n": 2, "name": "b", "ok": true}, {"name": "a", "n": 10.5}]')
	local tbl = assert(tables.from_value(value))
	assert(columns(tbl) == "name,n,ok", columns(tbl))
	assert(tbl.rows[1].n == "2" and tbl.rows[2].n == "10.5" and tbl.rows[2].ok == "", tbl.rows[2].n)
	assert(tables.from_value((greed.json.decode("[1, 2]"))) == nil)
	assert(tables.from_value((greed.json.decode('{"a": 1}'))) == nil)
	assert(tables.from_value((greed.json.decode("[]"))) == nil)
end)

test("numbers read with sizes, percentages and ages", function()
	assert(tables.number("512Mi") == 512 * 1024 * 1024)
	assert(tables.number("1.5G") == 1.5e9)
	assert(tables.number("250m") == 0.25)
	assert(tables.number("12m", true) == 720, "minutes in an AGE column")
	assert(tables.number("65%") == 65)
	assert(tables.number("3 (3d16h ago)") == 3)
	assert(tables.number("3d16h") == 3 * 86400 + 16 * 3600)
	assert(tables.number("45s") == 45)
	assert(tables.number("1/1") == nil and tables.number("Running") == nil)
	assert(tables.number("0.0.0.0:80") == nil)
end)

test("rows sort by numbers, ages and restarts, and filter by text or a column", function()
	local pods = assert(tables.detect(PODS, "kubectl get pods"))
	local by_age = tables.sorted(pods, tables.all(pods), "AGE")
	assert(cells(pods, "AGE", by_age) == "45s,12m,2h,3d16h,5d2h", cells(pods, "AGE", by_age))
	local restarts = tables.sorted(pods, tables.all(pods), "RESTARTS", true)
	assert(
		cells(pods, "RESTARTS", restarts) == "12 (45s ago),3 (3d16h ago),0,0,0",
		cells(pods, "RESTARTS", restarts)
	)
	-- Equal rows keep their order.
	assert(
		cells(pods, "NAME", restarts)
			== "worker-5c6b7d8f9-abcde,api-7d9f8b6c5-9wlmn,api-7d9f8b6c5-2xkqz,redis-0,db-migrate-x7k2p"
	)
	local function names(filter: string): string
		return cells(pods, "NAME", tables.filter(pods, filter))
	end
	assert(names("redis") == "redis-0")
	assert(names("STATUS=running") == "api-7d9f8b6c5-2xkqz,api-7d9f8b6c5-9wlmn,redis-0")
	assert(names("status~loop") == "worker-5c6b7d8f9-abcde")
	assert(names("STATUS=Running api") == "api-7d9f8b6c5-2xkqz,api-7d9f8b6c5-9wlmn")
	assert(names("restarts>0") == "api-7d9f8b6c5-9wlmn,worker-5c6b7d8f9-abcde")
	assert(names("AGE<1h") == "redis-0,db-migrate-x7k2p", names("AGE<1h"))
	assert(names("nothing-like-it") == "")
	assert(#tables.filter(pods, "") == 5)
end)

local function open(t: test.TestContext, dir: string): Shell
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = dir
	return sh
end

local function run(t: test.TestContext, sh: Shell, line: string): Block
	local block = assert(shell.run(sh, line, { view = greed.view() }), line)
	t:wait_for(function()
		return block.status ~= "running"
	end)
	return block
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

-- What `block` shows of its output.
local function shown(sh: Shell, block: Block): string
	local from, to = shell.log.output_range(sh, block)
	return if from and to then sh.buffer:slice(from, to + 1) else ""
end

test("a block keeps the table it printed, and where, select and sort make new ones", function(t)
	local dir = t:tempdir({ ["pods.txt"] = PODS })
	local sh = open(t, dir)
	local pods = run(t, sh, "cat pods.txt")
	local tbl = assert(pods.table, "a table")
	assert(#tbl.rows == 5, tostring(#tbl.rows))
	assert(string.find(status(sh, pods), "table · 5 rows", 1, true), status(sh, pods))

	local running = run(t, sh, "$1 | where STATUS = Running")
	assert(running.status == "done", running.stderr)
	local kept = assert(running.table)
	assert(#kept.rows == 3 and columns(kept) == columns(tbl), columns(kept))
	assert(string.match(running.output, "^NAME%s+READY%s+STATUS"), running.output)

	local young = run(t, sh, "$1 | where AGE < 1h | select name,age")
	local young_table = assert(young.table)
	assert(columns(young_table) == "NAME,AGE", columns(young_table))
	assert(
		young.output == "NAME               AGE\nredis-0            12m\ndb-migrate-x7k2p   45s\n",
		young.output
	)

	local sorted = run(t, sh, "$1 | sort RESTARTS -r | select NAME")
	assert(
		cells(assert(sorted.table), "NAME")
			== "worker-5c6b7d8f9-abcde,api-7d9f8b6c5-9wlmn,api-7d9f8b6c5-2xkqz,redis-0,db-migrate-x7k2p"
	)

	-- What comes after the stages reads their text.
	local counted = run(t, sh, "$1 | where STATUS = Running | wc -l")
	assert(string.match(counted.output, "^%s*4%s*$"), counted.output)
	-- A block of a stage is a table too.
	local again = run(t, sh, `$2 | where NAME ~ 9wlmn`)
	assert(#assert(again.table).rows == 1, again.output)

	local wrong = run(t, sh, "$1 | where COLOR = red")
	assert(wrong.status == "failed", wrong.status)
	assert(string.find(wrong.stderr, "no column COLOR", 1, true), wrong.stderr)
	-- sort without a column is the sort program, and where needs a table.
	local plain = run(t, sh, "printf 'b\\na\\n'")
	local sort = run(t, sh, `${plain.number} | sort`)
	assert(sort.output == "a\nb\n", sort.output)
	local not_table = run(t, sh, `${plain.number} | where A = b`)
	assert(string.find(not_table.stderr, "isn't one", 1, true), not_table.stderr)
end)

test("/ filters a table's rows in its block, esc shows them all again", function(t)
	local dir = t:tempdir({ ["pods.txt"] = PODS })
	local sh = open(t, dir)
	local pods = run(t, sh, "cat pods.txt")
	local original = shown(sh, pods)
	assert(original == PODS, original)
	t:keys("esc")
	local from = assert((shell.log.output_range(sh, pods)))
	greed.view():set_cursor(from + 2)
	t:keys("/ r u n n i n g")
	assert(shown(sh, pods) == table.concat({
		"NAME                     READY   STATUS             RESTARTS        AGE",
		"api-7d9f8b6c5-2xkqz      1/1     Running            0               3d16h",
		"api-7d9f8b6c5-9wlmn      1/1     Running            3 (3d16h ago)   5d2h",
		"redis-0                  1/1     Running            0               12m",
		"",
	}, "\n"), shown(sh, pods))
	t:keys("enter")
	local view = assert(pods.shown)
	assert(view.filter == "running" and #view.rows == 3, view.filter)
	-- The record keeps every row.
	assert(#assert(pods.table).rows == 5 and pods.output == PODS)
	assert(string.find(status(sh, pods), "3 of 5 rows · / running", 1, true), status(sh, pods))
	-- A filter on a column, starting from the one there was.
	t:keys("/ backspace backspace backspace backspace backspace backspace backspace")
	t:keys("A G E < 1 h enter")
	assert(#assert(pods.shown).rows == 2, shown(sh, pods))
	assert(not string.find(shown(sh, pods), "api", 1, true))
	t:keys("/ esc")
	assert(pods.shown == nil and shown(sh, pods) == PODS, shown(sh, pods))
	assert(string.find(status(sh, pods), "table · 5 rows", 1, true), status(sh, pods))
	-- Off a table, / searches as always.
	greed.view():set_cursor(0)
	t:keys("/ r e d i s enter")
	local found_from, found_to = core.text.span(greed.view():selection().ranges[1])
	local found = sh.buffer:slice(found_from, found_to)
	assert(found == "redis", found)
end)

test("space s sorts a table by the column under the cursor, again reverses it", function(t)
	local dir = t:tempdir({ ["pods.txt"] = PODS })
	local sh = open(t, dir)
	local pods = run(t, sh, "cat pods.txt")
	t:keys("esc")
	local from = assert((shell.log.output_range(sh, pods)))
	-- On the AGE column, in a row.
	greed.view():set_cursor(sh.buffer:line_start(sh.buffer:line_of(from) + 2) + 70)
	local function ages(): string
		local out: { string } = {}
		for line in string.gmatch(shown(sh, pods), "[^\n]+") do
			table.insert(out, string.match(line, "(%S+)$") or "")
		end
		return table.concat(out, ",")
	end
	t:keys("space s")
	assert(ages() == "AGE,45s,12m,2h,3d16h,5d2h", ages())
	assert(string.find(status(sh, pods), "by AGE ↑", 1, true), status(sh, pods))
	-- The cursor stays on the column, so again reverses it.
	t:keys("space s")
	assert(ages() == "AGE,5d2h,3d16h,2h,12m,45s", ages())
	t:keys("space s")
	assert(shown(sh, pods) == PODS and pods.shown == nil, ages())
	-- A sort keeps the filter, and space S shows it as it came.
	t:keys("space s / r u n enter")
	assert(ages() == "AGE,12m,3d16h,5d2h", ages())
	t:keys("space S")
	assert(shown(sh, pods) == PODS, shown(sh, pods))
	-- The row under the cursor, for plugins acting on rows.
	local line = sh.buffer:line_start(sh.buffer:line_of(from) + 3)
	assert(shell.rows.row_at(sh, pods, line) == 3)
	assert(shell.rows.row_at(sh, pods, from) == nil, "the header")
end)

test("a JSON array's table filters as aligned columns, and comes back as JSON", function(t)
	local sh = open(t, t:tempdir())
	local block = run(t, sh, [[echo '[{"name": "b", "size": 10}, {"name": "a", "size": 9}]']])
	assert(columns(block.table) == "name,size", columns(block.table))
	local json = shown(sh, block)
	t:keys("esc")
	local from = assert((shell.log.output_range(sh, block)))
	greed.view():set_cursor(from)
	t:keys("/ a enter")
	assert(shown(sh, block) == "name   size\na      9\n", shown(sh, block))
	-- The drawn columns sort too.
	greed.view():set_cursor(from + 8)
	t:keys("space s")
	assert(assert(block.shown).sort == "size")
	t:keys("space S")
	assert(shown(sh, block) == json, shown(sh, block))
end)

test("/ filters any block's lines as they're typed, esc shows them all again", function(t)
	local sh = open(t, t:tempdir())
	local block = run(t, sh, "printf 'apple pie\\nbanana\\nerror: one\\nwarning\\nerror: two\\n'")
	assert(block.table == nil, "text")
	local all = shown(sh, block)
	t:keys("esc")
	greed.view():set_cursor(assert((shell.log.output_range(sh, block))))
	t:keys("/ e r r")
	assert(shown(sh, block) == "error: one\nerror: two\n", shown(sh, block))
	t:keys("enter")
	assert(string.find(status(sh, block), "2 of 5 lines · / err", 1, true), status(sh, block))
	-- The record keeps every line, and copying gives them all.
	assert(block.output == all, block.output)
	-- Words all have to be there, in any case.
	shell.rows.set(sh, block, "ERROR two")
	assert(shown(sh, block) == "error: two\n", shown(sh, block))
	-- A regex after /; one that isn't one yet leaves it as it was.
	shell.rows.set(sh, block, "/^(apple|ban)")
	assert(shown(sh, block) == "apple pie\nbanana\n", shown(sh, block))
	shell.rows.set(sh, block, "/(")
	assert(shown(sh, block) == "apple pie\nbanana\n", shown(sh, block))
	-- Nothing left, and the block can still be filtered from its command.
	shell.rows.set(sh, block, "nothing-like-it")
	assert(shown(sh, block) == "" and assert(block.shown).total == 5)
	greed.view():set_cursor(assert((shell.log.range(block))))
	t:keys("/ esc")
	assert(shown(sh, block) == all and block.shown == nil, shown(sh, block))
end)

test("columns, from csv, from tsv, from json, split and lines make tables of text", function(t)
	local sh = open(t, t:tempdir())
	local spaced = run(t, sh, "printf 'name  size\\nfoo   10\\nbar   200\\n'")
	assert(spaced.table == nil, "lowercase isn't found on its own")
	local by_size = run(t, sh, `${spaced.number} | columns | sort size -r | select name`)
	assert(by_size.output == "name\nbar\nfoo\n", by_size.output)
	local headless = run(t, sh, `${spaced.number} | columns -H | select 2`)
	assert(headless.output == "2\nsize\n10\n200\n", headless.output)

	local csv = run(t, sh, [[printf 'name,age\n"Smith, J",42\nann,7\n']])
	local old = run(t, sh, `${csv.number} | from csv | where age > 10`)
	local old_table = assert(old.table, old.stderr)
	assert(#old_table.rows == 1 and old_table.rows[1].name == "Smith, J", old.output)

	-- A terminal turns tabs into spaces, so tab separated values come
	-- through a pipe.
	local tsv = assert(shell.run(sh, [[printf 'a\tb\n1\t2\n']], { runner = "pipe" }))
	t:wait_for(function()
		return tsv.status ~= "running"
	end)
	local b = run(t, sh, `${tsv.number} | from tsv | select b`)
	assert(b.output == "b\n2\n", b.output)

	local logs = run(t, sh, [[printf '{"level":"error","msg":"x"}\n{"level":"info","msg":"y"}\n']])
	assert(logs.value == nil, "JSON lines aren't one value")
	local errors = run(t, sh, `${logs.number} | from json | where level = error | select msg`)
	assert(errors.output == "msg\nx\n", errors.output)

	local passwd = run(
		t,
		sh,
		[[printf 'root:x:0:0:root:/root:/bin/bash\njohn:x:1000:100::/home/john:/bin/zsh\n']]
	)
	local zsh = run(t, sh, `${passwd.number} | split : | where 7 ~ zsh | select 1`)
	assert(zsh.output == "1\njohn\n", zsh.output)

	local fruit = run(t, sh, `${spaced.number} | lines | where line ~ ba`)
	assert(fruit.output == "line\nbar   200\n", fruit.output)

	local text = run(t, sh, `${spaced.number} | where size > 1`)
	assert(string.find(text.stderr, "columns", 1, true), text.stderr)
	assert(tables.pipeline(nil, "x", "split -l 10") == nil, "the split program")
	local bad = run(t, sh, `${spaced.number} | from json`)
	assert(bad.status == "failed" and string.find(bad.stderr, "isn't JSON", 1, true), bad.stderr)
end)

test("a plugin's parser reads its command's output first", function(t)
	local sh = open(t, t:tempdir())
	shell.parser("^echo parsed", function(text: string)
		return { { word = string.match(text, "(%S+)%s*$") or "", count = "1" } }
	end)
	shell.parser("printf", function()
		return nil
	end)
	local parsed = run(t, sh, "echo parsed things")
	local tbl = assert(parsed.table, "a table")
	assert(columns(tbl) == "count,word" and tbl.rows[1].word == "things", columns(tbl))
	-- A parser saying nothing leaves it to the shell.
	local pods = run(t, sh, `printf '{PODS:gsub("\n", "\\n")}'`)
	assert(pods.table and #pods.table.rows == 5, pods.output)
	assert(run(t, sh, "echo other").table == nil)
end)

-- A folder with `jc` and `uptime` programs that print what the real ones
-- would, on PATH in front of the shell's.
local function fake_jc(t: test.TestContext, sh: Shell)
	local dir = t:tempdir({
		["bin/jc"] = table.concat({
			"#!/bin/sh",
			'if [ "$1" = -a ]; then',
			[[  echo '{"parsers": [{"name": "uptime", "argument": "--uptime", "magic_commands": ["uptime"]}]}']],
			"  exit 0",
			"fi",
			'[ "$1" = --uptime ] || exit 1',
			"cat >/dev/null",
			[[echo '{"time": "10:00:00", "uptime": "3 days", "users": 2}']],
		}, "\n"),
		["bin/uptime"] = "#!/bin/sh\necho ' 10:00:00 up 3 days,  2 users,  load average: 0.10, 0.20, 0.30'\n",
	})
	run(t, sh, `chmod +x {dir}/bin/jc {dir}/bin/uptime`)
	local path = run(t, sh, [[printf %s "$PATH"]]).output
	sh.env.PATH = `{dir}/bin:{path}`
end

test("jc, when it's installed, reads the commands it knows", function(t)
	local sh = open(t, t:tempdir())
	fake_jc(t, sh)
	local up = run(t, sh, "uptime")
	t:wait_for(function()
		return up.table ~= nil
	end)
	local tbl = assert(up.table)
	assert(columns(tbl) == "time,uptime,users" and tbl.rows[1].users == "2", columns(tbl))
	assert(string.find(status(sh, up), "table · 1 row", 1, true), status(sh, up))
	-- Not a command it knows.
	local other = run(t, sh, "echo hi")
	t:wait(100)
	assert(other.table == nil)
end)

test("the real jc reads a command's output, when it's installed", function(t)
	local sh = open(t, t:tempdir())
	local path = run(t, sh, [[printf %s "$PATH"]]).output
	if shell.jc.find("jc", path) == nil then
		-- Skipped: jc isn't installed here.
		return
	end
	local tbl = shell.jc.parse(
		"Filesystem 1K-blocks Used Available Use% Mounted on\n/dev/sda1 100 50 50 50% /\n",
		"df",
		path
	)
	assert(tbl and #tbl.rows == 1, "jc read df")
end)
