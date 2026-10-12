-- The agents to pick from: each registered by name with the commands that
-- run it, the first one installed being used.

local greed = require("@greed")
local core = require("@core")

local M = {}

--- An agent to start: `commands` are tried in order, the first installed
--- runs, and `model` is the model to have it use, when it offers models.
--- A `native` agent is Greed's own, run in the editor; its `model` is the
--- role of the model it uses (see the models plugin). `install` is the
--- command that installs it, to tell you when it isn't.
export type Agent = {
	name: string,
	title: string?,
	commands: { { string } },
	model: string?,
	native: boolean?,
	install: string?,
}

--- Every agent registered, in the order they came.
M.list = {} :: { Agent }

--- Adds an agent to pick from, or replaces the one of the same name. It
--- goes when the plugin (or config) that added it does.
function M.register(agent: Agent)
	greed.plugin.tie(core.registry.put(M.list, agent, function(known: Agent)
		return known.name == agent.name
	end))
end

--- The command that runs `agent`: the first one installed. Greed's own
--- agent needs none.
function M.command_of(agent: Agent): { string }?
	if agent.native then
		return {}
	end
	for _, command in agent.commands do
		if greed.which(command[1]) then
			return command
		end
	end
	return nil
end

--- The agent called `name`, if one is registered.
function M.named(name: string): Agent?
	for _, known in M.list do
		if known.name == name then
			return known
		end
	end
	return nil
end

--- The agent called `name`, or the first installed one, if it's installed.
function M.installed(name: string?): Agent?
	for _, known in M.list do
		if (name == nil or known.name == name) and M.command_of(known) then
			return known
		end
	end
	return nil
end

M.register({
	name = "claude",
	title = "Claude Code",
	commands = {
		{ "claude-agent-acp" },
		{ "claude-code-acp" },
		{ "npx", "-y", "@agentclientprotocol/claude-agent-acp" },
	},
	install = "npm install -g @agentclientprotocol/claude-agent-acp",
})
M.register({
	name = "gemini",
	title = "Gemini CLI",
	commands = { { "gemini", "--experimental-acp" } },
	install = "npm install -g @google/gemini-cli",
})
M.register({
	name = "codex",
	title = "Codex",
	commands = { { "codex-acp" } },
	install = "npm install -g @zed-industries/codex-acp",
})
M.register({
	name = "opencode",
	title = "OpenCode",
	commands = { { "opencode", "acp" } },
	install = "npm install -g opencode-ai",
})
M.register({ name = "greed", title = "Greed", commands = {}, native = true })

--- Why `agent` can't start, when it isn't installed: the command it looks
--- for, and how to install it if it says.
function M.missing(agent: Agent): string
	local how = if agent.install
		then `install it with: {agent.install}`
		else `it needs {table.concat(agent.commands[1] or {}, " ")}`
	return `{agent.title or agent.name} isn't installed; {how}`
end

return M
