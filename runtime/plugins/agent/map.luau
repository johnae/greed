-- Finding your way around a project, for agents: a repo map (the functions
-- and types that matter most, ranked by how the files refer to each other,
-- packed into a budget), and grep, files and symbols tools that see your
-- unsaved changes.
--
-- The map follows Aider's: each file is a node, a file using a name another
-- defines is an edge to it, and PageRank, biased toward your working set
-- (working.luau) and the files asked about, ranks them. A definition's
-- rank is the share of rank that comes to it through its name.

local greed = require("@greed")
local core = require("@core")
local registry = require("./registry")
local working = require("./working")
local extend = require("./extend")

local M = {}

-- Tags are kept this many seconds, unless a file is saved sooner.
local FRESH = 60

local cache: { root: string, at: number, files: { greed.FileTags } }? = nil

greed.on("buffer.saved", function()
	cache = nil
end)

local function root(): string
	return core.project.root() or greed.fs.cwd()
end

--- Where an agent's tool results too long to give it whole are kept, to
--- read on in and grep.
function M.output_dir(): string?
	local cache = greed.fs.dirs().cache
	return cache and `{cache}/agent-output`
end

-- Greed's runtime folder: its own plugins, and their types in types/.
local function runtime_dir(): string?
	local plugin_core = greed.plugin.dirs().core
	return plugin_core and string.match(plugin_core, "^(.*)/[^/]+/[^/]+$")
end

--- What each source file in the project defines and uses, kept a while.
function M.tags(): { greed.FileTags }
	local dir = root()
	local now = os.time()
	if cache and cache.root == dir and now - cache.at < FRESH then
		return cache.files
	end
	local files = greed.syntax.tags(dir)
	cache = { root = dir, at = now, files = files }
	return files
end

local relative = working.relative

-- What an open file counts for, worked on or not.
local OPEN = 0.1

--- What the map ranks toward, by path: the working set, the open files a
--- little, and `asked` (paths an agent named) as much as the file worked
--- on most.
function M.focus(asked: { string }?): { [string]: number }
	local focus = working.scores()
	local most = 1
	for _, score in focus do
		most = math.max(most, score)
	end
	for _, buffer in greed.buffers() do
		local path = buffer:path()
		if path then
			local key = relative(path)
			focus[key] = (focus[key] or 0) + OPEN
		end
	end
	local named: { string } = asked or {}
	for _, path in named do
		local key = relative(path)
		focus[key] = (focus[key] or 0) + most
	end
	return focus
end

-- Languages whose files use each other's names.
local FAMILY = { typescript = "js", tsx = "js", javascript = "js", c = "c", cpp = "c" }

-- Whether other files can use a definition: in Rust a `pub` one, in Luau
-- one that isn't `local` or an unexported type.
local function shared(language: string, signature: string): boolean
	if language == "rust" then
		return string.match(signature, "^pub[%s(]") ~= nil
	elseif language == "luau" then
		return string.match(signature, "^local%s") == nil
			and string.match(signature, "^type%s") == nil
	end
	return true
end

type Ranked = {
	path: string,
	name: string,
	kind: string,
	line: number,
	signature: string,
	rank: number,
}

type Definition = { name: string, kind: "function" | "type", line: number, signature: string }

local function ranked(path: string, d: Definition, rank: number): Ranked
	return {
		path = path,
		name = d.name,
		kind = d.kind,
		line = d.line,
		signature = d.signature,
		rank = rank,
	}
end

--- The definitions in `files`, best first, ranked toward `focus`: weights
--- by path, relative to the project.
function M.rank(files: { greed.FileTags }, focus: { [string]: number }): { Ranked }
	-- Who defines each name, by language family, counting only what other
	-- files can use.
	local definers: { [string]: { string } } = {}
	local family: { [string]: string } = {}
	for _, file in files do
		family[file.path] = FAMILY[file.language] or file.language
		local seen = {}
		for _, d in file.definitions do
			if not seen[d.name] and shared(file.language, d.signature) then
				seen[d.name] = true
				local key = family[file.path] .. ":" .. d.name
				definers[key] = definers[key] or {}
				table.insert(definers[key], file.path)
			end
		end
	end
	-- How many files mention each name: one most files mention (`len`,
	-- `path`) says little about how two of them are related.
	local mentions: { [string]: number } = {}
	for _, file in files do
		for name in file.references do
			mentions[name] = (mentions[name] or 0) + 1
		end
	end
	-- Edges: from a file to each file defining a name it uses, weighted by
	-- how often, and less for names many files define (`new`, `get`) or
	-- mention.
	local edges: { [string]: { { to: string, name: string, weight: number } } } = {}
	local out: { [string]: number } = {}
	for _, file in files do
		local list = {}
		local total = 0
		for name, count in file.references do
			local by = definers[family[file.path] .. ":" .. name]
			if by and #name > 1 then
				local weight = math.sqrt(count) * math.log(#files / mentions[name] + 1) / #by
				if string.sub(name, 1, 1) == "_" then
					weight *= 0.1
				end
				for _, to in by do
					if to ~= file.path then
						table.insert(list, { to = to, name = name, weight = weight })
						total += weight
					end
				end
			end
		end
		edges[file.path] = list
		out[file.path] = total
	end
	-- PageRank, starting from and coming back to the focus files, each as
	-- much as its weight.
	local start: { [string]: number } = {}
	local focused = 0
	for _, file in files do
		focused += focus[file.path] or 0
	end
	for _, file in files do
		start[file.path] = if focused == 0 then 1 / #files else (focus[file.path] or 0) / focused
	end
	local rank = table.clone(start)
	for _ = 1, 30 do
		local next: { [string]: number } = {}
		local lost = 0
		for _, file in files do
			next[file.path] = 0
		end
		for _, file in files do
			local r = rank[file.path]
			if out[file.path] > 0 then
				for _, edge in edges[file.path] do
					next[edge.to] += 0.85 * r * edge.weight / out[file.path]
				end
			else
				lost += 0.85 * r
			end
		end
		for path, value in next do
			next[path] = value + (0.15 + lost) * start[path]
		end
		rank = next
	end
	-- Each definition's share: the rank that comes to it through its name.
	local share: { [string]: number } = {}
	for _, file in files do
		for _, edge in edges[file.path] do
			local key = edge.to .. "\0" .. edge.name
			share[key] = (share[key] or 0) + rank[file.path] * edge.weight / out[file.path]
		end
	end
	local definitions: { Ranked } = {}
	for _, file in files do
		for _, d in file.definitions do
			-- Rust's `impl` blocks repeat the type; their methods say more.
			if not (file.language == "rust" and string.match(d.signature, "^impl[%s<]")) then
				-- Unreferenced ones still come in their file's order.
				local r = (share[file.path .. "\0" .. d.name] or 0) + rank[file.path] * 1e-3
				table.insert(definitions, ranked(file.path, d, r))
			end
		end
	end
	table.sort(definitions, function(a: Ranked, b: Ranked)
		return a.rank > b.rank
	end)
	return definitions
end

type MapOptions = { focus: { string }?, budget: number? }

--- The repo map: the best-ranked definitions' first lines, grouped by
--- file, within about `budget` tokens (a token is about 4 characters).
function M.map(opts: MapOptions?): string
	local options: MapOptions = opts or {}
	local focus = M.focus(options.focus)
	local budget = (options.budget or 2048) * 4
	local by_file: { [string]: { Ranked } } = {}
	local order: { string } = {}
	local used = 0
	for _, d in M.rank(M.tags(), focus) do
		local new_file = by_file[d.path] == nil
		local cost = #d.signature + 8
		if new_file then
			cost += #d.path + 1
		end
		if used + cost > budget then
			break
		end
		used += cost
		if new_file then
			by_file[d.path] = {}
			table.insert(order, d.path)
		end
		table.insert(by_file[d.path], d)
	end
	local lines = {}
	for _, path in order do
		table.insert(lines, path)
		local defs = by_file[path]
		table.sort(defs, function(a: Ranked, b: Ranked)
			return a.line < b.line
		end)
		for _, d in defs do
			table.insert(lines, `{string.format("%5d", d.line + 1)}  {d.signature}`)
		end
	end
	return table.concat(lines, "\n")
end

--- The definitions whose names match `query` (fuzzily), best first.
function M.symbols(query: string, limit: number?): { Ranked }
	local all: { Ranked } = {}
	local names = {}
	for _, file in M.tags() do
		for _, d in file.definitions do
			table.insert(all, ranked(file.path, d, 0))
			table.insert(names, d.name)
		end
	end
	local found = {}
	for _, i in greed.fuzzy(query, names) do
		table.insert(found, all[i])
		if #found >= (limit or 50) then
			break
		end
	end
	return found
end

type Hit = { path: string, line: number, text: string }

-- Whether `path` is `folder` or in it.
local function inside(path: string, folder: string?): boolean
	return folder ~= nil and (path == folder or string.sub(path, 1, #folder + 1) == folder .. "/")
end

-- Whether agents may search and list `dir` outside the project: Greed's
-- own plugins and types, the best examples for a plugin, tool results too
-- long to have been given whole, and your config with the plugins agents
-- write in it.
local function reachable(dir: string): boolean
	return inside(dir, runtime_dir())
		or inside(dir, M.output_dir())
		or inside(dir, greed.fs.dirs().config)
		or inside(dir, extend.dirs.plugins)
		or inside(dir, extend.dirs.fallback)
end

-- Why `dir` can't be reached, for a tool that `does` in the project.
local function out_of_reach(dir: string, does: string): string
	local runtime = runtime_dir()
	local also = if runtime
		then `, in your config, or in Greed's own plugins and types in {runtime}`
		else ""
	return `{dir} is outside the project; {does} in it{also}`
end

--- The lines matching the regex `pattern` under `dir` (relative to the
--- project; all of it by default), with open files as you have them.
function M.grep(pattern: string, dir: string?, limit: number?): ({ Hit }?, string?)
	local base = root()
	local where, prefix = base, ""
	if dir and string.sub(dir, 1, 1) == "/" then
		if inside(dir, base) then
			dir = if dir == base then nil else string.sub(dir, #base + 2)
		elseif reachable(dir) then
			where, prefix = dir, dir .. "/"
			dir = nil
		else
			return nil, out_of_reach(dir, "grep searches")
		end
	end
	if dir then
		where, prefix = `{base}/{dir}`, `{dir}/`
		if greed.fs.stat(where) == nil then
			return nil, `there's no {dir} in the project`
		end
	end
	-- A file searched alone is found with an empty path inside it.
	local info = greed.fs.stat(where)
	if info and info.kind == "file" then
		prefix = string.sub(prefix, 1, -2)
	end
	local max = limit or 200
	local lines, err = greed.fs.grep(pattern, where, { limit = max })
	if lines == nil then
		return nil, err
	end
	-- Open files with unsaved changes are searched as they are.
	local unsaved: { [string]: greed.Buffer } = {}
	for _, buffer in greed.buffers() do
		local path = buffer:path()
		if path and buffer:modified() then
			unsaved[relative(path)] = buffer
		end
	end
	local hits: { Hit } = {}
	for _, line in lines do
		local path = prefix .. line.path
		if not unsaved[path] then
			table.insert(hits, { path = path, line = line.line + 1, text = line.text })
		end
	end
	for path, buffer in unsaved do
		if string.sub(path, 1, #prefix) == prefix then
			local seen = {}
			local matches: { { from: number, to: number } } = buffer:find_all(pattern) or {}
			for _, m in matches do
				local line = buffer:line_of(m.from)
				if not seen[line] then
					seen[line] = true
					local text = buffer:line_text(line)
					table.insert(hits, { path = path, line = line + 1, text = text })
				end
			end
		end
	end
	table.sort(hits, function(a: Hit, b: Hit)
		return if a.path == b.path then a.line < b.line else a.path < b.path
	end)
	while #hits > max do
		table.remove(hits)
	end
	return hits, nil
end

local object = registry.schema.object

registry.tool({
	name = "repo_map",
	group = "map",
	description = "A map of the project: the functions and types that matter most, with their "
		.. "files and lines, ranked by how files refer to each other and toward the files the user "
		.. "has open and those in `focus`. Read it first to find your way around",
	input = object({
		focus = {
			type = "array",
			items = { type = "string" },
			description = "Files to rank toward",
		},
		budget = { type = "number", description = "About how many tokens; 2048 by default" },
	}),
	run = function(args)
		return M.map({ focus = args.focus, budget = args.budget })
	end,
})

registry.tool({
	name = "symbols",
	description = "Functions and types in the project whose names match `query` (fuzzily), "
		.. "with their files, 1-based lines and first lines",
	input = object({
		query = { type = "string" },
		limit = { type = "number", description = "50 by default" },
	}, { "query" }),
	run = function(args)
		local found = {}
		for _, d in M.symbols(args.query, args.limit) do
			table.insert(
				found,
				{ path = d.path, line = d.line + 1, kind = d.kind, signature = d.signature }
			)
		end
		return greed.json.array(found)
	end,
})

registry.tool({
	name = "grep",
	description = "The lines matching a regex in the project's files, with 1-based lines. Open "
		.. "files are searched as the user has them, unsaved changes included",
	input = object({
		pattern = { type = "string" },
		path = {
			type = "string",
			description = "A folder in the project to search in, or, given in full, your "
				.. "config folder (and its plugins) or Greed's runtime folder (its own plugins "
				.. "and their types)",
		},
		limit = { type = "number", description = "200 lines by default" },
	}, { "pattern" }),
	run = function(args)
		local hits, err = M.grep(args.pattern, args.path, args.limit)
		if hits == nil then
			error(err, 0)
		end
		if #hits == 0 then
			-- An agent looking for Greed's API in the project gets it from
			-- Greed's own plugins and types instead, and hears so.
			local runtime = runtime_dir()
			if args.path == nil and runtime then
				local there = M.grep(args.pattern, runtime, args.limit)
				if there and #there > 0 then
					return `nothing in the project; these are from Greed's own plugins and types `
						.. `(path "{runtime}" searches only there):\n{greed.json.encode(
							greed.json.array(there)
						)}`
				end
			end
			return `no lines match in {args.path or "the project"}`
		end
		return greed.json.array(hits)
	end,
})

registry.tool({
	name = "files",
	description = "The project's files, skipping hidden and ignored ones; with `query`, those "
		.. "whose paths match it fuzzily, best first",
	input = object({
		query = { type = "string" },
		path = {
			type = "string",
			description = "A folder to list instead of the project: one in it, or, given in "
				.. "full, your config folder (and its plugins) or Greed's runtime folder",
		},
		limit = { type = "number", description = "200 by default" },
	}),
	run = function(args)
		local base = root()
		local dir: string = args.path or base
		if string.sub(dir, 1, 1) ~= "/" then
			dir = `{base}/{dir}`
		elseif not inside(dir, base) and not reachable(dir) then
			error(out_of_reach(dir, "files lists"), 0)
		end
		local all = greed.files(dir)
		-- Paths from the project's root, and outside it in full, so they can be read.
		local prefix = if dir == base
			then ""
			elseif inside(dir, base) then string.sub(dir, #base + 2) .. "/"
			else dir .. "/"
		if prefix ~= "" then
			for i, path in all do
				all[i] = prefix .. path
			end
		end
		local found = {}
		local limit = args.limit or 200
		if args.query then
			for _, i in greed.fuzzy(args.query, all) do
				table.insert(found, all[i])
				if #found >= limit then
					break
				end
			end
		else
			table.move(all, 1, math.min(#all, limit), 1, found)
		end
		return greed.json.array(found)
	end,
})

greed.command({
	name = "repo-map",
	doc = "Show the repo map agents get: the functions and types that matter most, ranked toward the open files",
	run = function()
		local buffer = greed.create_buffer("repo-map", M.map())
		greed.float(buffer, { title = "Repo map", width = "90%", height = "80%" })
	end,
})

return M
