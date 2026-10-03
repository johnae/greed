-- Editing styles: which mode you come back to when you're done typing or
-- picking something. Helix's style (this plugin) comes back to "normal";
-- edit mode and Vim are styles of their own, each with its own modes, so
-- switching between them leaves the others' keys alone.
--
--     :style vim
--     require("@greed").option.set("editing-style", "edit")

local greed = require("@greed")

export type Style = {
	name: string,
	doc: string,
	--- The mode the style starts in and comes back to.
	mode: string,
	--- What the status line calls the style's modes, e.g. { vim = "normal" }.
	labels: { [string]: string }?,
	--- The plugin it comes from; unloading that plugin removes the style.
	plugin: string?,
}

local styles: { [string]: Style } = {}

greed.option.define({
	name = "editing-style",
	doc = "How editing works: helix, edit or vim (see :style)",
	default = "helix",
})

-- The style in use: the option's, or Helix's if that style isn't known.
local function current(): Style
	return styles[greed.option.get("editing-style") :: string] or styles.helix
end

local M = {}

--- Adds a style. If the user already chose it, it starts now.
function M.define(style: Style)
	styles[style.name] = style
	if greed.option.get("editing-style") == style.name then
		greed.mode.set(style.mode)
	end
end

--- The styles, sorted by name.
function M.list(): { Style }
	local list = {}
	for _, style in styles do
		table.insert(list, style)
	end
	table.sort(list, function(a: Style, b: Style)
		return a.name < b.name
	end)
	return list
end

--- The style in use.
M.current = current

--- The mode to come back to, e.g. when leaving insert mode.
function M.home(): string
	return current().mode
end

--- Whether `mode` is some style's own mode, like normal or vim.
function M.is_home(mode: string): boolean
	for _, style in styles do
		if style.mode == mode then
			return true
		end
	end
	return false
end

--- The mode buffers of a kind are used in, when it isn't the style's own,
--- e.g. `core.style.kind_modes.picker = "insert"`: a picker you come back
--- to after a float over it closes takes typing again.
M.kind_modes = {} :: { [string]: string }

--- The mode to be in with `view` focused: its buffer kind's, or `home()`.
function M.home_for(view: greed.View): string
	return M.kind_modes[view:buffer():kind()] or M.home()
end

--- Modes shown as another mode, e.g. a completion menu's mode as the
--- typing mode it came from: `core.style.shown_as["completion-insert"] = "insert"`.
M.shown_as = {} :: { [string]: string }

--- What the status line shows for `mode`.
function M.label(mode: string): string
	if M.shown_as[mode] then
		return M.label(M.shown_as[mode])
	end
	for _, style in styles do
		local label = style.labels and style.labels[mode]
		if label then
			return label
		end
	end
	return mode
end

--- Switches to style `name`.
function M.set(name: string)
	if styles[name] == nil then
		error(`no editing style called {name}; there's {table.concat(M.names(), ", ")}`, 0)
	end
	greed.option.set("editing-style", name)
end

function M.names(): { string }
	local names = {}
	for _, style in M.list() do
		table.insert(names, style.name)
	end
	return names
end

greed.on("option.changed", function(event)
	if event.name ~= "editing-style" then
		return
	end
	if styles[event.value :: string] == nil then
		greed.echo(`no editing style called {event.value}; using {current().name}`)
	end
	greed.history.end_group()
	greed.mode.set(M.home())
end)

-- A style goes with its plugin, and Helix's takes over if it was in use.
greed.on("plugin.unloaded", function(event)
	local using = current()
	for name, style in styles do
		if style.plugin == event.name then
			styles[name] = nil
		end
	end
	if current() ~= using then
		greed.mode.set(M.home())
	end
end)

greed.command({
	name = "style",
	doc = "Switch editing style: helix, edit or vim",
	args = { { name = "style", doc = "The style", complete = "editing-style" } },
	run = function(ctx)
		local name = ctx.args[1]
		if name == nil then
			greed.echo(`editing style: {current().name} (there's {table.concat(M.names(), ", ")})`)
			return
		end
		M.set(name)
		greed.echo(`editing style: {name}`)
	end,
})

M.define({
	name = "helix",
	doc = "Select, then act on the selection (Helix, Kakoune)",
	mode = "normal",
})

return M
