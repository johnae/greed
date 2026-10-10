-- `ps`'s rows as processes, by their PID.

local state = require("./state")
local tables = require("./tables")
local kinds = require("./kinds")

type Block = state.Block

kinds.kind({
	name = "processes",
	match = "ps",
	capture = function(block: Block): any
		local tbl = block.table
		return if tbl and tables.column(tbl, "PID") then true else nil
	end,
	row = function(row: { [string]: string }, _captured: any, block: Block): kinds.Thing?
		local tbl = assert(block.table)
		local pid = row[tables.column(tbl, "PID") or "PID"]
		if pid == nil or not string.match(pid, "^%d+$") then
			return nil
		end
		local command = row.COMMAND or row.CMD or ""
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

kinds.object_kind("process", "A running program, by its PID, from a table that lists it")

kinds.command("process", "stop", "kill {pid}", { doc = "Ask it to stop (TERM)", danger = true })
kinds.command("process", "kill", "kill -9 {pid}", { doc = "Make it stop (KILL)", danger = true })
kinds.command(
	"process",
	"open files",
	"lsof -p {pid}",
	{ doc = "The files and sockets it has open" }
)

return {}
