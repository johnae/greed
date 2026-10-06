-- Projects: `space P` lists, in one picker, the projects open here, the
-- sessions running on this machine, recent projects, and the projects your
-- sources find. enter goes to one: it switches to it if it's open or has a
-- session, and opens it in a session of its own if not. alt-enter opens it
-- in a new session even when one is running for it. A typed folder opens
-- too.
--
-- Sources are folders to look in and commands that print paths:
--
--     require("@projects").sources({
--         -- every folder one level under these
--         { dirs = { "~/Development", "~/Work" } },
--         -- deeper, but only folders that look like projects
--         { dirs = { "~/src" }, depth = 3, markers = { ".jj", ".git" } },
--         -- any command that prints one path per line
--         { command = { "zoxide", "query", "-l" } },
--     })
--
-- Sources are looked at in the background, when the editor starts and each
-- time the picker opens, and what they found last is kept, so the picker
-- opens at once.

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")

export type Source = {
	--- What the picker says it came from; the command's program, or
	--- "folders", by default.
	name: string?,
	dirs: { string }?,
	--- How many folders down to look; 1 by default.
	depth: number?,
	--- Files or folders a project has, e.g. ".git". With these, any folder
	--- down to `depth` that has one is a project, and isn't looked into.
	--- Without, every folder `depth` down is one.
	markers: { string }?,
	--- A program and its arguments that print one path per line.
	command: { string }?,
}

type Found = { path: string, from: string }

local M = {}

local sources: { Source } = {}
-- What the sources found the last time they were looked at.
local found: { Found } = {}
local looking = false

-- "~/src/greed" for a folder in the home directory, since that's how
-- people say it.
local function short(path: string): string
	local home = greed.fs.dirs().home
	if home and string.sub(path, 1, #home + 1) == home .. "/" then
		return "~" .. string.sub(path, #home + 1)
	end
	return path
end

local expand = core.project.expand

local function is_dir(path: string): boolean
	local info = greed.fs.stat(path)
	return info ~= nil and info.kind == "dir"
end

-- What the sources found, kept in the cache so the picker has it at once.
local function cache_file(): string?
	local cache = greed.fs.dirs().cache
	return if cache then `{cache}/project-sources` else nil
end

local function load_cache()
	local file = cache_file()
	local text = file and greed.fs.read(file)
	found = {}
	for _, line in string.split(text or "", "\n") do
		local from, path = string.match(line, "^([^\t]*)\t(.+)$")
		if from and path then
			table.insert(found, { path = path, from = from })
		end
	end
end

local function save_cache()
	local file = cache_file()
	if file == nil then
		return
	end
	local lines = {}
	for _, f in found do
		table.insert(lines, `{f.from}\t{f.path}`)
	end
	greed.fs.write(file, table.concat(lines, "\n") .. "\n")
end

-- The project folders under `dir`, `depth` levels down at most.
local function look_in(dir: string, depth: number, markers: { string }?, into: { string })
	local entries: { greed.DirEntry } = greed.fs.list(dir) or {}
	for _, entry in entries do
		if entry.dir and string.sub(entry.name, 1, 1) ~= "." then
			local path = `{dir}/{entry.name}`
			if markers == nil then
				if depth <= 1 then
					table.insert(into, path)
				else
					look_in(path, depth - 1, nil, into)
				end
			else
				local is_project = false
				for _, marker in markers do
					if greed.fs.stat(`{path}/{marker}`) then
						is_project = true
						break
					end
				end
				if is_project then
					table.insert(into, path)
				elseif depth > 1 then
					look_in(path, depth - 1, markers, into)
				end
			end
		end
	end
end

-- The folders one source finds, and its name. Commands wait, so this has
-- to run in a command or event handler.
local function look(source: Source): ({ string }, string)
	local paths = {}
	if source.command then
		local done, err = greed.process.run(source.command)
		if done == nil or done.code ~= 0 then
			local why = if done then string.match(done.stderr, "^[^\n]*") else err
			greed.echo(`projects: {table.concat(source.command, " ")} failed: {why}`)
		else
			for _, line in string.split(done.stdout, "\n") do
				local printed = string.match(line, "^%s*(.-)%s*$") :: string
				local path = expand(printed)
				if printed ~= "" and is_dir(path) then
					table.insert(paths, path)
				end
			end
		end
		return paths, source.name or source.command[1]
	end
	local dirs: { string } = source.dirs or {}
	for _, dir in dirs do
		look_in(expand(dir), source.depth or 1, source.markers, paths)
	end
	return paths, source.name or "folders"
end

--- Looks at every source again, and keeps what they found for the picker.
--- It waits on commands, so it runs in a command or event handler.
function M.refresh()
	if looking then
		return
	end
	looking = true
	local all: { Found } = {}
	local seen: { [string]: boolean } = {}
	for _, source in sources do
		local ok, paths, from = pcall(look, source)
		if ok then
			for _, path in paths do
				if not seen[path] then
					seen[path] = true
					table.insert(all, { path = path, from = from })
				end
			end
		end
	end
	found = all
	looking = false
	save_cache()
end

--- Sets where projects are found besides those open, running and recent.
function M.sources(list: { Source })
	sources = list
end

--- What the sources found the last time they were looked at.
function M.found(): { Found }
	return table.clone(found)
end

-- Every project the picker lists: open here, running in a session, recent,
-- then found by sources, each once.
local function items(): { picker.Item }
	local list = {}
	local listed: { [string]: boolean } = {}
	local function add(root: string?, label: string, value: any)
		if root then
			if listed[root] then
				return
			end
			listed[root] = true
		end
		table.insert(list, { label = label, value = value })
	end
	for _, p in greed.project.list() do
		local label = short(p.root) .. if p.current then "  (shown)" else ""
		add(p.root, label, { project = p.id, root = p.root })
	end
	for _, s in greed.session.list() do
		if not s.current then
			local label = `{if s.root then short(s.root) else s.name}  (session {s.name})`
			add(s.root, label, { session = s.name, root = s.root })
		end
	end
	for _, root in core.project.recent() do
		add(root, `{short(root)}  (recent)`, { path = root, root = root })
	end
	for _, f in found do
		add(f.path, `{short(f.path)}  ({f.from})`, { path = f.path, root = f.path })
	end
	return list
end

greed.command({
	name = "pick-project",
	doc = "Go to a project: one open here, a running session, a recent one or one "
		.. "your sources find; or type a folder to open",
	run = function()
		picker.pick("Projects (alt-enter: in a new session)", items(), function(item)
			if item.value.project then
				greed.project.switch(item.value.project)
			elseif item.value.session then
				greed.session.switch({ name = item.value.session })
			else
				greed.session.switch({ path = item.value.path })
			end
		end, {
			-- A typed folder lists the folders in it, to go on with tab.
			paths = {
				dirs = true,
				choose = function(path)
					greed.session.switch({ path = path })
				end,
			},
			fallback = function(query)
				local path = expand(query)
				if not is_dir(path) then
					greed.echo(`no folder at {path}`)
					return
				end
				greed.session.switch({ path = path })
			end,
			keys = {
				["alt-enter"] = function(_, current)
					local root = current and current.value.root
					if root == nil then
						greed.echo("that session doesn't say which project it's for")
						return
					end
					greed.session.switch({ path = root, new = true })
				end,
			},
		})
		-- For next time; the picker is already open with what was found
		-- before.
		M.refresh()
	end,
})

greed.keymap.bind("normal", { ["space P"] = "pick-project" })

load_cache()

greed.on("editor.started", function()
	M.refresh()
end)

return M
