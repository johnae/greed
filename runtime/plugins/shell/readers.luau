-- Commands whose output the shell reads as a table with a sikt program:
-- each line a row, the program's captures its columns. They're asked
-- before the shell's own look for a table, and after any parser a plugin
-- or your config adds for the same command.

local read = require("./table_read")

-- `NAME=value` lines.
local VARIABLES = [[line start name: (one of (letter "_") 0+ wordchar) "=" value: until text end]]

local M = {}

--- The commands read, each with its program.
M.READERS = {
	{
		match = "free",
		program = [[line start kind: 1+ letter ":" 1+ space total: size 1+ space used: size 1+ space free: size
			optional (1+ space shared: size 1+ space cache: size 1+ space available: size)]],
	},
	{
		match = "ss",
		program = [[line start optional (netid: 1+ lower 1+ space) state: 1+ one of (upper "-") 1+ space
			recv: integer 1+ space send: integer 1+ space local: 1+ none of " " 1+ space
			peer: 1+ none of " " optional (1+ space process: 1+ none of " ")]],
	},
	{
		match = "^ip %-br%a* a",
		program = [[line start name: 1+ none of " " 1+ space state: 1+ upper
			optional (1+ space addresses: until (0+ space text end))]],
	},
	{
		match = "^ip %-br%a* l",
		program = [[line start name: 1+ none of " " 1+ space state: 1+ upper 1+ space mac: 1+ none of " "
			optional (1+ space "<" flags: until ">" ">")]],
	},
	{
		-- Linux's `on / type tmpfs (rw)`, and macOS's `on / (apfs, local)`.
		match = "mount",
		program = [[line start device: until " on " " on " path: until (" type " or " (")
			(" type " type: 1+ none of " " " (" options: until ")" ")"
			or " (" type: until "," ", " options: until ")" ")")]],
	},
	{
		-- Linux's and macOS's, which says "load averages" without commas.
		match = "uptime",
		program = [[line start 0+ space time: until " " 1+ space "up " up: until ("," 1+ space 1+ digit " user")
			"," 1+ space users: integer " user" until "load average" until ": " ": "
			load1: number optional "," 1+ space load5: number optional "," 1+ space load15: number]],
	},
	{
		match = "ping",
		program = [["bytes from " host: until ": " ": icmp_seq=" seq: integer " ttl=" ttl: integer
			" time=" ms: number " ms"]],
	},
	{
		match = "^cargo test",
		program = [[line start "test " name: until " ... " " ... " result: ("ok" or "FAILED" or "ignored")]],
	},
	{
		match = "^go test",
		program = [[line start 0+ space "--- " result: ("PASS" or "FAIL" or "SKIP") ": " name: until " ("
			" (" took: duration ")"]],
	},
	{
		match = "who",
		program = [[line start user: 1+ none of " " 1+ space tty: 1+ none of " " 1+ space
			since: until (" (" or 0+ space text end) optional (" (" from: until ")" ")")]],
	},
	-- Only on their own: `env NAME=value command` prints the command's.
	{ match = "^env%s*$", program = VARIABLES },
	{ match = "^printenv%s*$", program = VARIABLES },
} :: { { match: string, program: string } }

for _, reader in M.READERS do
	read.parser(reader.match, reader.program)
end

return M
