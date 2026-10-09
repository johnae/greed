-- Languages, batteries included: which files are in which language, their
-- language servers and how they're commented and indented. The table is in
-- languages.luau. A server only starts if it's installed, so nothing needs
-- setting up; `:health` shows what's found and what's missing.
--
-- Change an entry from your config. Fields you give replace those fields:
--
--     local languages = require("@languages")
--     languages.set("python", { servers = { { "pylsp" } } })
--     languages.set("odin", { extensions = { "odin" }, servers = { { "ols" } } })

local greed = require("@greed")
local defaults = require("@self/languages")
local core = require("@core")
local comment, indent = core.comment, core.indent
local query_files = require("@self/query_files")
local grammars = require("@self/grammars")

export type Language = defaults.Language

local languages: { [string]: Language } = {}

-- Tells the editor about a language's files.
local function apply(name: string, language: Language)
	greed.filetype(name, { extensions = language.extensions, names = language.names })
	comment.set(name, language.comment)
	indent.set(name, {
		unit = if language.indent then string.rep(" ", language.indent) else "\t",
		openers = language.indent_after,
		closers = language.outdent_before,
	})
end

-- Tells the editor about a language's servers.
local function apply_servers(name: string, language: Language)
	local servers = language.servers
	if servers and #servers > 0 then
		greed.lsp.server({ language = name, commands = servers, root_markers = language.roots })
	else
		greed.lsp.remove(name)
	end
end

-- Who set each language's fields, by language and field: the plugin, or
-- nil for this one and your config.
local set_by: { [string]: { [string]: string } } = {}

-- A copy of `value`, tables inside it too.
local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = copy(v)
	end
	return out
end

local M = {}

--- Language `name`, or nil if Greed doesn't know it. A copy: change it with
--- `set`.
function M.get(name: string): Language?
	return copy(languages[name])
end

--- Changes language `name`, or adds it: each field given replaces that field.
--- What runs a program, its servers and formatter, runs within the limit of
--- the plugin that set it, so it can do no more than that plugin may.
function M.set(name: string, changes: Language)
	local by = greed.plugin.caller()
	local language: Language = table.clone(languages[name] or {} :: Language)
	for key, value in changes :: { [string]: any } do
		(language :: { [string]: any })[key] = copy(value)
	end
	if changes.servers ~= nil or changes.roots ~= nil then
		greed.plugin.within(by, apply_servers, name, language)
	end
	languages[name] = language
	local fields = set_by[name] or {}
	set_by[name] = fields
	for key in changes :: { [string]: any } do
		fields[key] = by
	end
	apply(name, language)
end

--- The plugin that set `field` of language `name`, nil for Greed's own and
--- your config: what runs from it runs within that plugin's limit.
function M.set_by(name: string, field: string): string?
	local fields = set_by[name]
	return fields and fields[field]
end

--- Every language's name, sorted.
function M.list(): { string }
	local names = {}
	for name in languages do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

for name, language in defaults do
	M.set(name, language)
end

-- Queries from files in every plugin and the config folder, read again
-- when plugins come and go.
local own = greed.plugin.dirs().languages

--- Reads the query files again and sets the queries, showing and returning
--- any problems (a query its grammar can't compile), one line each.
function M.load_queries(): { string }
	local problems = query_files.load(own)
	for _, problem in problems do
		greed.echo(problem)
	end
	return problems
end

M.load_queries()
greed.on("plugin.loaded", function(event)
	if event.dir and event.name ~= "languages" and greed.fs.list(`{event.dir}/queries`) then
		M.load_queries()
	end
end)
greed.on("plugin.unloaded", function()
	M.load_queries()
end)

-- Grammars downloaded when a file in their language opens -------------------

M.grammars = grammars

--- Sets up the grammar for `language` if Greed knows where to get one,
--- downloading it the first time. Returns whether it has one now.
function M.ensure_grammar(language: string): boolean
	return grammars.ensure(language, query_files.provides)
end

greed.on("buffer.opened", function(event: greed.BufferChanged)
	local language = event.buffer:language()
	if language and grammars.sources[language] then
		local ok, err = pcall(M.ensure_grammar, language)
		if not ok then
			greed.echo(tostring(err))
		end
	end
end)

greed.command({
	name = "grammar-fetch",
	doc = "Download a grammar Greed knows where to get, ahead of opening a file in it",
	args = { { name = "language", doc = "e.g. ruby" } },
	run = function(ctx)
		local language = ctx.args[1] or ctx.buffer:language()
		if language == nil or grammars.sources[language] == nil then
			error(`Greed doesn't know where to get a grammar for {language or "this buffer"}`, 0)
		end
		if M.ensure_grammar(language) then
			greed.echo(`the {language} grammar is ready`)
		end
	end,
})

-- `:health` --------------------------------------------------------------

--- The lines `:health` ends with: each running server, its program and the
--- folder it runs in, one per project.
function M.running_report(servers: { greed.LspServer }): { string }
	if #servers == 0 then
		return { "", "No language servers running" }
	end
	local lines = { "", "Running language servers:" }
	for _, server in servers do
		local program = server.command[1] or "?"
		local state = if server.ready then "" else " (starting)"
		table.insert(
			lines,
			string.format("%-12s%s in %s%s", server.language, program, server.root, state)
		)
	end
	return lines
end

-- One line per language: its grammar, then each server, found or missing;
-- then the servers running.
local function health_report(): (string, { greed.Mark })
	local have = {}
	for _, name in greed.grammars() do
		have[name] = true
	end
	local lines, marks = {}, {}
	local pos = 0
	local function add(text: string, style: string?)
		if style then
			table.insert(marks, { from = pos, to = pos + #text, style = style })
		end
		pos += #text
		return text
	end
	for _, name in M.list() do
		local language = languages[name]
		local line = add(string.format("%-12s", name))
		if have[name] then
			line ..= add("highlighting  ")
		elseif grammars.sources[name] then
			line ..= add("downloads     ")
		else
			line ..= add("no grammar    ", "ui.health.missing")
		end
		local servers: { { string } } = language.servers or {}
		if #servers == 0 then
			line ..= add("no server set", "ui.health.missing")
		end
		for i, command in servers do
			local found = greed.which(command[1]) ~= nil
			if i > 1 then
				line ..= add(", ")
			end
			line ..= add(command[1], if found then "ui.health.found" else "ui.health.missing")
		end
		table.insert(lines, line)
		pos += 1
	end
	for _, line in M.running_report(greed.lsp.running()) do
		table.insert(lines, add(line))
		pos += 1
	end
	return table.concat(lines, "\n"), marks
end

greed.command({
	name = "health",
	doc = "Show each language's highlighting and servers, and which are installed",
	run = function()
		local text, marks = health_report()
		core.floats.show_text(
			"Health: found servers in green",
			text,
			{ kind = "health", marks = marks, height = "80%" }
		)
	end,
})

return M
