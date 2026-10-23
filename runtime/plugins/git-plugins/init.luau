-- Plugins from git: say which in your config, and Greed fetches them into
-- its data folder and pins each to a commit in a lock file next to your
-- config, `plugins.lock`, so another machine gets the same ones. Put the
-- lines in `init.luau` or in a file you require from it:
--
--     local plugins = require("@git-plugins")
--     plugins.use("https://github.com/someone/greed-jump")
--     plugins.use("https://github.com/someone/greed-todo", { ref = "v2", name = "todo" })
--
-- Saying so only records it: nothing is fetched while the config runs, so
-- starting never waits on the network. Missing plugins are fetched in the
-- background once the editor is up, or with `:plugins-sync`, at the commit
-- the lock file says, or the latest of `ref` for one that's new there.
-- `:plugins-update [NAME]` fetches the latest of each `ref` and writes the
-- lock file again. Taking a line out of your config and running
-- `:plugins-sync` removes that plugin (to the trash where there is one) and
-- its pin. A plugin fetched loads like any of yours: one asking
-- for capabilities waits for your approval (`:plugins-approve`), and so
-- does an update asking for more.

local greed = require("@greed")
local core = require("@core")

greed.option.define({
	name = "plugins-lock",
	doc = "The lock file pinning plugins from git to commits; empty for plugins.lock in your config's folder",
	default = "",
})

local M = {}

--- A plugin from git: where it's fetched from, which branch or tag to
--- follow (the default branch, when nil), and the name it goes by.
export type Use = { url: string, ref: string?, name: string }

-- What the config said to use, in order, by name.
local uses: { Use } = {}

--- The name a plugin fetched from `url` goes by: its last part, without
--- `.git` and a `greed-` in front.
function M.name_of(url: string): string
	local last = string.match(url, "([^/:]+)/*$") or url
	last = string.gsub(last, "%.git$", "") :: string
	last = string.gsub(last, "^greed%-", "") :: string
	return last
end

--- Says to use the plugin at `url` (anything `git clone` takes), following
--- `opts.ref` and named `opts.name`. What it returns takes that back, as a
--- config running again without the line does.
function M.use(url: string, opts: { ref: string?, name: string? }?): () -> ()
	local name = (opts and opts.name) or M.name_of(url)
	for i, known in uses do
		if known.name == name then
			table.remove(uses, i)
			break
		end
	end
	local entry = { url = url, ref = opts and opts.ref, name = name }
	table.insert(uses, entry)
	local function forget()
		local at = table.find(uses, entry)
		if at then
			table.remove(uses, at)
		end
	end
	-- Taken out again when the config that said so runs again without it.
	greed.plugin.cleanup(forget)
	return forget
end

--- The plugins said to use, in order.
function M.list(): { Use }
	return table.clone(uses)
end

--- Where fetched plugins go: the data folder's plugins, which load by
--- themselves.
function M.folder(): string?
	local data = greed.fs.dirs().data
	return if data then `{data}/plugins` else nil
end

--- The lock file.
function M.lock_file(): string?
	local set = greed.option.get("plugins-lock") :: string
	if set ~= "" then
		return set
	end
	local config = greed.fs.dirs().config
	return if config then `{config}/plugins.lock` else nil
end

--- What a lock file says, by plugin: where it came from, what it followed
--- and its commit.
export type Locked = { url: string, ref: string?, commit: string }

--- Reads the lock file's text: a line per plugin, "name url ref commit",
--- with "-" for no ref.
function M.parse_lock(text: string): { [string]: Locked }
	local out: { [string]: Locked } = {}
	for _, line in string.split(text, "\n") do
		local name, url, ref, commit = string.match(line, "^(%S+)%s+(%S+)%s+(%S+)%s+(%x+)%s*$")
		if name and url and ref and commit then
			out[name] = { url = url, ref = if ref == "-" then nil else ref, commit = commit }
		end
	end
	return out
end

-- The lock file's text for `locked`, sorted by name.
local function lock_text(locked: { [string]: Locked }): string
	local names = {}
	for name in locked do
		table.insert(names, name)
	end
	table.sort(names)
	local lines = { "# Plugins from git, pinned by :plugins-sync and :plugins-update." }
	for _, name in names do
		local l = locked[name]
		table.insert(lines, `{name} {l.url} {l.ref or "-"} {l.commit}`)
	end
	return table.concat(lines, "\n") .. "\n"
end

local function read_lock(): { [string]: Locked }
	local file = M.lock_file()
	return M.parse_lock(if file then greed.fs.read(file) or "" else "")
end

local function write_lock(locked: { [string]: Locked })
	local file = M.lock_file()
	if file == nil then
		return
	end
	local ok, err = greed.fs.write(file, lock_text(locked))
	if not ok then
		greed.echo(`plugins: can't write {file}: {err}`)
	end
end

-- Runs git with `args` in `dir`; its output, or an error saying what failed.
local function git(args: { string }, dir: string?): string
	local command = { "git" }
	table.move(args, 1, #args, 2, command)
	local ran, err = greed.process.run(command, { cwd = dir, timeout = 120000 })
	if ran == nil then
		error(`git: {err}`, 0)
	elseif ran.code ~= 0 then
		local why = string.match(ran.stderr, "[^\n]*[^\n%s][^\n]*") or `exit {ran.code}`
		error(`git {args[1]}: {why}`, 0)
	end
	return ran.stdout
end

-- The commit `dir` is at.
local function head(dir: string): string
	return (string.gsub(git({ "rev-parse", "HEAD" }, dir), "%s+$", ""))
end

-- Fetches `use` into the plugins folder if it isn't there, at `commit` (or
-- the latest of its ref); with `update`, moves one that's there to the
-- latest of its ref. Returns the commit it's at.
local function fetch(use: Use, folder: string, commit: string?, update: boolean): string
	local dir = `{folder}/{use.name}`
	if greed.fs.stat(dir) == nil then
		greed.fs.mkdir(folder)
		local args = { "clone", "--quiet" }
		if use.ref then
			table.insert(args, "--branch")
			table.insert(args, use.ref)
		end
		table.insert(args, use.url)
		table.insert(args, dir)
		git(args)
		if commit then
			git({ "checkout", "--quiet", commit }, dir)
		end
	elseif update then
		git({ "fetch", "--quiet", "--tags", "origin" }, dir)
		local target = if use.ref then `origin/{use.ref}` else "origin/HEAD"
		-- A tag has no origin/ branch: the tag itself.
		local ok = pcall(git, { "rev-parse", "--verify", "--quiet", target }, dir)
		git({ "checkout", "--quiet", if ok then target else use.ref or "origin/HEAD" }, dir)
	end
	return head(dir)
end

--- Fetches the plugins said to use that aren't here yet, at the commits the
--- lock file says; with `update`, takes every one (or the one named) to
--- the latest of its ref. Writes the lock file. Returns how many it
--- fetched or moved, and what failed.
function M.sync(update: boolean?, only: string?): (number, { string })
	local folder = M.folder()
	if folder == nil then
		return 0, { "no data folder to keep plugins in" }
	end
	local locked = read_lock()
	local done, failed = 0, {}
	for _, use in uses do
		if only and use.name ~= only then
			continue
		end
		local pin = locked[use.name]
		-- A pin for another place or ref doesn't hold.
		local commit = if pin and pin.url == use.url and pin.ref == use.ref then pin.commit else nil
		local dir = `{folder}/{use.name}`
		local before = if greed.fs.stat(dir) then head(dir) else nil
		local ok, at = pcall(fetch, use, folder, commit, update == true)
		if ok then
			if at ~= before then
				done += 1
			end
			locked[use.name] = { url = use.url, ref = use.ref, commit = at }
		else
			table.insert(failed, `{use.name}: {at}`)
		end
	end
	write_lock(locked)
	return done, failed
end

--- Removes the plugins the lock file pins that your config no longer says
--- to use, to the trash where there is one, and takes them out of the lock
--- file. Only folders that are still a checkout of where they were fetched
--- from go. Returns the names removed, and what failed.
function M.prune(): ({ string }, { string })
	local folder = M.folder()
	if folder == nil then
		return {}, {}
	end
	local wanted: { [string]: boolean } = {}
	for _, use in uses do
		wanted[use.name] = true
	end
	local locked = read_lock()
	local removed, failed = {}, {}
	for name, pin in locked do
		if wanted[name] then
			continue
		end
		local dir = `{folder}/{name}`
		if greed.fs.stat(dir) then
			local ok, origin = pcall(git, { "config", "--get", "remote.origin.url" }, dir)
			if not ok or string.gsub(origin, "%s+$", "") ~= pin.url then
				table.insert(failed, `{name}: not the checkout of {pin.url}, left as it is`)
				continue
			end
			local gone, err = pcall(core.file.remove, dir)
			if not gone then
				table.insert(failed, `{name}: {err}`)
				continue
			end
		end
		locked[name] = nil
		table.insert(removed, name)
	end
	if #removed > 0 then
		write_lock(locked)
	end
	table.sort(removed)
	return removed, failed
end

-- Says how a sync went, or `nothing` when it changed nothing.
local function report(done: number, failed: { string }, nothing: string?, removed: { string }?)
	local said = {}
	if done > 0 then
		table.insert(said, `{done} fetched`)
	end
	if removed and #removed > 0 then
		table.insert(said, `removed {table.concat(removed, ", ")}`)
	end
	table.move(failed, 1, #failed, #said + 1, said)
	if #said > 0 then
		greed.echo(`plugins: {table.concat(said, "; ")}`)
	elseif nothing then
		greed.echo(`plugins: {nothing}`)
	end
end

-- Syncs as `M.sync` does, removes what the config no longer uses (asked
-- for by hand only: a config that failed partway would otherwise lose
-- them all) and says how it went.
local function sync_and_prune(update: boolean, only: string?, nothing: string)
	local done, failed = M.sync(update, only)
	local removed: { string } = {}
	if only == nil then
		local prune_failed: { string }
		removed, prune_failed = M.prune()
		table.move(prune_failed, 1, #prune_failed, #failed + 1, failed)
	end
	report(done, failed, nothing, removed)
end

greed.command({
	name = "plugins-sync",
	doc = "Fetch the plugins your config says to use from git that aren't here yet, at the lock file's commits, and remove those it no longer uses",
	run = function()
		sync_and_prune(false, nil, "all here")
	end,
})

greed.command({
	name = "plugins-update",
	doc = "Take the plugins from git (or the one named) to the latest of what each follows, and pin that",
	args = { { name = "plugin", doc = "Its name", type = "string", optional = true } },
	run = function(ctx)
		sync_and_prune(true, ctx.values.plugin, "up to date")
	end,
})

-- Once the editor is up, what's missing is fetched in the background.
greed.on("editor.started", function()
	if #uses > 0 then
		greed.spawn(function()
			local done, failed = M.sync(false)
			report(done, failed)
		end)
	end
end)

return M
