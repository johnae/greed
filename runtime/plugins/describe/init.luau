-- Help: describe anything the editor is made of, to see what it does, who
-- defined it and where. In the help window, enter jumps to the definition
-- and esc (or q) closes it.
--
--   space h h   describe anything: commands, options, events, the API,
--               plugins and modes, in one picker
--   space h c   a command          space h o   an option
--   space h e   an event           space h a   a function of the API
--   space h p   a plugin           space h m   a mode and its keys
--   space h k   press a key to see what it runs
--
-- Agents get the same through the `describe` tool, from `text`.

local greed = require("@greed")
local picker = require("@picker")
local api = require("@self/api")

local M = {}

--- Something to describe: what kind it is, its name, a line about it, the
--- lines of its description, and where it's defined.
export type Entry = {
	kind: string,
	name: string,
	doc: string,
	lines: () -> { string },
	path: string?,
	line: number?,
}

local KINDS: { string } = { "command", "option", "event", "api", "plugin", "mode", "style" }

local function defined_at(source: string?, owner: string?): string
	local where = source or "?"
	return if owner then `Defined in {where} by the {owner} plugin` else `Defined in {where}`
end

local function doc_or_none(doc: string): string
	return if doc == "" then "(no description)" else doc
end

local function keys_of(command: string): { string }
	local out: { string } = {}
	for _, binding in greed.keymap.find(command) do
		table.insert(out, `Keys: {binding.keys} ({binding.layer})`)
	end
	if #out == 0 then
		table.insert(out, "Keys: none")
	end
	return out
end

local function commands(): { Entry }
	local out: { Entry } = {}
	for _, command in greed.commands() do
		table.insert(out, {
			kind = "command",
			name = command.name,
			doc = command.doc,
			path = command.path,
			line = command.line,
			lines = function()
				local lines = { doc_or_none(command.doc), "" }
				for _, arg in command.args do
					table.insert(
						lines,
						`Argument: {arg.name}{if arg.doc then "  " .. arg.doc else ""}`
					)
				end
				local keys = keys_of(command.name)
				table.move(keys, 1, #keys, #lines + 1, lines)
				table.insert(lines, defined_at(command.source, command.owner))
				return lines
			end,
		})
	end
	return out
end

local function options(): { Entry }
	local out: { Entry } = {}
	for _, option in greed.option.list() do
		table.insert(out, {
			kind = "option",
			name = option.name,
			doc = option.doc,
			path = option.path,
			line = option.line,
			lines = function()
				local lines = {
					doc_or_none(option.doc),
					"",
					`Value: {tostring(option.value)}`,
					`Default: {tostring(option.default)}`,
				}
				if #option.choices > 0 then
					local choices = {}
					for _, choice in option.choices do
						table.insert(choices, `"{tostring(choice)}"`)
					end
					table.insert(lines, `Choices: {table.concat(choices, ", ")}`)
				end
				if option.set_by then
					table.insert(lines, `Set by the {option.set_by} plugin`)
				end
				table.insert(lines, `Change it with :set {option.name} VALUE`)
				table.insert(lines, defined_at(option.source, option.owner))
				return lines
			end,
		})
	end
	return out
end

local function events(): { Entry }
	local types = api.read()
	if types == nil then
		return {}
	end
	local handlers: { [string]: { greed.HandlerInfo } } = {}
	for _, handler in greed.handlers() do
		handlers[handler.event] = handlers[handler.event] or {}
		table.insert(handlers[handler.event], handler)
	end
	local out: { Entry } = {}
	for _, event in types.events do
		local payload: { api.Entry } = types.fields[event.payload] or {}
		local fields = {}
		for _, field in payload do
			table.insert(fields, field.name)
		end
		table.insert(out, {
			kind = "event",
			name = event.name,
			doc = `{event.payload}: {table.concat(fields, ", ")}`,
			path = types.path,
			line = event.line,
			lines = function()
				local lines = { `Handlers get a {event.payload}:`, "" }
				for _, field in payload do
					table.insert(
						lines,
						`  {field.name}: {field.signature}{if field.doc ~= ""
							then "  " .. field.doc
							else ""}`
					)
				end
				table.insert(lines, "")
				table.insert(lines, `Listen with greed.on("{event.name}", function(event) ... end)`)
				local listening: { greed.HandlerInfo } = handlers[event.name] or {}
				table.insert(
					lines,
					if #listening == 0 then "Nothing listens to it now." else "Listening now:"
				)
				for _, handler in listening do
					table.insert(lines, `  the {handler.owner} plugin, at {handler.source or "?"}`)
				end
				return lines
			end,
		})
	end
	return out
end

local function functions(): { Entry }
	local types = api.read()
	if types == nil then
		return {}
	end
	local out: { Entry } = {}
	for _, entry in types.entries do
		table.insert(out, {
			kind = "api",
			name = entry.name,
			doc = entry.doc,
			path = types.path,
			line = entry.line,
			lines = function()
				return { entry.signature, "", doc_or_none(entry.doc) }
			end,
		})
	end
	return out
end

local function plugins(): { Entry }
	local dirs = greed.plugin.dirs()
	-- How many commands, options and handlers each plugin has.
	local owned_commands: { [string]: number } = {}
	local owned_options: { [string]: number } = {}
	local owned_handlers: { [string]: number } = {}
	for _, command in greed.commands() do
		owned_commands[command.owner] = (owned_commands[command.owner] or 0) + 1
	end
	for _, option in greed.option.list() do
		owned_options[option.owner] = (owned_options[option.owner] or 0) + 1
	end
	for _, handler in greed.handlers() do
		owned_handlers[handler.owner] = (owned_handlers[handler.owner] or 0) + 1
	end
	local out: { Entry } = {}
	for _, name in greed.plugin.list() do
		local dir = dirs[name]
		table.insert(out, {
			kind = "plugin",
			name = name,
			doc = dir or "",
			path = if dir then dir .. "/init.luau" else nil,
			line = if dir then 1 else nil,
			lines = function()
				local lines =
					{ if dir then `Loaded from {dir}` else "Not loaded from a folder", "" }
				if dir then
					local info = greed.plugin.describe(dir)
					if #info.requires > 0 then
						table.insert(lines, `Requires: {table.concat(info.requires, ", ")}`)
					end
					for _, capability in info.capabilities do
						table.insert(lines, `May use {capability.name}: {capability.what}`)
					end
				end
				local commands, options, handlers =
					owned_commands[name] or 0, owned_options[name] or 0, owned_handlers[name] or 0
				table.insert(
					lines,
					`Defines {commands} commands, {options} options and {handlers} event handlers`
				)
				return lines
			end,
		})
	end
	return out
end

local function modes(): { Entry }
	local layers: { [string]: { string } } = {}
	for _, binding in greed.keymap.find() do
		layers[binding.layer] = layers[binding.layer] or {}
		table.insert(layers[binding.layer], `  {binding.keys}  {binding.command}`)
	end
	local out: { Entry } = {}
	for layer, bindings in layers do
		table.sort(bindings)
		table.insert(out, {
			kind = "mode",
			name = layer,
			doc = `{#bindings} keys`,
			lines = function()
				local lines = { `The keys bound in {layer}:`, "" }
				table.move(bindings, 1, #bindings, #lines + 1, lines)
				return lines
			end,
		})
	end
	table.sort(out, function(a: Entry, b: Entry)
		return a.name < b.name
	end)
	return out
end

-- The editing styles: their modes, each with the role it plays and what the
-- status line calls it, and the keys that open the leader.
local function styles(): { Entry }
	local core = require("@core")
	local out: { Entry } = {}
	for _, style in core.style.list() do
		table.insert(out, {
			kind = "style",
			name = style.name,
			doc = style.doc,
			lines = function()
				local lines = { style.doc, "" }
				local function role(name: string, mode: string?)
					if mode then
						local label = string.upper(core.style.label(mode))
						table.insert(lines, `{name}: {mode} (shown as {label})`)
					end
				end
				local roles = style.roles
				if roles then
					role("command", roles.command)
					role("typing", roles.typing)
					role("selecting", roles.selecting)
				end
				if style.leader then
					table.insert(lines, `The leader: {style.leader}`)
				end
				table.insert(lines, "")
				table.insert(lines, `:style {style.name} switches to it.`)
				return lines
			end,
		})
	end
	return out
end

local SOURCES: { [string]: () -> { Entry } } = {
	command = commands,
	option = options,
	event = events,
	api = functions,
	plugin = plugins,
	mode = modes,
	style = styles,
}

--- Everything of `kind` ("command", "option", "event", "api", "plugin",
--- "mode" or "style"), or of every kind.
function M.entries(kind: string?): { Entry }
	local out: { Entry } = {}
	for _, name in KINDS do
		if kind == nil or kind == name then
			for _, entry in SOURCES[name]() do
				table.insert(out, entry)
			end
		end
	end
	return out
end

--- What describing `name` (of `kind`, or any) shows, as text, or nil if
--- there's nothing by that name.
function M.text(name: string, kind: string?): string?
	local found = {}
	for _, entry in M.entries(kind) do
		if entry.name == name then
			local lines = { `{entry.kind} {entry.name}`, "" }
			for _, line in entry.lines() do
				table.insert(lines, line)
			end
			if entry.path then
				table.insert(lines, `File: {entry.path}:{entry.line or 1}`)
			end
			table.insert(found, table.concat(lines, "\n"))
		end
	end
	return if #found > 0 then table.concat(found, "\n\n") else nil
end

type Open = {
	view: greed.View,
	path: string?,
	line: number?,
}

local open: Open? = nil

local function close()
	if open then
		open.view:close()
		open = nil
	end
end

--- Shows `entry` in the help window.
function M.show(entry: Entry)
	close()
	local lines = { `{entry.name}  ({entry.kind})`, "" }
	for _, line in entry.lines() do
		table.insert(lines, line)
	end
	if entry.path then
		table.insert(lines, "")
		table.insert(lines, "enter: go to the definition   esc: close")
	end
	local buffer = greed.create_buffer("help", table.concat(lines, "\n"))
	local height = math.min(#lines + 2, 30)
	open = {
		view = greed.float(buffer, { title = "Help", width = "70%", height = height }),
		path = entry.path,
		line = entry.line,
	}
end

-- A picker over `kind` (or everything), each labelled with its kind when
-- they're mixed.
local function pick(title: string, kind: string?)
	local items = {}
	for _, entry in M.entries(kind) do
		local label = if kind then entry.name else `{entry.kind}  {entry.name}`
		if entry.doc ~= "" then
			label ..= "  " .. entry.doc
		end
		table.insert(items, { label = label, value = entry })
	end
	picker.pick(title, items, function(item)
		M.show(item.value)
	end)
end

greed.command({
	name = "describe",
	doc = "Describe anything: a command, option, event, API function, plugin or mode",
	run = function()
		pick("Describe", nil)
	end,
})

for _, kind in KINDS do
	local what = if kind == "api" then "a function or type of the plugin API" else "a " .. kind
	greed.command({
		name = `describe-{kind}`,
		doc = `Describe {what}`,
		run = function()
			pick(`Describe {if kind == "api" then "the API" else kind}`, kind)
		end,
	})
end

greed.command({
	name = "describe-key",
	doc = "Press keys to see what command they run",
	run = function()
		greed.echo("press a key to describe")
		local keys = ""
		while true do
			local key = greed.next_key()
			keys = if keys == "" then key else `{keys} {key}`
			local name, pending = greed.keymap.resolve(keys)
			if name then
				for _, entry in commands() do
					if entry.name == name then
						M.show(entry)
						return
					end
				end
				greed.echo(`{keys} runs {name}, which doesn't exist`)
				return
			elseif not pending then
				greed.echo(`{keys} isn't bound to anything`)
				return
			end
		end
	end,
})

greed.command({
	name = "help-close",
	doc = "Close the help window",
	run = close,
})

greed.command({
	name = "help-goto",
	doc = "Open the file what's described is defined in, at its definition",
	run = function()
		local o = open
		if o == nil or o.path == nil then
			return
		end
		close()
		require("@core").file.open_at(o.path, (o.line or 1) - 1)
	end,
})

greed.keymap.bind({ kind = "help" }, {
	esc = "help-close",
	q = "help-close",
	enter = "help-goto",
})

greed.keymap.bind({ layer = "leader" }, {
	["h h"] = "describe",
	["h c"] = "describe-command",
	["h o"] = "describe-option",
	["h e"] = "describe-event",
	["h a"] = "describe-api",
	["h p"] = "describe-plugin",
	["h m"] = "describe-mode",
	["h k"] = "describe-key",
	["h s"] = "describe-style",
})

-- Commands, wherever they show up as things to act on (the command
-- palette's items): describe one.
require("@core").actions.action({
	kind = "command",
	name = "describe",
	doc = "What it does, its keys and where it's defined",
	run = function(target)
		for _, entry in commands() do
			if entry.name == target.value then
				M.show(entry)
				return
			end
		end
	end,
})

return M
