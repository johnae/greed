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

local kern = require("@kern")
local defaults = require("@self/languages")

export type Language = defaults.Language

local languages: { [string]: Language } = {}

-- Tells the editor about a language's files and servers.
local function apply(name: string, language: Language)
	kern.filetype(name, { extensions = language.extensions, names = language.names })
	local servers = language.servers
	if servers and #servers > 0 then
		kern.lsp.server({ language = name, commands = servers, root_markers = language.roots })
	else
		kern.lsp.remove(name)
	end
end

local M = {}

--- The entry for language `name`, if Kern knows it.
function M.get(name: string): Language?
	return languages[name]
end

--- Changes language `name`, or adds it: each field given replaces that field.
function M.set(name: string, changes: Language)
	local language: Language = table.clone(languages[name] or {} :: Language)
	for key, value in changes :: { [string]: any } do
		(language :: { [string]: any })[key] = value
	end
	languages[name] = language
	apply(name, language)
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

-- `:health` --------------------------------------------------------------

local shown: kern.View? = nil

local function close_health()
	if shown then
		shown:close()
		shown = nil
	end
end

-- One line per language: its grammar, then each server, found or missing.
local function health_report(): (string, { kern.Mark })
	local grammars = {}
	for _, name in kern.grammars() do
		grammars[name] = true
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
		if grammars[name] then
			line ..= add("highlighting  ")
		else
			line ..= add("no grammar    ", "ui.health.missing")
		end
		local servers = language.servers or {}
		if #servers == 0 then
			line ..= add("no server set", "ui.health.missing")
		end
		for i, command in servers do
			local found = kern.which(command[1]) ~= nil
			if i > 1 then
				line ..= add(", ")
			end
			line ..= add(command[1], if found then "ui.health.found" else "ui.health.missing")
		end
		table.insert(lines, line)
		pos += 1
	end
	return table.concat(lines, "\n"), marks
end

kern.command({
	name = "health",
	doc = "Show each language's highlighting and servers, and which are installed",
	run = function()
		close_health()
		local text, marks = health_report()
		local buffer = kern.create_buffer("health", text, { readonly = true })
		buffer:decorate("health", marks)
		shown = kern.float(
			buffer,
			{ title = "Health: found servers in green", width = "80%", height = "80%" }
		)
	end,
})

kern.command({
	name = "health-close",
	doc = "Close the health report",
	run = close_health,
})

kern.keymap.bind({ mode = "normal", kind = "health" }, { esc = "health-close", q = "health-close" })

return M
