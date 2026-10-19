-- The commands the shell reads with sikt programs, from what they print.

local test = require("@greed/test")
local shell = require("@shell")

-- Checks that `command`'s `output` is read as a table whose `column` holds
-- `want` (its cells joined with commas, "-" for none), and with `columns`.
local function expect(
	command: string,
	output: string,
	column: string,
	want: string,
	columns: string?
)
	local tbl = shell.tables.parse(output, command)
	assert(tbl, `{command}: no table`)
	local cells: { string } = {}
	for _, row in tbl.rows do
		table.insert(cells, row[column] or "-")
	end
	local got = table.concat(cells, ",")
	assert(got == want, `{command}: {got}`)
	if columns then
		local named = table.concat(tbl.columns, ",")
		assert(named == columns, `{command}: {named}`)
	end
end

test("free, ss, ip, mount and uptime are read as tables", function()
	expect(
		"free -h",
		"               total        used        free      shared  buff/cache   available\nMem:           125Gi        54Gi       2.1Gi       1.4Gi        71Gi        70Gi\nSwap:          126Gi        40Gi        85Gi\n",
		"used",
		"54Gi,40Gi",
		"kind,total,used,free,shared,cache,available"
	)
	expect(
		"ss -tuln",
		"Netid State  Recv-Q Send-Q Local Address:Port  Peer Address:Port\ntcp   LISTEN 0      4096   100.98.203.12:443        0.0.0.0:*\nudp   UNCONN 0      0      0.0.0.0:5353   0.0.0.0:*\n",
		"local",
		"100.98.203.12:443,0.0.0.0:5353"
	)
	expect(
		"ip -br addr",
		"lo               UNKNOWN        127.0.0.1/8 ::1/128 \nwlan0            UP             192.168.20.118/24 \n",
		"addresses",
		"127.0.0.1/8 ::1/128,192.168.20.118/24"
	)
	expect(
		"ip -brief link",
		"lo               UNKNOWN        00:00:00:00:00:00 <LOOPBACK,UP> \n",
		"flags",
		"LOOPBACK,UP"
	)
	expect(
		"mount",
		"tmpfs on / type tmpfs (rw,relatime)\n/dev/disk3s1 on /System (apfs, sealed, local)\n",
		"type",
		"tmpfs,apfs"
	)
	expect(
		"uptime",
		" 00:58:50 up 9 days,  8:19,  1 user,  load average: 9.69, 6.73, 8.39\n",
		"load5",
		"6.73"
	)
	-- macOS's says "load averages", without commas.
	expect("uptime", "10:01  up 2 days, 3 users, load averages: 1.20 1.31 1.40\n", "users", "3")
end)

test("ping, test runs, who and the environment are read as tables", function()
	expect(
		"ping -c 2 1.1.1.1",
		"PING 1.1.1.1 (1.1.1.1) 56(84) bytes of data.\n64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=12.3 ms\n64 bytes from 1.1.1.1: icmp_seq=2 ttl=57 time=11.9 ms\n",
		"ms",
		"12.3,11.9"
	)
	expect(
		"cargo test -q",
		"running 2 tests\ntest a::b ... ok\ntest c ... FAILED\n\ntest result: FAILED. 1 passed; 1 failed\n",
		"result",
		"ok,FAILED"
	)
	expect(
		"go test -v ./...",
		"=== RUN   TestA\n--- PASS: TestA (0.00s)\n    --- FAIL: TestA/sub (0.01s)\nPASS\n",
		"name",
		"TestA,TestA/sub"
	)
	expect(
		"who",
		"john     tty1         2026-10-19 08:00\njohn     pts/0        2026-10-19 09:12 (100.1.2.3)\n",
		"from",
		"-,100.1.2.3"
	)
	expect("env", "HOME=/home/x\nPATH=/a:/b\n", "name", "HOME,PATH")
	-- `env` running a command shows the command's output, read as its own.
	assert(shell.tables.parse("HOME=/home/x\n", "env A=1 cat notes") == nil, "the command's own")
end)
