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
--   space h i   inspect what's under the cursor, or the editor: an
--               object's state, what it relates to and what it can do
--
-- Agents get the same through the `describe` tool, from `text`.

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")
local api = require("@self/api")
local inspect = require("@self/inspect")

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
	--- For a live object, the object, which shows in the inspector.
	object: core.Object?,
}

local KINDS: { string } =
	{ "command", "option", "event", "api", "plugin", "mode", "style", "object" }

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

-- The objects of the running editor: everything that can be listed, and
-- the editor itself, where the inspector starts.
local function objects(): { Entry }
	local out: { Entry } = {}
	local listed = core.objects.list()
	table.insert(listed, 1, assert(core.objects.get("editor:")))
	for _, object in listed do
		table.insert(out, {
			kind = "object",
			name = object.id,
			doc = object.label,
			lines = function()
				return inspect.text(object)
			end,
			object = object,
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
	object = objects,
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
	-- A type is found by its name alone too, and as the list of names
	-- containing one writes it ("api type ThemeEntry").
	local wanted = string.gsub(name, "^api ", "")
	for _, entry in M.entries(kind) do
		if entry.name == wanted or entry.name == "type " .. wanted then
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
	if #found > 0 then
		return table.concat(found, "\n\n")
	end
	-- A plugin's module, like picker.pick: its code is the doc there is.
	local plugin, rest = string.match(name, "^([%w_%-]+)[%.:]([%w_]+)$")
	local dir = if plugin and plugin ~= "greed" then greed.plugin.dirs()[plugin] else nil
	if dir == nil then
		return nil
	end
	return `{plugin} is a plugin; what require("@{plugin}") gives, {rest} with it, is in `
		.. `{dir}/init.luau and the files it requires. Read them, or grep {dir} for {rest}.`
end

-- The help window: where what it describes is defined, or for an object in
-- the inspector, the object, what its lines lead to, the objects
-- inspected before it, to go back to, and those gone back from, to go
-- forward to again.
type Open = {
	view: greed.View,
	path: string?,
	line: number?,
	object: core.Object?,
	links: { [number]: inspect.Link }?,
	back: { core.Object },
	forward: { core.Object },
}

local open: Open? = nil

local function close()
	if open then
		open.view:close()
		open = nil
	end
end

--- Shows `object` in the inspector: its state, the objects it relates to
--- (enter goes to one, backspace or ctrl-o comes back, ctrl-i goes forward
--- again) and its actions (enter runs one). `back` is the objects inspected
--- before, newest last, and `forward` those gone back from, nearest last.
function M.inspect(object: core.Object, back: { core.Object }?, forward: { core.Object }?)
	close()
	local lines, links = inspect.page(object)
	table.insert(lines, "")
	table.insert(
		lines,
		"enter: inspect or run   ctrl-o ctrl-i: back, forward   r: again   esc: close"
	)
	local buffer = greed.create_buffer("help", table.concat(lines, "\n"))
	open = {
		view = greed.float(buffer, {
			title = "Inspect",
			width = "70%",
			height = math.min(#lines + 2, 30),
		}),
		object = object,
		links = links,
		back = back or {},
		forward = forward or {},
	}
end

--- Shows `entry` in the help window.
function M.show(entry: Entry)
	if entry.object then
		M.inspect(entry.object)
		return
	end
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
		back = {},
		forward = {},
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
	local what = if kind == "api"
		then "a function or type of the plugin API"
		elseif string.find(kind, "^[aeiou]") then "an " .. kind
		else "a " .. kind
	greed.command({
		name = `describe-{kind}`,
		doc = `Describe {what}`,
		run = function()
			pick(`Describe {if kind == "api" then "the API" else kind}`, kind)
		end,
	})
end

-- `entry`, a command `keys` runs, with where they're bound and what that
-- hides at the top: `bound` from `greed.keymap.describe`.
local function with_hidden(
	entry: Entry,
	keys: string,
	bound: { { layer: string, command: string, plugin: string } }
): Entry
	local first = bound[1]
	if first == nil then
		return entry
	end
	local top = { `{keys} in {first.layer}, from the {first.plugin} plugin` }
	for i = 2, #bound do
		local under = bound[i]
		table.insert(top, `  over {under.command} in {under.layer}, from the {under.plugin} plugin`)
	end
	table.insert(top, "")
	local shown = table.clone(entry)
	shown.lines = function()
		local lines = table.clone(top)
		local rest = entry.lines()
		table.move(rest, 1, #rest, #lines + 1, lines)
		return lines
	end
	return shown
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
				local bound = greed.keymap.describe(keys)
				for _, entry in commands() do
					if entry.name == name then
						M.show(with_hidden(entry, keys, bound))
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
	doc = "Open the file what's described is defined in, at its definition; in the inspector, "
		.. "inspect the object on this line or run its action",
	run = function(ctx)
		local o = open
		if o == nil then
			return
		end
		local object = o.object
		if object then
			local link = o.links and o.links[ctx.buffer:line_of(ctx.view:cursor()) + 1]
			if link == nil then
				return
			end
			if link.object then
				local back = table.clone(o.back)
				table.insert(back, object)
				M.inspect(link.object, back)
				return
			end
			-- An action runs where you were, as if the inspector weren't
			-- there.
			close()
			core.objects.act(object, assert(link.action))
			return
		end
		if o.path == nil then
			return
		end
		close()
		core.file.open_at(o.path, (o.line or 1) - 1)
	end,
})

greed.command({
	name = "help-back",
	doc = "In the inspector, go back to the object inspected before",
	run = function()
		local o = open
		if o == nil or #o.back == 0 then
			return
		end
		local back = table.clone(o.back)
		local previous = table.remove(back) :: core.Object
		local forward = table.clone(o.forward)
		if o.object then
			table.insert(forward, o.object)
		end
		M.inspect(core.objects.get(previous.id) or previous, back, forward)
	end,
})

greed.command({
	name = "help-forward",
	doc = "In the inspector, go forward again to the object gone back from",
	run = function()
		local o = open
		local object = o and o.object
		if o == nil or object == nil or #o.forward == 0 then
			return
		end
		local forward = table.clone(o.forward)
		local ahead = table.remove(forward) :: core.Object
		local back = table.clone(o.back)
		table.insert(back, object)
		M.inspect(core.objects.get(ahead.id) or ahead, back, forward)
	end,
})

greed.command({
	name = "help-again",
	doc = "In the inspector, look at the object again, as it is now",
	run = function()
		local o = open
		local object = o and o.object
		if o and object then
			local now = core.objects.get(object.id)
			if now == nil then
				greed.echo(`{object.label} is gone`)
				return
			end
			M.inspect(now, o.back, o.forward)
		end
	end,
})

-- What was done to anything, newest first: enter opens what an action
-- made (a shell action's block) in the inspector, or else the thing.
core.actions.action({
	kind = "*",
	name = "history",
	quiet = true,
	doc = "What was done to it, by you or an agent, and when; enter opens what each made",
	run = function(target)
		local object = core.objects.from(target)
		local history = core.actions.history(if object then object.id else "")
		if object == nil or #history == 0 then
			greed.echo(`nothing done to {target.label} yet`)
			return
		end
		local items = {}
		for _, entry in history do
			local made = if entry.made then core.objects.get(entry.made) else nil
			local ago = core.time.ago((greed.now() - entry.at) // 1000)
			local what = if made then `  → {made.label}` else ""
			table.insert(items, {
				label = `{ago}  {entry.by}  {entry.action}{what}`,
				value = made or object,
			})
		end
		picker.pick(`Done to {object.label}`, items, function(item)
			M.inspect(core.objects.get(item.value.id) or item.value)
		end)
	end,
})

greed.command({
	name = "inspect",
	doc = "Inspect what's under the cursor: its state, what it relates to, what it can do; "
		.. "with nothing there, start at the editor",
	run = function(ctx)
		local here = core.objects.at(ctx.view)
		if #here == 0 then
			M.inspect(assert(core.objects.get("editor:")))
		elseif #here == 1 then
			M.inspect(here[1])
		else
			local items = {}
			for _, object in here do
				table.insert(items, { label = `{object.kind}  {object.label}`, value = object })
			end
			picker.pick("Inspect", items, function(item)
				M.inspect(item.value)
			end)
		end
	end,
})

greed.keymap.bind({ kind = "help" }, {
	esc = "help-close",
	q = "help-close",
	enter = "help-goto",
	backspace = "help-back",
	["ctrl-o"] = "help-back",
	["alt-left"] = "help-back",
	["ctrl-i"] = "help-forward",
	["alt-right"] = "help-forward",
	r = "help-again",
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
	["h i"] = "inspect",
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
