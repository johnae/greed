-- Completion at a shell's prompt, through the completion menu's sources:
-- the builtins and programs on PATH for a command's first word, files and
-- folders from the shell's folder after it, `$` for variables and earlier
-- blocks' output (`$3`), `buf:` for open files and buffers `> buf:` made,
-- and `@sel` and `@file` at a line's start.

local greed = require("@greed")
local core = require("@core")
local parse = require("./parse")
local state = require("./state")
local log = require("./log")
local data = require("./data")

type Shell = state.Shell
type Item = { label: string, detail: string?, text: string, from: number? }

local M = {}

-- The variables programs started in `shell` get: the editor's, with the
-- shell's own on top.
local function environment(shell: Shell): { [string]: string }
	local vars: { [string]: string } = {}
	for name, value in state.editor_environment() do
		if shell.env[name] ~= false then
			vars[name] = value
		end
	end
	for name, value: string | false in shell.env do
		if value ~= false then
			vars[name] = value
		end
	end
	return vars
end

-- The programs in the folders of the last PATH looked through.
local programs: { path: string, names: { string } }? = nil

-- The names of the files in the folders on `path`, each once.
local function executables(path: string): { string }
	if programs and programs.path == path then
		return programs.names
	end
	local seen: { [string]: boolean } = {}
	local names: { string } = {}
	for dir in string.gmatch(path, "[^:]+") do
		local entries = greed.fs.list(dir, { hidden = true, ignored = true })
		if entries then
			for _, entry in entries do
				if not entry.dir and not seen[entry.name] then
					seen[entry.name] = true
					table.insert(names, entry.name)
				end
			end
		end
	end
	table.sort(names)
	programs = { path = path, names = names }
	return names
end

-- Characters after which a new word starts.
local BREAK = "[%s|;&()<>]"

--- What could complete the word before the cursor in `view`, when it shows
--- a shell's prompt; nil for any other buffer, so other sources and the
--- language server get asked.
function M.items(view: greed.View): { Item }?
	local buffer = view:buffer()
	local shell = state.of(buffer)
	if shell == nil then
		return nil
	end
	local pos = view:cursor()
	if not log.in_prompt(shell, pos) then
		return {}
	end
	local start = log.prompt_start(shell)
	local before = buffer:slice(start, pos)
	local at = 1
	for i = #before, 1, -1 do
		if string.match(string.sub(before, i, i), BREAK) then
			at = i + 1
			break
		end
	end
	local word = string.sub(before, at)
	local from = start + at - 1
	-- The first word of a command: nothing but spaces before it since the
	-- prompt's start or a `|`, `;`, `&` or `(`.
	local head = string.sub(before, 1, at - 1)
	local first = string.match(head, "^%s*$") ~= nil or string.match(head, "[|;&(]%s*$") ~= nil
	local items: { Item } = {}
	local function add(text: string, detail: string?)
		table.insert(items, { label = text, text = text, detail = detail, from = from })
	end
	if string.sub(word, 1, 1) == "$" then
		for _, block in shell.blocks do
			add(`${block.number}`, block.command)
		end
		for name in environment(shell) do
			add("$" .. name)
		end
	elseif first and string.sub(word, 1, 1) == "@" then
		add("@sel", "the selection in the file you're in")
		add("@file", "the file you're in")
	elseif string.sub(word, 1, 4) == "buf:" then
		for _, name in data.names() do
			add("buf:" .. name, "made by > buf:")
		end
		for _, open in greed.buffers() do
			local path = open:path()
			if path then
				add("buf:" .. (core.project.basename(path) or path), core.project.short(path))
			end
		end
	elseif first and not string.find(word, "/", 1, true) then
		local names: { string } = {}
		for name in parse.BUILTINS do
			table.insert(names, name)
		end
		table.sort(names)
		for _, name in names do
			add(name, "builtin")
		end
		local path = environment(shell).PATH
		if path then
			for _, name in executables(path) do
				add(name)
			end
		end
	else
		-- Files and folders, from the shell's folder, in the folder the
		-- word names so far.
		local folder = string.match(word, "^(.*/)") or ""
		local typed = string.sub(word, #folder + 1)
		local dir = if folder == "" then shell.cwd else core.project.resolve(folder, shell.cwd)
		local entries =
			greed.fs.list(dir, { hidden = string.sub(typed, 1, 1) == ".", ignored = true })
		if entries then
			for _, entry in entries do
				add(folder .. entry.name .. (if entry.dir then "/" else ""))
			end
		end
	end
	return items
end

-- The completion menu is the lsp plugin's, which can be unloaded: once
-- it's loaded, it asks `items` first, and its keys win over the shell's
-- tab, enter and arrows while it's open.
local function attach()
	local lsp = require("@lsp")
	lsp.completion.source(M.items)
	lsp.completion.keys_over("shell")
end

if table.find(greed.plugin.list(), "lsp") then
	attach()
end

greed.on("plugin.loaded", function(event: greed.PluginLoaded)
	if event.name == "lsp" then
		attach()
	end
end)

return M
