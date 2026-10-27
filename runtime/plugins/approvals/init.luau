-- Approving plugins. A plugin that isn't one of Greed's own and declares
-- capabilities (running programs, files by path, the network, ...) waits
-- until you approve them, and again if it later asks for more.
--
--   :plugins-approve   review the waiting plugins and approve one
--   :plugins           every plugin, where it comes from and what it may use
--   :plugin-reload NAME load a plugin again from its folder

local greed = require("@greed")
local picker = require("@picker")

local M = {}

--- What the plugin described by `about` (from `greed.plugin.describe`) asks
--- for, one line per capability, with the ones not approved yet marked.
function M.lines(about: greed.PluginInfo): { string }
	if #about.capabilities == 0 then
		return { "It uses nothing beyond the editor." }
	end
	local lines = { "It asks to:" }
	for _, capability in about.capabilities do
		local new = if table.find(about.missing, capability.name) then "  (new)" else ""
		table.insert(lines, `  {capability.name}: {capability.what}{new}`)
	end
	return lines
end

-- Tells you what waits, once the editor is up.
greed.on("editor.started", function()
	local waiting = greed.plugin.pending()
	if #waiting > 0 then
		local s = if #waiting == 1 then " waits" else "s wait"
		greed.echo(`{#waiting} plugin{s} for your approval - :plugins-approve`)
	end
end)

-- Approves and loads the plugin in `dir`, which must be one waiting for
-- approval. You chose it in a picker, whose code calls this, so it
-- runs with approvals' own capabilities: only for a plugin that waits,
-- so nothing can hand it any other folder.
local function approve(dir: string): (boolean, string?)
	for _, about in greed.plugin.pending() do
		if about.dir == dir then
			local ok, err = pcall(greed.plugin.approve, dir)
			return ok, if ok then nil else tostring(err)
		end
	end
	return false, `{dir} isn't waiting for approval`
end

greed.command({
	name = "plugin-reload",
	doc = "Load a plugin again from its folder, as after changing its code",
	args = { { name = "plugin", doc = "Its name", complete = "plugin" } },
	run = function(ctx)
		local name = ctx.args[1] or ""
		local dir = greed.plugin.dirs()[name]
		if dir == nil then
			greed.echo(`no plugin called {name}`)
			return
		end
		-- A config's folder has no plugin.toml, so its name goes with it.
		local manifest = greed.fs.stat(`{dir}/plugin.toml`) ~= nil
		local ok, err = pcall(greed.plugin.load, dir, if manifest then nil else name)
		greed.echo(if ok then `reloaded {name}` else `{name}: {err}`)
	end,
})

greed.command({
	name = "plugins-approve",
	doc = "Review the plugins waiting for approval of what they use, and approve one",
	run = function()
		local waiting = greed.plugin.pending()
		if #waiting == 0 then
			greed.echo("no plugins wait for approval")
			return
		end
		local items: { picker.Item } = {}
		for _, about in waiting do
			local asks = {}
			for _, capability in about.capabilities do
				table.insert(asks, capability.name)
			end
			table.insert(items, {
				label = about.name,
				detail = table.concat(asks, ", "),
				value = about,
			})
		end
		picker.pick("Approve a plugin", items, function(item)
			local about = item.value :: greed.PluginInfo
			local ok, err = greed.vouch(approve, about.dir)
			greed.echo(if ok then `approved and loaded {about.name}` else tostring(err))
		end, {
			preview = function(item)
				local about = item.value :: greed.PluginInfo
				local lines = { about.name, about.dir, "" }
				for _, line in M.lines(about) do
					table.insert(lines, line)
				end
				if #about.requires > 0 then
					table.insert(lines, "")
					table.insert(lines, `It uses the plugins {table.concat(about.requires, ", ")}.`)
				end
				return { text = table.concat(lines, "\n") }
			end,
		})
	end,
})

-- Whether `path` is `dir` or inside it.
local function inside(path: string, dir: string?): boolean
	return dir ~= nil and (path == dir or string.sub(path, 1, #dir + 1) == dir .. "/")
end

--- Where the plugin in `dir` comes from, in words: Greed's own, your config,
--- the copy of it greed ssh brought, the data folder (plugins fetched from
--- git, and those made in the editor), or the project.
function M.origin(dir: string): string
	local dirs = greed.fs.dirs()
	local core = greed.plugin.dirs().core
	local shipped = core and string.match(core, "^(.*)/[^/]+$")
	if inside(dir, shipped) then
		return "Greed's own"
	elseif inside(dir, dirs.brought) then
		return "your config, brought by greed ssh"
	elseif inside(dir, dirs.data) and greed.fs.stat(`{dir}/.git`) then
		return "fetched from git (data folder)"
	elseif inside(dir, dirs.data) then
		return "made in the editor (data folder)"
	elseif inside(dir, dirs.config) then
		return "your config"
	elseif inside(dir, greed.project.current().root) then
		return "this project"
	end
	return "loaded from " .. dir
end

greed.command({
	name = "plugins",
	doc = "List the plugins, where each comes from and what it may use; enter opens one",
	run = function()
		local items: { picker.Item } = {}
		for _, about in greed.plugin.pending() do
			table.insert(items, {
				label = about.name,
				detail = `waiting for approval  ({M.origin(about.dir)})`,
				value = about,
			})
		end
		local dirs = greed.plugin.dirs()
		local loading = greed.profile.loading()
		for _, name in greed.plugin.list() do
			local dir = dirs[name]
			if dir then
				local about = greed.plugin.describe(dir)
				local asks = {}
				for _, capability in about.capabilities do
					table.insert(asks, capability.name)
				end
				local uses = if #asks > 0 then "  " .. table.concat(asks, ", ") else ""
				-- What it adds to starting Greed, when that's enough to notice.
				local ms = loading[name]
				local took = if ms and ms >= 1 then string.format("  loads in %.0f ms", ms) else ""
				table.insert(
					items,
					{ label = name, detail = `{M.origin(dir)}{uses}{took}`, value = about }
				)
			end
		end
		picker.pick("Plugins", items, function(item)
			local about = item.value :: greed.PluginInfo
			greed.open(about.dir .. "/init.luau")
		end, {
			preview = function(item)
				local about = item.value :: greed.PluginInfo
				local lines = { about.name, about.dir, M.origin(about.dir), "" }
				for _, line in M.lines(about) do
					table.insert(lines, line)
				end
				return { text = table.concat(lines, "\n") }
			end,
		})
	end,
})

-- Your plugins are watched: a plugin folder that appears loads, and one
-- whose files change reloads, by itself. One asking for anything you
-- haven't approved waits (the version running keeps going as it was) and
-- the review opens, so nothing gets a capability before you say so.

--- The folders whose plugins are watched: your config's and the data
--- folder's plugins. Tests point it elsewhere and call `rescan`.
function M.watched(): { string }
	local dirs = greed.fs.dirs()
	local out = {}
	for _, base in { dirs.config, dirs.data } do
		if base then
			table.insert(out, `{base}/plugins`)
		end
	end
	return out
end

-- How long a plugin's files must be still before it loads: an agent or a
-- save writes several files in a row.
local QUIET_MS = 300

-- The plugin folders found, when each last changed (on greed.now()'s
-- clock), and what each loaded plugin's files held when it loaded, by name.
local found: { [string]: boolean } = {}
local changed_at: { [string]: number } = {}
local loaded_as: { [string]: string } = {}

-- What's directly in `dir`; nothing when it can't be read.
local function entries(dir: string): { greed.DirEntry }
	local list = greed.fs.list(dir)
	return list or {}
end

-- The plugin files under `dir`, sorted.
local function files_of(dir: string, out: { string }?): { string }
	local files = out or {}
	for _, entry in entries(dir) do
		local path = `{dir}/{entry.name}`
		if entry.dir then
			files_of(path, files)
		elseif entry.name == "plugin.toml" or string.match(entry.name, "%.luau$") then
			table.insert(files, path)
		end
	end
	table.sort(files)
	return files
end

-- What the plugin files under `dir` hold, as one digest.
local function digest(dir: string): string
	local parts = {}
	for _, path in files_of(dir) do
		table.insert(parts, `{string.sub(path, #dir + 1)}={greed.hash.sha256_file(path) or ""}`)
	end
	return table.concat(parts, "\n")
end

-- Watches `dir`, its folders and the plugin files under it.
local function watch_tree(dir: string)
	greed.fs.watch(dir)
	for _, entry in entries(dir) do
		if entry.dir then
			watch_tree(`{dir}/{entry.name}`)
		end
	end
	for _, path in files_of(dir) do
		greed.fs.watch(path)
	end
end

-- The plugin folder `path` is in, if it's under a watched folder.
local function plugin_of(path: string): string?
	for _, folder in M.watched() do
		local name = string.match(path, "^" .. string.gsub(folder, "%p", "%%%0") .. "/([^/]+)")
		if name then
			return `{folder}/{name}`
		end
	end
	return nil
end

-- Loads or reloads the plugin in `dir`, or has it wait for your approval.
-- Approvals vouches for it, whoever asked for a rescan, like git-plugins
-- after fetching: it's always a folder it watches, and one asking for
-- capabilities still waits for you.
local function settle(dir: string)
	local ok, about = pcall(greed.plugin.describe, dir)
	if not ok then
		greed.echo(`{dir}: {about}`)
		return
	end
	local info = about :: greed.PluginInfo
	if loaded_as[info.name] == digest(dir) then
		-- Loaded as it is now, as installing a plugin an agent wrote does.
		return
	end
	local was = greed.plugin.dirs()[info.name] ~= nil
	if #info.missing > 0 then
		-- It goes on the waiting list; what runs now keeps running.
		pcall(greed.vouch, greed.plugin.load, dir, nil)
		local now = if was then " (it runs as it was until then)" else ""
		greed.echo(
			`{info.name} asks for {table.concat(info.missing, ", ")}: approve it to load it{now}`
		)
		greed.run("plugins-approve")
		return
	end
	local loaded, err = pcall(greed.vouch, greed.plugin.load, dir, nil)
	if loaded then
		greed.echo(if was then `reloaded {info.name}` else `loaded {info.name}`)
	else
		greed.echo(`{info.name} didn't load: {err}`)
	end
end

-- Settles `dir` once its files have been still for a moment.
local function soon(dir: string)
	local at = greed.now()
	changed_at[dir] = at
	greed.spawn(function()
		greed.sleep(QUIET_MS)
		if changed_at[dir] == at then
			settle(dir)
		end
	end)
end

-- Looks through and watches the watched folders, as `M.rescan` says.
local function rescan(load: boolean?)
	for _, folder in M.watched() do
		greed.fs.watch(folder)
		for _, entry in entries(folder) do
			local dir = `{folder}/{entry.name}`
			if entry.dir and greed.fs.stat(`{dir}/plugin.toml`) then
				watch_tree(dir)
				if not found[dir] then
					found[dir] = true
					if load then
						soon(dir)
					end
				end
			end
		end
	end
end

--- Looks through the watched folders again, watching what's there; with
--- `load`, plugin folders it hadn't seen load (or wait for approval).
--- Another plugin may ask for it, like git-plugins after fetching:
--- approvals vouches for it, since it only reads its own folders.
function M.rescan(load: boolean?)
	greed.vouch(rescan, load)
end

-- Only the watched folders' plugins: hashing every file of Greed's own at
-- each start would be most of the time starting takes.
greed.on("plugin.loaded", function(event: greed.PluginLoaded)
	if event.dir and plugin_of(event.dir) then
		loaded_as[event.name] = digest(event.dir)
	end
end)

greed.on("file.changed", function(event: greed.FileChanged)
	local dir = plugin_of(event.path)
	if dir then
		-- A new file in it is watched too.
		watch_tree(dir)
		if found[dir] then
			soon(dir)
			return
		end
	end
	M.rescan(true)
end)

-- What's there as Greed starts has loaded, or waits, already.
M.rescan(false)

return M
