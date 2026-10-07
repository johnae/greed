-- Editing styles: which mode you come back to when you're done typing or
-- picking something. Helix's style (this plugin) comes back to "normal";
-- edit mode and Vim are styles of their own, each with its own modes, so
-- switching between them leaves the others' keys alone.
--
-- Plugins ask the styles rather than naming their modes: `is_typing` for
-- whether a mode types, `each_typing` to bind keys in every typing mode,
-- and keys bound for a buffer kind in normal mode work in every style.
--
--     :style vim
--     require("@greed").option.set("editing-style", "edit")

local greed = require("@greed")
local registry = require("./registry")

export type Style = {
	name: string,
	doc: string,
	--- The mode the style starts in and comes back to.
	mode: string,
	--- The modes that type what's typed, like insert. A style without
	--- modes lists its own mode. Completion, signature help and markup
	--- shown as written (see `reveal`) follow these.
	typing: { string }?,
	--- What the status line calls the style's modes, e.g. { vim = "normal" }.
	labels: { [string]: string }?,
	--- Once the plugin it came from; ignored.
	plugin: string?,
}

local styles: { [string]: Style } = {}

-- What wants to hear of each typing mode, and the modes it has heard of.
type Watcher = { call: (mode: string) -> (), heard: { [string]: boolean } }
local watchers: { Watcher } = {}

local function tell(watcher: Watcher, style: Style)
	local modes: { string } = style.typing or {}
	for _, mode in modes do
		if not watcher.heard[mode] then
			watcher.heard[mode] = true
			watcher.call(mode)
		end
	end
end

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

--- Adds a style. If the user already chose it, it starts now. Its mode
--- gets the keys bound for each buffer kind in normal mode, so panels like
--- the file tree keep theirs. It goes when the plugin that added it does,
--- and Helix's takes over if it was in use.
function M.define(style: Style)
	styles[style.name] = style
	if style.mode ~= "normal" then
		greed.keymap.inherit_kinds(style.mode, "normal")
	end
	for _, watcher in table.clone(watchers) do
		tell(watcher, style)
	end
	if greed.option.get("editing-style") == style.name then
		greed.mode.set(style.mode)
	end
	greed.plugin.tie(function()
		if styles[style.name] ~= style then
			return
		end
		local using = current()
		styles[style.name] = nil
		if current() ~= using then
			greed.mode.set(M.home())
		end
	end)
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

--- The mode buffers of each kind are used in, when it isn't the style's
--- own; set with `kind_mode`.
M.kind_modes = {} :: { [string]: string }

--- Makes buffers of `kind` used in `mode`, e.g.
--- `core.style.kind_mode("picker", "insert")`: a picker you come back to
--- after a float over it closes takes typing again.
function M.kind_mode(kind: string, mode: string)
	greed.plugin.tie(registry.set(M.kind_modes, kind, mode))
end

--- The mode to be in with `view` focused: its buffer kind's, or `home()`.
function M.home_for(view: greed.View): string
	return M.kind_modes[view:buffer():kind()] or M.home()
end

--- Modes shown as another mode; set with `show_as`.
M.shown_as = {} :: { [string]: string }

--- Shows `mode` as `as`, e.g. a completion menu's mode as the typing mode
--- it came from: `core.style.show_as("completion-insert", "insert")`.
--- Being typing or not follows `as` too.
function M.show_as(mode: string, as: string)
	greed.plugin.tie(registry.set(M.shown_as, mode, as))
end

-- The mode `mode` is shown as, following `show_as` all the way.
local function shown(mode: string): string
	local seen: { [string]: boolean } = {}
	while M.shown_as[mode] and not seen[mode] do
		seen[mode] = true
		mode = M.shown_as[mode]
	end
	return mode
end

--- What the status line shows for `mode`.
function M.label(mode: string): string
	mode = shown(mode)
	for _, style in styles do
		local label = style.labels and style.labels[mode]
		if label then
			return label
		end
	end
	return mode
end

-- The style whose typing modes have `mode`, if any.
local function typing_style(mode: string): Style?
	mode = shown(mode)
	for _, style in styles do
		if style.typing and table.find(style.typing, mode) then
			return style
		end
	end
	return nil
end

--- Whether `mode` (the current one if nil) types what's typed: a style's
--- typing mode like insert, or a mode shown as one.
function M.is_typing(mode: string?): boolean
	return typing_style(mode or greed.mode.get()) ~= nil
end

--- Calls `call` with each typing mode of every style, now and as styles
--- are added, each mode once, until the plugin that asked goes. For keys
--- that should work wherever you type:
---
---     core.style.each_typing(function(mode)
---         greed.keymap.bind(mode, { ["ctrl-space"] = "completion-ask" })
---     end)
function M.each_typing(call: (mode: string) -> ())
	local watcher: Watcher = { call = call, heard = {} }
	greed.plugin.tie(registry.put(watchers, watcher))
	for _, style in M.list() do
		tell(watcher, style)
	end
end

--- When markup a plugin hides (a link's brackets, a heading's hashes)
--- shows as written in `mode` (the current one if nil), as a mark's
--- `reveal` wants it: "line" while typing, on the cursor's line; "cursor"
--- in a style without modes, once the cursor is inside it rather than at
--- its start, where a click puts it; otherwise "never", so moving around
--- and clicking keep the looks.
function M.reveal(mode: string?): "line" | "cursor" | "never"
	local name = shown(mode or greed.mode.get())
	local style = typing_style(name)
	if style == nil then
		return "never"
	end
	return if style.mode == name then "cursor" else "line"
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
	doc = "Select text, then say what to do with it (Helix, Kakoune)",
	mode = "normal",
	typing = { "insert" },
})

return M
