-- Editing styles: which mode you come back to when you're done typing or
-- picking something. Each style is a plugin (helix, the default; vim;
-- edit-mode) with its own modes, so switching between them leaves the
-- others' keys alone.
--
-- Plugins bind keys by role rather than naming a style's modes: each style
-- says which of its modes plays which role, and `{ role = "typing" }`
-- binds in every style's typing mode, styles added later too. The leader
-- (`{ layer = "leader" }`) is open in every style, and a panel binds its
-- keys for its kind of buffer alone (`{ kind = "tree" }`), so they work in
-- every style and mode. `is_typing` says whether a mode types.
--
--     :style vim
--     require("@greed").option.set("editing-style", "edit")

local greed = require("@greed")
local registry = require("./registry")

--- Which of a style's modes plays each role. Keys bound with
--- `{ role = "typing" }` work in every style's typing mode, and with
--- `{ style = "vim", role = "typing" }` in one style's.
export type Roles = {
	--- The mode for moving around and running commands, like Helix's or
	--- Vim's normal mode. A style without modes has none.
	command: string?,
	--- The mode that types what's typed, like insert.
	typing: string?,
	--- The mode where moving selects, like Helix's select or Vim's visual
	--- mode.
	selecting: string?,
}

export type Style = {
	name: string,
	doc: string,
	--- The mode the style starts in and comes back to.
	mode: string,
	--- Which mode plays each role. Left out, the typing mode is the first
	--- of `typing`, and the command mode is `mode` unless it types.
	roles: Roles?,
	--- The modes that type what's typed, like insert; the typing role's by
	--- default. A style without modes lists its own mode. Completion,
	--- signature help and markup shown as written (see `reveal`) follow
	--- these.
	typing: { string }?,
	--- What the status line calls the style's modes, e.g. { vim = "normal" }; a mode without one shows as its name.
	labels: { [string]: string }?,
	--- The keys that open the leader in the style's mode, e.g. "space" or
	--- "ctrl-space": the keys every plugin binds with `{ layer = "leader" }`.
	leader: string?,
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
	doc = "How editing works: helix, vim, edit or another style a plugin adds (see :style)",
	default = "helix",
})

-- What's in use while no style is loaded at all.
local NONE: Style = { name = "none", doc = "No editing style loaded", mode = "helix" }

-- The style in use: the option's, or Helix's if that style isn't known, or
-- any there is.
local function current(): Style
	local found = styles[greed.option.get("editing-style") :: string] or styles.helix
	if found then
		return found
	end
	for _, style in styles do
		return style
	end
	return NONE
end

local M = {}

local ROLES = { "command", "typing", "selecting" }

-- The mode that plays `role` in `roles`, if any.
local function role_mode(roles: Roles, role: string): string?
	return if role == "command"
		then roles.command
		elseif role == "typing" then roles.typing
		elseif role == "selecting" then roles.selecting
		else nil
end

-- The roles each mode of `style` plays, with what's left out filled in.
local function roles_of(style: Style): Roles
	local roles: Roles = if style.roles then table.clone(style.roles) else {}
	local typing: { string } = style.typing or {}
	roles.typing = roles.typing or typing[1]
	if
		roles.command == nil
		and roles.typing ~= style.mode
		and not table.find(typing, style.mode)
	then
		roles.command = style.mode
	end
	return roles
end

--- Adds a style. If the user already chose it, it starts now. Each of its
--- role modes gets the keys bound for that role, every style's and its
--- own (`{ role = "typing" }`, `{ style = name, role = "typing" }`), and
--- its `leader` keys open the leader. It goes when the plugin that added
--- it does, and Helix's takes over if it was in use.
function M.define(style: Style)
	style = table.clone(style)
	local roles = roles_of(style)
	style.roles = roles
	if style.typing == nil then
		style.typing = if roles.typing then { roles.typing } else {}
	end
	styles[style.name] = style
	for _, role in ROLES do
		local mode = role_mode(roles, role)
		if mode then
			greed.keymap.inherit_first(mode, { style = style.name, role = role })
			greed.keymap.inherit(mode, { role = role })
		end
	end
	if style.leader then
		greed.keymap.enter(style.mode, style.leader, "leader")
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

--- The mode that plays `role` in the style in use, if one does, e.g.
--- `core.style.mode_for("selecting")`.
function M.mode_for(role: string): string?
	return role_mode(current().roles or {}, role)
end

--- The mode the style in use types in, e.g. after `insert-mode`: its
--- typing mode, or its own for a style without modes.
function M.typing_mode(): string
	return M.mode_for("typing") or current().mode
end

--- Whether `mode` is some style's own mode, like helix or vim.
function M.is_home(mode: string): boolean
	for _, style in styles do
		if style.mode == mode then
			return true
		end
	end
	return false
end

--- The kinds of buffer that take typing; set with `typing_kind`.
M.typing_kinds = {} :: { [string]: boolean }

--- Makes buffers of `kind` take typing, in the style's typing mode, e.g.
--- `core.style.typing_kind("picker")`: a picker you come back to after a
--- float over it closes takes typing again, whatever the style.
function M.typing_kind(kind: string)
	greed.plugin.tie(registry.set(M.typing_kinds, kind, true))
end

--- The mode to be in with `view` focused: `typing_mode()` for a kind of
--- buffer that takes typing, or `home()`.
function M.home_for(view: greed.View): string
	return if M.typing_kinds[view:buffer():kind()] then M.typing_mode() else M.home()
end

--- Modes shown as another mode; set with `show_as`.
M.shown_as = {} :: { [string]: string }

--- Shows `mode` as `as`, e.g. a completion menu's mode as the typing mode
--- it came from: `core.style.show_as("completion-vim-insert", "vim-insert")`.
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

--- The role `mode` (the current one if nil, or the mode it's shown as)
--- plays in its style, e.g. "selecting" in Helix's select mode.
function M.role(mode: string?): string?
	local name = shown(mode or greed.mode.get())
	for _, style in styles do
		for _, role in ROLES do
			if role_mode(style.roles or {}, role) == name then
				return role
			end
		end
	end
	return nil
end

--- Calls `call` with each typing mode of every style, now and as styles
--- are added, each mode once, until the plugin that asked goes. Keys bind
--- with `{ role = "typing" }`; this is for modes of your own made from
--- each typing mode, like the completion menu's:
---
---     core.style.each_typing(function(mode)
---         greed.keymap.inherit(`completion-{mode}`, mode)
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

-- Whether a command called `name` is there.
local function has_command(name: string): boolean
	for _, command in greed.commands() do
		if command.name == name then
			return true
		end
	end
	return false
end

greed.command({
	name = "style",
	doc = "Switch editing style, or pick one",
	args = { { name = "style", doc = "The style", complete = "editing-style" } },
	run = function(ctx)
		local name = ctx.args[1]
		if name then
			M.set(name)
			greed.echo(`editing style: {name}`)
		elseif has_command("pick-style") then
			greed.run("pick-style")
		else
			greed.echo(`editing style: {current().name} (there's {table.concat(M.names(), ", ")})`)
		end
	end,
})

return M
