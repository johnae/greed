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

test("macOS's ps, a user name longer than its column moving a row along, is a table", function()
	local lines = {
		"USER               PID  %CPU %MEM      VSZ    RSS   TT  STAT STARTED      TIME COMMAND",
		"runner           25090 150.7  2.1 435516464 154208   ??  R<   12:04PM   5:05.86 /Users/runner/work/greed",
		"root               126   1.1  0.4 435305456  27472   ??  Ss   11:48AM   0:09.91 /usr/libexec/opendirectoryd",
		"_installcoordinationd   412   0.0  0.1 435290944   9488   ??  Ss   11:48AM   0:00.11 /usr/libexec/installcoordinationd",
		"_spotlight         501   0.0  0.0 435299184   4896   ??  S    11:49AM   0:00.02 /usr/libexec/trustd --agent",
	}
	-- A machine's worth of processes, as macOS has.
	for pid = 600, 625 do
		table.insert(
			lines,
			`root               {pid}   0.0  0.0 435299184   4896   ??  Ss   11:49AM   0:00.02 /usr/sbin/daemon{pid}`
		)
	end
	local ps = assert(tables.detect(table.concat(lines, "\n") .. "\n", "ps aux"))
	assert(columns(ps) == "USER,PID,%CPU,%MEM,VSZ,RSS,TT,STAT,STARTED,TIME,COMMAND", columns(ps))
	local moved = ps.rows[3]
	assert(moved.USER == "_installcoordinationd" and moved.PID == "412", `{moved.USER}|{moved.PID}`)
	assert(moved.COMMAND == "/usr/libexec/installcoordinationd", moved.COMMAND)
	assert(ps.rows[4].COMMAND == "/usr/libexec/trustd --agent", ps.rows[4].COMMAND)
	assert(ps.rows[1].VSZ == "435516464" and ps.rows[1].TT == "??", ps.rows[1].VSZ)
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
	-- These go about the shell as text; blocks mode has tests of its own.
	greed.option.set("shell-blocks", false)
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
	assert(shown(sh, block) == "name   size\na       9 B\n", shown(sh, block))
	-- The drawn columns sort too.
	greed.view():set_cursor(from + 8)
	t:keys("space s")
	assert(assert(block.shown).sort == "size")
	t:keys("space S")
	assert(shown(sh, block) == json, shown(sh, block))
end)

test("/ with key=value keeps JSON lines by a field, and .a.b a section of YAML", function(t)
	local log = table.concat({
		'{"level":"info","msg":"in sync","release":{"name":"vikunja"}}',
		'{"level":"error","msg":"db down","release":{"name":"linstor"}}',
		'{"level":"info","msg":"error count 0","release":{"name":"linstor"}}',
	}, "\n") .. "\n"
	local pod =
		"metadata:\n  name: api\nstatus:\n  phase: Running\n  conditions:\n  - type: Ready\nspec:\n  nodeName: n1\n"
	local sh = open(t, t:tempdir({ ["log.json"] = log, ["pod.yaml"] = pod }))
	local logs = run(t, sh, "cat log.json")
	shell.rows.set(sh, logs, "level=error")
	assert(string.find(shown(sh, logs), "db down", 1, true), shown(sh, logs))
	assert(not string.find(shown(sh, logs), "error count", 1, true), shown(sh, logs))
	shell.rows.set(sh, logs, "release.name=linstor count")
	assert(string.find(shown(sh, logs), "^[^\n]*error count 0[^\n]*\n$"), shown(sh, logs))
	local yaml = run(t, sh, "cat pod.yaml")
	shell.rows.set(sh, yaml, ".conditions")
	assert(shown(sh, yaml) == "status:\n  conditions:\n  - type: Ready\n", shown(sh, yaml))
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
	-- The status follows the table a moment later on a busy machine.
	t:wait_for(function()
		return up.table ~= nil and string.find(status(sh, up), "table · 1 row", 1, true) ~= nil
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

local LIST = [[{"apiVersion": "v1", "kind": "List", "metadata": {"labels": {"app": "api"}},
"items": [{"name": "api-1", "phase": "Running", "restarts": 0},
{"name": "worker-2", "phase": "Failed", "restarts": 4}]}]]

test("a JSON object works with the stages, and get picks a field", function(t)
	local dir = t:tempdir({ ["list.json"] = LIST, ["one.json"] = [[{"name": "api", "port": 80}]] })
	local sh = open(t, dir)
	local one = run(t, sh, "cat one.json")
	assert(one.table == nil and type(one.value) == "table", "an object, not a table")
	-- select on an object's own fields.
	local name = run(t, sh, `${one.number} | select name`)
	assert(name.status == "done", name.stderr)
	assert(name.output == "name\napi\n", name.output)
	local port = run(t, sh, `${one.number} | where port > 10 | select port`)
	assert(port.output == "port\n  80\n", port.output)
	-- Columns of the array one field holds, like kubectl's items.
	local list = run(t, sh, "cat list.json")
	local failed = run(t, sh, `${list.number} | where phase = Failed | select name`)
	assert(failed.status == "done", failed.stderr)
	assert(failed.output == "name\nworker-2\n", failed.output)
	local kind = run(t, sh, `${list.number} | select kind`)
	assert(kind.output == "kind\nList\n", kind.output)
	local sorted = run(t, sh, `${list.number} | sort restarts -r | select name`)
	assert(sorted.output == "name\nworker-2\napi-1\n", sorted.output)
	-- get: a field, an array's item from 0, a field of each item.
	local items = run(t, sh, `${list.number} | get items`)
	assert(columns(items.table) == "name,phase,restarts", columns(items.table))
	local first = run(t, sh, `${list.number} | get items.0.name`)
	assert(first.output == "api-1\n", first.output)
	local labels = run(t, sh, `${list.number} | get metadata.labels`)
	assert(labels.output == '{"app":"api"}\n', labels.output)
	assert(type(labels.value) == "table" and labels.value.app == "api", "JSON again")
	local names = run(t, sh, `${list.number} | get items.name`)
	assert(names.output == '["api-1","worker-2"]\n', names.output)
	local counted = run(t, sh, `${list.number} | get items.0.name | wc -c`)
	assert(string.match(counted.output, "^%s*6%s*$"), counted.output)
	local missing = run(t, sh, `${list.number} | get items.5`)
	assert(missing.status == "failed", missing.status)
	assert(string.find(missing.stderr, "items has 2 items, from 0", 1, true), missing.stderr)
	local wrong = run(t, sh, `${list.number} | get spec`)
	assert(
		string.find(wrong.stderr, "has no spec; it has apiVersion, items", 1, true),
		wrong.stderr
	)
	-- Text isn't JSON.
	local text = run(t, sh, "echo hello")
	local no = run(t, sh, `${text.number} | get a`)
	assert(string.find(no.stderr, "get works on JSON", 1, true), no.stderr)
end)

test("a stage on text says why it can't run, after a program too", function(t)
	local sh = open(t, t:tempdir())
	local text = run(t, sh, "printf 'b 1\\na 2\\n'")
	local n = text.number
	local where = run(t, sh, `${n} | where A = b`)
	assert(where.status == "failed", where.status)
	assert(
		string.find(where.stderr, "columns, from csv/tsv/json, split or lines make one", 1, true),
		where.stderr
	)
	-- sort is the sort program on text; select after it is the shell's,
	-- on what sort printed, which isn't a table either.
	local mixed = run(t, sh, `${n} | sort | select A`)
	assert(mixed.status == "failed", mixed.status)
	assert(string.find(mixed.stderr, "select works on a table", 1, true), mixed.stderr)
	-- A program that fails without printing ends the line there.
	local failed = run(t, sh, `${n} | sort /nowhere | select A`)
	assert(failed.status == "failed", failed.status)
	assert(
		not string.find(failed.stderr, "select", 1, true),
		"it stopped at sort: " .. failed.stderr
	)
	assert(string.find(failed.stderr, "nowhere", 1, true), failed.stderr)
	-- lines makes one.
	local lines = run(t, sh, `${n} | lines | where line ~ a`)
	assert(lines.output == "line\na 2\n", lines.output)
end)

test("a dotted column reaches inside JSON objects, as kubectl's items are", function(t)
	local list: { [string]: any } = {
		kind = "List",
		metadata = { resourceVersion = "" },
		-- Items of different shapes, as kubectl's are.
		items = {
			{ metadata = { name = "api" }, status = { phase = "Running", podIP = "10.0.0.1" } },
			{ metadata = { name = "job" }, status = { phase = "Succeeded" } },
		} :: { any },
	}
	local pods = greed.json.encode(list)
	local sh = open(t, t:tempdir({ ["pods.json"] = pods }))
	local first = run(t, sh, "cat pods.json")
	local running = run(
		t,
		sh,
		`${first.number} | where status.phase = Running | select metadata.name status.podIP`
	)
	assert(running.status == "done", running.stderr)
	local tbl = assert(running.table, running.output)
	assert(#tbl.rows == 1 and tbl.rows[1]["metadata.name"] == "api", running.output)
	assert(tbl.rows[1]["status.podIP"] == "10.0.0.1", running.output)
	local missing = run(t, sh, `${first.number} | where status.nothing = x`)
	assert(missing.status ~= "done", "no such column")
	-- A field by its own name says where it is.
	local leaf = run(t, sh, `${first.number} | where phase = Running`)
	local said = tostring(leaf.stderr) .. leaf.output
	assert(string.find(said, "it's status.phase", 1, true), said)
end)

test("stages after a program read what it prints as a table", function(t)
	local sh = open(t, t:tempdir())
	local table_line = "printf 'NAME   AGE\\nann    3\\nbob    5\\ncid    9\\n'"
	local old = run(t, sh, `{table_line} | where AGE > 4 | select NAME`)
	assert(old.status == "done", old.stderr)
	assert(old.output == "NAME\nbob\ncid\n", old.output)
	assert(old.table and #old.table.rows == 2, "kept as a table")
	-- Programs after the stages read their text, and stages can follow
	-- those programs again.
	local counted = run(t, sh, `{table_line} | where AGE > 4 | grep -v NAME | wc -l`)
	assert(string.match(counted.output, "^%s*2%s*$"), counted.output)
	local again = run(t, sh, `{table_line} | grep -v cid | where AGE < 4`)
	assert(
		again.table and #again.table.rows == 1 and again.table.rows[1].NAME == "ann",
		again.output
	)
	-- JSON from a program works the same.
	local json = run(t, sh, `printf '[\{"a":1\},\{"a":7\}]' | where a > 3`)
	assert(json.table and #json.table.rows == 1, json.output)
	-- From a block too, past a program.
	local first = run(t, sh, table_line)
	local through = run(t, sh, `${first.number} | grep -v ann | where AGE > 6`)
	assert(through.table and through.table.rows[1].NAME == "cid", through.output)
end)

test("esc in normal mode shows a filtered block's every line again", function(t)
	local sh = open(t, t:tempdir())
	local block = run(t, sh, "printf 'apple\\nbanana\\napricot\\n'")
	local all = shown(sh, block)
	t:keys("esc")
	greed.view():set_cursor(assert((shell.log.output_range(sh, block))))
	t:keys("/ a p enter")
	assert(shown(sh, block) == "apple\napricot\n", shown(sh, block))
	t:keys("esc")
	assert(shown(sh, block) == all and block.shown == nil, shown(sh, block))
	-- Elsewhere esc does what it did.
	t:keys("esc")
	assert(shown(sh, block) == all)
end)

-- A block that printed PODS, the table to work on.
local function pods_block(t: test.TestContext, sh: Shell): Block
	local block = run(t, sh, `printf '%s' {shell.parse.quote(PODS)}`)
	assert(block.table and #block.table.rows == 5, "a table of pods")
	return block
end

test("count, first, last, uniq, sum, group and to work on a table's rows", function(t)
	local sh = open(t, t:tempdir())
	local n = pods_block(t, sh).number
	local function rows(line: string): { { [string]: string } }
		local block = run(t, sh, `${n} | {line}`)
		assert(block.status == "done", `{line}: {block.stderr}`)
		return assert(block.table, line).rows
	end
	assert(rows("count")[1].count == "5")
	assert(#rows("first 2") == 2 and #rows("first") == 1)
	local last = rows("last 2")
	assert(last[1].NAME == "redis-0" and last[2].NAME == "db-migrate-x7k2p")
	assert(#rows("uniq STATUS") == 3)
	assert(rows("sum RESTARTS")[1].sum == "15", rows("sum RESTARTS")[1].sum)
	local grouped = rows("group STATUS")
	assert(grouped[1].STATUS == "Running" and grouped[1].count == "3", grouped[1].count)
	assert(rows("where STATUS = Running | count")[1].count == "3", "they chain")
	local csv = run(t, sh, `${n} | select NAME,RESTARTS | to csv`)
	assert(
		string.find(csv.output, "NAME,RESTARTS\napi-7d9f8b6c5-2xkqz,0\napi-", 1, true) == 1,
		csv.output
	)
	local json = run(t, sh, `${n} | first 2 | to json`)
	local list = greed.json.decode(json.output)
	assert(type(list) == "table" and #list == 2 and list[1].NAME == "api-7d9f8b6c5-2xkqz")
	-- Without a column, uniq is the program.
	local program = run(t, sh, `${n} | uniq`)
	assert(program.status == "done" and string.find(program.output, "CrashLoopBackOff", 1, true))
end)

test("filter and map run Luau on each row, in a sandbox", function(t)
	local sh = open(t, t:tempdir())
	local n = pods_block(t, sh).number
	local restarted = run(t, sh, `${n} | filter n.RESTARTS > 0 and r.STATUS ~= "Running"`)
	assert(restarted.table and #restarted.table.rows == 1, restarted.output)
	assert(restarted.table.rows[1].NAME == "worker-5c6b7d8f9-abcde")
	local mapped = run(t, sh, `${n} | map minutes = n.AGE / 60 | sort minutes | first`)
	assert(mapped.table and mapped.table.rows[1].minutes == "0.75", mapped.output)
	assert(table.find(mapped.table.columns, "minutes"), "a new column")
	local wrong = run(t, sh, `${n} | filter n.NOPE > 1`)
	assert(wrong.status == "failed" and string.find(wrong.stderr, "filter:", 1, true), wrong.stderr)
	local escape = run(t, sh, `${n} | filter require("@greed").process.run(\{ "true" \}) ~= nil`)
	assert(escape.status == "failed", "the sandbox runs no programs")
	assert(string.find(escape.stderr, "needs approval", 1, true), escape.stderr)
	assert(string.find(run(t, sh, `${n} | map x`).stderr, "map NAME = EXPR", 1, true) ~= nil)
end)

test("each runs a command for every row, with its cells quoted", function(t)
	local sh = open(t, t:tempdir())
	local n = pods_block(t, sh).number
	local each = run(t, sh, `${n} | where STATUS != Running | each echo pod \{NAME\} is \{status\}`)
	assert(each.status == "done", each.stderr)
	assert(
		each.output
			== "pod worker-5c6b7d8f9-abcde is CrashLoopBackOff\npod db-migrate-x7k2p is Completed\n",
		each.output
	)
	local odd = run(t, sh, `printf 'NAME\\na b\\n' | lines | each printf '<%s>' \{line\}`)
	assert(string.find(odd.output, "<a b>", 1, true), "one argument: " .. odd.output)
	local none = run(t, sh, `${n} | each echo hi`)
	assert(none.status == "failed" and string.find(none.stderr, "{NAME}", 1, true), none.stderr)
	-- After a program too.
	local after = run(t, sh, `printf '%s' {shell.parse.quote(PODS)} | count`)
	assert(after.table and after.table.rows[1].count == "5", after.output)
end)

test("a filter ignores case unless shell-filter-search-case says otherwise", function()
	local tables = shell.tables
	assert(tables.has("Running", "running") and tables.has("running", "Running"))
	greed.option.set("shell-filter-search-case", "default")
	assert(not tables.has("running", "Running"), "as search-case says: smart")
	greed.option.set("shell-filter-search-case", "match")
	assert(not tables.has("Running", "running"))
	greed.option.set("shell-filter-search-case", "ignore")
end)

-- nu 0.115's `ls`, drawn as a stream comes: in two parts, numbered on.
local NU_LS = [[
╭───┬───────────┬──────┬────────╮
│ # │   name    │ type │  size  │
├───┼───────────┼──────┼────────┤
│ 0 │ notes.txt │ file │    6 B │
│ 1 │ src       │ dir  │ 4.0 kB │
╰───┴───────────┴──────┴────────╯
╭───┬───────────┬──────┬────────╮
│ 2 │ todo.md   │ file │   12 B │
╰───┴───────────┴──────┴────────╯
]]

test("a nu table's rows are on the lines its row numbers start", function()
	local value = {
		{ name = "notes.txt", type = "file", size = 6 },
		{ name = "src", type = "dir", size = 4096 },
		{ name = "todo.md", type = "file", size = 12 },
	}
	local tbl = assert(tables.drawn(value, NU_LS))
	assert(tbl.rows[2].name == "src" and tbl.rows[2].size == "4096")
	assert(table.concat(assert(tbl.at), ",") == "4,5,8", table.concat(tbl.at or {}, ","))
	-- With the numbers switched off, or a basic border, still a table.
	local plain = assert(tables.drawn(value, "name  type\nnotes.txt  file\n"))
	assert(plain.at == nil and #plain.rows == 3)
	local basic = assert(tables.drawn(value, "| 0 | notes.txt |\n| 1 | src |\n| 2 | todo.md |\n"))
	assert(table.concat(assert(basic.at), ",") == "1,2,3")
	-- No borders at all, and fewer rows saved than drawn.
	local none = assert(tables.drawn({ value[1] }, "#  name\n0  notes.txt\n1  src\n"))
	assert(table.concat(assert(none.at), ",") == "2")
	assert(tables.drawn({ "not", "objects" }, "0 not\n1 objects\n") == nil)
end)

test("a table's rows stay one line each in a narrow pane, and scroll sideways", function(t)
	local sh = open(t, t:tempdir())
	local block = pods_block(t, sh)
	-- Text that isn't a table still wraps.
	run(t, sh, "echo " .. string.rep("word ", 20))
	local function screen(): { string }
		return t:draw(40, 30)
	end
	local drawn = screen()
	local rows = assert(block.table).rows
	-- Each row's screen line is followed by the next row's: the columns past
	-- the edge are cut, not wrapped onto a line of their own.
	local found = false
	for i, text in drawn do
		if string.find(text, rows[1].NAME, 1, true) then
			found = true
			assert(string.find(drawn[i + 1], rows[2].NAME, 1, true), table.concat(drawn, "\n"))
		end
	end
	assert(found, table.concat(drawn, "\n"))
	assert(string.find(table.concat(drawn, "\n"), "word word", 1, true), "the echo is there")
	-- Put on the end of a row, the view scrolls to show it.
	local _, last = shell.log.output_range(sh, block)
	local line = sh.buffer:line_of(assert(last) - 1)
	greed.view():set_cursor(sh.buffer:line_end(line) - 1)
	screen()
	assert(greed.view():side_scroll() > 0, "scrolled sideways")
end)

test(
	"after a program, sort, last, uniq, sum and split with a column or number are the stages",
	function(t)
		local sh = open(t, t:tempdir())
		local pods = `printf '%s' {shell.parse.quote(PODS)}`
		local last = run(t, sh, `{pods} | last 2`)
		assert(last.status == "done" and #assert(last.table).rows == 2, last.stderr)
		assert(assert(last.table).rows[2].NAME == "db-migrate-x7k2p", last.output)
		local sorted = run(t, sh, `{pods} | sort NAME -r | first`)
		assert(assert(sorted.table).rows[1].NAME == "worker-5c6b7d8f9-abcde", sorted.output)
		local unique = run(t, sh, `{pods} | uniq STATUS | count`)
		assert(assert(unique.table).rows[1].count == "3", unique.output)
		-- Without an argument, or with a flag, it's the program.
		local program = run(t, sh, "printf 'b\\na\\n' | sort")
		assert(program.output == "a\nb\n", program.output)
		local flagged = run(t, sh, "printf '10\\n9\\n' | sort -n")
		assert(flagged.output == "9\n10\n", flagged.output)
	end
)

test(
	"a drawn table shows sizes, dates and nested JSON as people read them, the cells kept",
	function()
		local recent = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 3 * 3600) :: string
		local tbl = assert(tables.from_value({
			{
				name = "Cargo.lock",
				size = 142647,
				modified = recent,
				tags = { "a", "b" },
				count = 7,
				note = string.rep("x", 60),
			},
			{
				name = "notes.md",
				size = 899,
				modified = "2025-01-02T03:04:05+00:00",
				tags = { "c" },
				count = 12,
				note = "",
			},
		}))
		local lines = tables.draw(tbl)
		local drawn = table.concat(lines, "\n")
		assert(
			string.find(drawn, "142.6 kB", 1, true) and string.find(drawn, "899 B", 1, true),
			drawn
		)
		assert(string.find(drawn, "3 h ago", 1, true), drawn)
		assert(string.find(drawn, "2025-01-0", 1, true), drawn)
		assert(
			string.find(drawn, "[2 items]", 1, true) and string.find(drawn, "[1 item]", 1, true),
			drawn
		)
		assert(string.find(drawn, string.rep("x", 47) .. "…", 1, true), "cut: " .. drawn)
		-- Numbers line up on the right.
		assert(string.find(lines[2], " 7", 1, true) and string.find(lines[3], "12", 1, true), drawn)
		-- The cells are what they were, for the stages.
		assert(tbl.rows[1].size == "142647" and tbl.rows[1].modified == recent)
	end
)

test("a table's header and the cells saying how things are doing are colored", function(t)
	local sh = open(t, t:tempdir())
	local block = pods_block(t, sh)
	local styled: { [string]: string } = {}
	for _, mark in sh.buffer:decorations(`shell.cells.{block.uid}`) do
		styled[sh.buffer:slice(mark.from, mark.to)] = mark.style
	end
	assert(styled.Running == "shell.table.good", "Running")
	assert(styled.CrashLoopBackOff == "shell.table.bad", "CrashLoopBackOff")
	assert(styled.Completed == "shell.table.good", "Completed")
	assert(styled["0/1"] == "shell.table.warn" and styled["1/1"] == "shell.table.good", "READY")
	assert(styled["redis-0"] == nil, "a name says nothing")
	local header = false
	for text, style in styled do
		header = header
			or (style == "shell.table.header" and string.find(text, "STATUS", 1, true) ~= nil)
	end
	assert(header, "the header")
	-- Filtered, it's colored as it shows now.
	shell.rows.set(sh, block, "STATUS=Running")
	local kept = 0
	for _, mark in sh.buffer:decorations(`shell.cells.{block.uid}`) do
		if
			mark.style == "shell.table.good"
			and sh.buffer:slice(mark.from, mark.to) == "Running"
		then
			kept += 1
		end
	end
	assert(kept == 3, tostring(kept))
end)

test("map and filter say what's wrong with a column, and fractions show to two places", function(t)
	local sh = open(t, t:tempdir())
	local n = pods_block(t, sh).number
	local text = run(t, sh, `${n} | map loud = string.upper(n.NAME)`)
	assert(text.status ~= "done", "fails")
	assert(
		string.find(
			text.stderr,
			'NAME isn\'t a number here ("api-7d9f8b6c5-2xkqz"); r.NAME is its text',
			1,
			true
		),
		text.stderr
	)
	local missing = run(t, sh, `${n} | filter r.NOPE == "x"`)
	assert(
		string.find(missing.stderr, "there's no column NOPE; there's NAME, READY", 1, true),
		missing.stderr
	)
	local loud = run(t, sh, `${n} | map loud = string.upper(r.NAME) | select loud | first`)
	assert(loud.output == "loud\nAPI-7D9F8B6C5-2XKQZ\n", loud.output)
	local thirds =
		run(t, sh, `${n} | map third = n.RESTARTS / 3 | select NAME,third | where NAME ~ worker`)
	assert(string.find(thirds.output, " 4\n", 1, true), thirds.output)
	local fraction = run(t, sh, `${n} | map third = (n.RESTARTS + 1) / 3 | select third | first 3`)
	assert(string.find(fraction.output, "0.33", 1, true), fraction.output)
	assert(string.find(fraction.output, "1.33", 1, true), fraction.output)
end)

test("a stage taking text reads its words, a first line without numbers as the header", function()
	local tables = require("@shell").tables
	local seen: any = nil
	tables.stage(
		{ name = "test-words", usage = "test-words", doc = "Keeps what it's given", text = true },
		function(tbl, _rest, ctx)
			seen = { tbl = tbl, ctx = ctx }
			return tbl, nil
		end
	)
	assert((tables.pipeline(nil, "0.5 0.4 1/20\n", "test-words")))
	assert(seen.tbl.columns[3] == "3" and seen.tbl.rows[1]["1"] == "0.5", seen.tbl.columns[1])
	local text = "NAME CPU(cores) NOTE\napi 250m a b\n"
	assert((tables.pipeline(nil, text, "test-words", nil, { block = "b" })))
	local made = seen.tbl
	assert(made.columns[2] == "CPU(cores)" and made.rows[1]["CPU(cores)"] == "250m")
	assert(made.rows[1].NOTE == "a b", "past the header, in its last column")
	assert(seen.ctx.block == "b", "it gets what it runs for")
end)
