-- Tree-sitter queries from files: `queries/<language>/<kind>.scm` in every
-- plugin's folder and in your config folder, e.g.
-- `~/.config/kern/queries/rust/highlights.scm`. This plugin's own come
-- first, then other plugins', then yours. A later file replaces an earlier
-- one, unless its first line is `; extends`, which adds it to the end.

local kern = require("@kern")

local M = {}

-- The folders to look in, in order: this plugin's, the others' (by name),
-- then the config folder.
local function roots(own: string?): { string }
	local list = {}
	if own then
		table.insert(list, own)
	end
	local dirs = kern.plugin.dirs()
	local names = {}
	for name, dir in dirs do
		if dir ~= own then
			table.insert(names, name)
		end
	end
	table.sort(names)
	for _, name in names do
		table.insert(list, dirs[name])
	end
	local config = kern.fs.dirs().config
	if config then
		table.insert(list, config)
	end
	return list
end

type Query = { language: string, kind: string, source: string }

-- Every query in `root`'s queries folder.
local function files(root: string): { Query }
	local found = {}
	for _, language in kern.fs.list(`{root}/queries`) or {} do
		if language.dir then
			for _, file in kern.fs.list(`{root}/queries/{language.name}`) or {} do
				local kind = string.match(file.name, "^(.+)%.scm$")
				local source = kind and kern.fs.read(`{root}/queries/{language.name}/{file.name}`)
				if kind and source then
					table.insert(found, { language = language.name, kind = kind, source = source })
				end
			end
		end
	end
	return found
end

-- What was set last time, so queries whose files went away are taken back.
local set: { [string]: Query } = {}

--- Reads every query file again and sets the queries. Problems (a query a
--- grammar can't compile) are returned, one line each.
function M.load(own: string?): { string }
	local combined: { [string]: Query } = {}
	for _, root in roots(own) do
		for _, file in files(root) do
			local key = `{file.language}/{file.kind}`
			local before = combined[key]
			if before and string.match(file.source, "^;+%s*extends") then
				before.source ..= "\n" .. file.source
			else
				combined[key] = file
			end
		end
	end
	local problems = {}
	for key, query in combined do
		local ok, err = pcall(kern.syntax.set_query, query.language, query.kind, query.source)
		if not ok then
			table.insert(problems, `queries/{key}.scm: {err}`)
		end
	end
	for key, query in set do
		if combined[key] == nil then
			kern.syntax.set_query(query.language, query.kind, nil)
		end
	end
	set = combined
	table.sort(problems)
	return problems
end

return M
