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
local problems = require("@self/problems")
require("@self/tools")
require("@self/ide")
require("@self/claude")
require("@self/compare")
require("@self/refactor")
local web = require("@self/web")
local map = require("@self/map")
local working = require("@self/working")
local ask = require("@self/ask")
local eval = require("@self/eval")
local extend = require("@self/extend")
local context = require("@self/context")
local untrusted = require("@self/untrusted")
local memory = require("@self/memory")
local manifest = require("@self/manifest")

registry.group(
	"refactor",
	"Renaming and the language server's fixes and refactors, proposed for review"
)
registry.group(
	"map",
	"Where things are: the repo map ranked toward what the user works on, and their working set"
)
registry.group("syntax", "Tree-sitter queries over a file's syntax tree")
registry.group(
	"history",
	"How code came to be: what changed lately and who changed it, and every change behind some lines"
)
registry.group(
	"plugins",
	"Greed itself: what a command, option or API function is, and writing plugins"
)

export type Tool = registry.Tool
export type Kind = registry.Kind
export type Caller = registry.Caller
export type Content = registry.Content
export type Edit = proposals.Edit
export type FileEdits = proposals.FileEdits
export type FileChanges = proposals.FileChanges
export type WorkingEntry = working.Entry
export type EvalEntry = eval.Entry

-- Frozen, so no plugin can put its own function in place of one of these,
-- like a `propose` that says the user accepted.
return table.freeze({
	tool = registry.tool,
	tools = registry.tools,
	--- Groups of tools agents switch on when they need them (registry.luau).
	group = registry.group,
	offered = registry.offered,
	caller = registry.caller,
	--- Helpers for tools' argument schemas, like `schema.object` (registry.luau).
	schema = table.freeze(registry.schema),
	--- An MCP result for a tool to return as it is, and any tool result as
	--- text (registry.luau).
	result = registry.result,
	as_text = registry.as_text,
	error_text = registry.error_text,
	--- Whether an agent asks you before a tool runs, by its kind (registry.luau).
	asks = registry.asks,
	--- Why arguments don't fit a tool's schema, and running a tool by name
	--- as MCP does, arguments checked first (registry.luau).
	check = registry.check,
	call = registry.call,
	--- Whether a tool's caller is a shell, `greed ctl` (registry.luau).
	from_shell = registry.from_shell,
	--- Text someone else wrote, wrapped so a model reads it as information
	--- (untrusted.luau).
	untrusted = untrusted,
	propose = proposals.propose,
	propose_files = proposals.propose_files,
	propose_changes = proposals.propose_changes,
	propose_ranges = proposals.propose_ranges,
	--- What the language servers report in buffers just changed (problems.luau).
	problems_after = problems.after_edits,
	pending = proposals.pending,
	try = extend.try,
	install = extend.install,
	--- A plugin check in words for an agent, and whether it may go to the
	--- user to install (extend.luau).
	describe_check = extend.describe,
	dirs = extend.dirs,
	ask = ask.ask,
	--- Each run of an agent's code past the sandbox, oldest first (eval.luau).
	eval_log = function(): { eval.Entry }
		return table.clone(eval.log)
	end,
	--- The repo map, symbols and grep agents get (map.luau).
	map = map,
	--- The files you worked in lately (working.luau).
	working = working,
	--- Searching the web and reading pages for agents (web.luau).
	web = web,
	--- What the user has on screen, to send with prompts (context.luau).
	context = context,
	--- Standing preferences you accepted, and agents proposing them (memory.luau).
	memory = memory,
	--- What a write to a plugin.toml lets the plugin do that it couldn't,
	--- to say in the question before it (manifest.luau).
	widens = manifest.widens,
})
