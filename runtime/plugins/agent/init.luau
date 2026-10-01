-- Lets agents and scripts use the editor: `kern ctl` from a shell, and MCP
-- clients like Claude Code through `kern mcp`.
--
-- Requests come in on the session socket. registry.luau answers MCP's
-- methods (initialize, tools/list, tools/call), so the tools are the same
-- for an agent and for `kern ctl TOOL`. Add your own with
-- `require("@agent").tool { ... }`; tools.luau has the built-in ones, and
-- proposals.luau the review of edits agents propose.

local registry = require("@self/registry")
local proposals = require("@self/proposals")
require("@self/tools")
require("@self/ide")
local extend = require("@self/extend")

export type Tool = registry.Tool
export type Edit = proposals.Edit

return {
	tool = registry.tool,
	tools = registry.tools,
	propose = proposals.propose,
	pending = proposals.pending,
	try = extend.try,
	install = extend.install,
	dirs = extend.dirs,
}
