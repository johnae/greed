-- Slash commands in a transcript's box, as Claude Code has them: a
-- message whose first word is one of Greed's chat commands, like /model or
-- /effort high, runs that command instead of going to the agent. Any other
-- /word goes to the agent as typed, for agents with commands of their own
-- (ACP's `available_commands_update`). tab after / completes from both.
--
-- Each command runs an editor command (agent-model, agent-effort, ...),
-- so the box, the keys and the command line do the same.

local greed = require("@greed")
local session = require("./session")
local native = require("./native")
local transcript = require("./transcript")

type Session = session.Session
type Item = { label: string, detail: string?, badge: string?, text: string, from: number? }

local M = {}

--- One of Greed's chat commands: `/name`, what it does, a hint for what
--- it takes, the editor command it runs (given what follows as its
--- argument), and `when` a session has it, if not always: for one that
--- hasn't, the word goes to its agent.
export type Command = {
	name: string,
	doc: string,
	hint: string?,
	command: string,
	when: ((s: Session) -> boolean)?,
}

M.COMMANDS = {
	{
		name = "effort",
		doc = "How hard the model thinks, for this session",
		hint = "none|low|medium|high|max",
		command = "agent-effort",
		when = native.drives,
	},
	{
		name = "model",
		doc = "Pick the model, or switch to the one named",
		hint = "name",
		command = "agent-model",
		when = function(s: Session): boolean
			return #s.models > 0 or native.drives(s)
		end,
	},
	{
		name = "mode",
		doc = "Pick the agent's mode, or switch to the one named",
		hint = "name",
		command = "agent-mode",
		when = function(s: Session): boolean
			return #s.modes > 0
		end,
	},
	{
		name = "thoughts",
		doc = "Show or hide what the agent thinks",
		command = "agent-toggle-thoughts",
	},
	{
		name = "compact",
		doc = "Summarise all but the last few turns, to save room",
		command = "agent-compact",
		when = native.drives,
	},
	{
		name = "fork",
		doc = "A new session that starts with everything said so far",
		command = "agent-fork",
	},
} :: { Command }

-- Whether `s` has the command `c`.
local function has(s: Session, c: Command): boolean
	return c.when == nil or c.when(s)
end

--- The chat command of Greed's that `text`, written in the box of `s`,
--- runs, and what it's given; nil when it's for the agent.
function M.find(s: Session, text: string): (Command?, string?)
	local name, rest = string.match(text, "^/(%S+)%s*(.-)%s*$")
	for _, c in M.COMMANDS do
		if c.name == name and has(s, c) then
			return c, if rest ~= "" then rest else nil
		end
	end
	return nil, nil
end

--- Runs the chat command `c` with `arg`, as `find` found them.
function M.run(c: Command, arg: string?)
	greed.run(c.command, { args = if arg then { arg } else {} })
end

--- What completes `typed`, a slash and the start of a command's name:
--- Greed's chat commands `s` has, then those its agent offers that aren't
--- one of them, each with what it does.
function M.items(s: Session, typed: string, from: number): { Item }
	local items: { Item } = {}
	local taken: { [string]: boolean } = {}
	local function add(name: string, doc: string, hint: string?, badge: string)
		if taken[name] or string.sub(`/{name}`, 1, #typed) ~= typed then
			return
		end
		taken[name] = true
		local about = if hint then `{doc} ({hint})` else doc
		table.insert(
			items,
			{ label = `/{name}`, detail = about, badge = badge, text = `/{name} `, from = from }
		)
	end
	for _, c in M.COMMANDS do
		if has(s, c) then
			add(c.name, c.doc, c.hint, "greed")
		end
	end
	local offered: { session.Command } = s.commands or {}
	for _, c in offered do
		add(c.name, c.description, c.hint, s.name)
	end
	return items
end

-- What's typed in the box of the transcript `view` shows before its
-- cursor, when it's a slash and a word, and where it starts.
local function slash_at(view: greed.View): (string?, number)
	local buffer = view:buffer()
	local start = transcript.prompt_start(buffer)
	local cursor = view:cursor()
	if start == nil or cursor < start then
		return nil, 0
	end
	local typed = buffer:slice(start, cursor)
	return if string.match(typed, "^/%S*$") then typed else nil, start
end

-- Whether the lsp plugin, whose menu completes, is loaded.
local function menu_loaded(): boolean
	return table.find(greed.plugin.list(), "lsp") ~= nil
end

--- Whether the cursor of `view` is in a slash command's name in the box,
--- where tab completes it (with the lsp plugin's menu, when it's loaded).
function M.completing(view: greed.View): boolean
	return (slash_at(view)) ~= nil and menu_loaded()
end

--- Has the box of each transcript complete slash commands, finding the
--- session of a transcript buffer with `of`. The completion menu is the
--- lsp plugin's, which can be unloaded: it's used whenever it's loaded.
function M.complete(of: (buffer: greed.Buffer) -> Session?)
	local function attach()
		local lsp = require("@lsp")
		lsp.completion.source(function(view: greed.View): { Item }?
			local s = of(view:buffer())
			if s == nil then
				return nil
			end
			local typed, from = slash_at(view)
			return if typed then M.items(s, typed, from) else nil
		end, { enter = "first" })
		lsp.completion.keys_over("agent-transcript")
	end
	if menu_loaded() then
		attach()
	end
	greed.on("plugin.loaded", function(event: greed.PluginLoaded)
		if event.name == "lsp" then
			attach()
		end
	end)
end

return M
