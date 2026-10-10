-- Rows with a PID column as processes, by their PID: `ps` on Linux and
-- macOS, nu's `ps`, `lsof`, `docker top`.

local state = require("./state")
local tables = require("./tables")
local kinds = require("./kinds")

type Block = state.Block

kinds.kind({
	name = "processes",
	columns = { "PID" },
	row = function(row: { [string]: string }, _captured: any, block: Block): kinds.Thing?
		local tbl = assert(block.table)
		local pid = row[tables.column(tbl, "PID") or "PID"]
		if pid == nil or not string.match(pid, "^%d+$") then
			return nil
		end
		local named = tables.column(tbl, "COMMAND")
			or tables.column(tbl, "CMD")
			or tables.column(tbl, "name")
		local command = if named then row[named] or "" else ""
		return {
			kind = "process",
			label = `{pid} {command}`,
			value = { pid = pid, command = command },
			key = pid,
		}
	end,
	called = function(): (string, string)
		return "process", "processes"
	end,
	complete = {
		kill = function(words: { string }, _shell: state.Shell): ((value: any) -> string?)?
			if string.sub(words[#words] or "", 1, 1) == "-" then
				return nil
			end
			return function(value: any): string?
				return value.pid
			end
		end,
	},
})

kinds.object_kind(
	"process",
	"A running program, by its PID, from a table that lists it",
	function(value: any): string
		return `ps -o pid,stat,%cpu,%mem,command -p {value.pid}`
	end
)

kinds.command("process", "stop", "kill {pid}", { doc = "Ask it to stop (TERM)", danger = true })
kinds.command("process", "kill", "kill -9 {pid}", { doc = "Make it stop (KILL)", danger = true })
kinds.command(
	"process",
	"interrupt",
	"kill -INT {pid}",
	{ doc = "Interrupt it, as ctrl-c would (INT)", danger = true }
)
kinds.command(
	"process",
	"hang up",
	"kill -HUP {pid}",
	{ doc = "Hang up on it (HUP): many servers read their config again", danger = true }
)
kinds.command(
	"process",
	"open files",
	"lsof -p {pid}",
	{ doc = "The files and sockets it has open" }
)
kinds.command("process", "its folder", "lsof -a -d cwd -p {pid}", { doc = "The folder it runs in" })

return {}
