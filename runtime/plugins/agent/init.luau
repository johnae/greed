-- Lets agents and scripts use the editor: `kern ctl` from a shell, and MCP
-- clients like Claude Code through `kern mcp`.
--
-- Requests come in on the session socket. registry.luau answers MCP's
-- methods (initialize, tools/list, tools/call), so the tools are the same
-- for an agent and for `kern ctl TOOL`. Add your own with
-- `require("@agent").tool { ... }`; tools.luau has the built-in ones.

local registry = require("@self/registry")

export type Tool = registry.Tool
require("@self/tools")

return registry
