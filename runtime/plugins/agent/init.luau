-- Lets agents and scripts use the editor: `greed ctl` from a shell, and MCP
-- clients like Claude Code through `greed mcp`.
--
-- Requests come in on the session socket. registry.luau answers MCP's
-- methods (initialize, tools/list, tools/call), so the tools are the same
-- for an agent and for `greed ctl TOOL`. Add your own with
-- `require("@agent").tool { ... }`; tools.luau has the built-in ones, and
-- proposals.luau the review of edits agents propose.

local registry = require("@self/registry")
local proposals = require("@self/proposals")
require("@self/tools")
require("@self/ide")
require("@self/claude")
require("@self/compare")
require("@self/refactor")
local map = require("@self/map")
local working = require("@self/working")
local ask = require("@self/ask")
local eval = require("@self/eval")
local extend = require("@self/extend")

export type Tool = registry.Tool
export type Edit = proposals.Edit
export type FileEdits = proposals.FileEdits
export type FileChanges = proposals.FileChanges
export type WorkingEntry = working.Entry

return {
	tool = registry.tool,
	tools = registry.tools,
	propose = proposals.propose,
	propose_files = proposals.propose_files,
	propose_changes = proposals.propose_changes,
	propose_ranges = proposals.propose_ranges,
	pending = proposals.pending,
	try = extend.try,
	install = extend.install,
	dirs = extend.dirs,
	ask = ask.ask,
	--- How Luau from agents runs: the reviewer, the log (eval.luau).
	eval = eval,
	--- The repo map, symbols and grep agents get (map.luau).
	map = map,
	--- The files you worked in lately (working.luau).
	working = working,
}
