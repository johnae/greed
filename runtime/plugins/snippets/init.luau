-- Snippets of your own, in VS Code's format: a JSON file per language in
-- your snippets folder (`snippets` in your config's folder) or a project's
-- (`.greed/snippets`), each snippet a name with a prefix to type, a body
-- and a description:
--
--     {
--       "test": {
--         "prefix": "test",
--         "body": ["#[test]", "fn ${1:name}() {", "\t$0", "}"],
--         "description": "A test function"
--       }
--     }
--
-- `rust.json` is for Rust, `all.json` for every language, and a
-- `.code-snippets` file, as VS Code shares them, may give a snippet a
-- "scope" ("rust,python"); without one it's for every language. Snippets
-- come up as you type their prefix, after what the language server
-- offers; `:snippet` picks one by name, and `:snippets-edit` opens this
-- language's file. Saving a file reloads it.

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")

greed.option.define({
	name = "snippets-folder",
	doc = "Where your own snippets are; empty for the snippets folder in your config's folder",
	default = "",
})

--- A snippet: its name, the prefixes typing brings it up with, its body
--- (snippet.luau's syntax), what it's for, and the languages it's for
--- (nil for every one).
export type Snippet = {
	name: string,
	prefixes: { string },
	body: string,
	description: string?,
	scope: { [string]: boolean }?,
}

-- A file of snippets read: the language it's for (nil for every one) and
-- its snippets.
type File = { language: string?, snippets: { Snippet } }

local M = {}

--- Your snippets folder.
function M.folder(): string?
	local set = greed.option.get("snippets-folder") :: string
	if set ~= "" then
		return core.project.expand(set)
	end
	local config = greed.fs.dirs().config
	return if config then `{config}/snippets` else nil
end

--- The folders snippets are read from: yours, then the project's.
function M.folders(): { string }
	local out = {}
	local mine = M.folder()
	if mine then
		table.insert(out, mine)
	end
	table.insert(out, `{core.project.root()}/.greed/snippets`)
	return out
end

-- What's been read, by path: each folder's snippet files, and each file.
local listed: { [string]: { string } } = {}
local read: { [string]: File } = {}

greed.on("file.changed", function(event: greed.FileChanged)
	listed[event.path] = nil
	read[event.path] = nil
end)

-- The snippet files in `folder`, watched for changes.
local function files_in(folder: string): { string }
	local known = listed[folder]
	if known then
		return known
	end
	greed.fs.watch(folder)
	local files = {}
	local entries = greed.fs.list(folder, { hidden = true, ignored = true })
	if entries then
		for _, entry in entries do
			local name = entry.name
			local snippets = string.match(name, "%.json$")
				or string.match(name, "%.code%-snippets$")
			if not entry.dir and snippets then
				table.insert(files, `{folder}/{name}`)
			end
		end
	end
	listed[folder] = files
	return files
end

-- `value` as a list of strings: one string alone, or a list.
local function strings(value: any): { string }
	if type(value) == "string" then
		return { value }
	end
	local out = {}
	if type(value) == "table" then
		for _, item in value do
			if type(item) == "string" then
				table.insert(out, item)
			end
		end
	end
	return out
end

--- Reads a snippet file's text: its snippets, or nil and why not. `name`
--- is the file's name, which says the language it's for.
function M.parse(name: string, text: string): (File?, string?)
	local data, err = greed.json.decode(text)
	if type(data) ~= "table" then
		return nil, err or "it isn't a JSON object"
	end
	local language = string.match(name, "^(.+)%.json$")
	if language == "all" then
		language = nil
	end
	local snippets: { Snippet } = {}
	for key, value in data do
		if type(key) ~= "string" or type(value) ~= "table" or value.body == nil then
			continue
		end
		local prefixes = strings(value.prefix)
		local scope: { [string]: boolean }? = nil
		if type(value.scope) == "string" and value.scope ~= "" then
			local set = {}
			for part in string.gmatch(value.scope, "[^,%s]+") do
				set[part] = true
			end
			scope = set
		end
		table.insert(snippets, {
			name = key,
			prefixes = if #prefixes > 0 then prefixes else { key },
			body = table.concat(strings(value.body), "\n"),
			description = if type(value.description) == "string" then value.description else nil,
			scope = scope,
		})
	end
	table.sort(snippets, function(a: Snippet, b: Snippet): boolean
		return a.name < b.name
	end)
	return { language = language, snippets = snippets }, nil
end

-- The snippet file at `path`, read once until it changes.
local function file(path: string): File
	local known = read[path]
	if known then
		return known
	end
	greed.fs.watch(path)
	local name = core.project.basename(path) or path
	local parsed, err = M.parse(name, greed.fs.read(path) or "{}")
	if parsed == nil then
		greed.echo(`snippets: {path}: {err}`)
	end
	local got: File = parsed or { language = nil, snippets = {} } :: File
	read[path] = got
	return got
end

--- The snippets for `buffer`'s language, yours first, then the project's.
function M.for_buffer(buffer: greed.Buffer): { Snippet }
	local language = buffer:language()
	local out: { Snippet } = {}
	for _, folder in M.folders() do
		for _, path in files_in(folder) do
			local got = file(path)
			if got.language == nil or got.language == language then
				for _, snippet in got.snippets do
					local scope = snippet.scope
					if scope == nil or (language ~= nil and scope[language]) then
						table.insert(out, snippet)
					end
				end
			end
		end
	end
	return out
end

-- What the completion menu offers at the cursor in `view`: the snippets
-- whose prefix starts with what's typed, or every one when asked.
local function offered(view: greed.View, asked: { explicit: boolean }): { core.CompletionItem }?
	local buffer = view:buffer()
	if buffer:kind() ~= "file" then
		return nil
	end
	local pos = view:cursor()
	local before = buffer:slice(buffer:line_start(buffer:line_of(pos)), pos)
	local typed = string.match(before, "[%w_%-]*$") or ""
	if typed == "" and not asked.explicit then
		return nil
	end
	local items: { core.CompletionItem } = {}
	for _, snippet in M.for_buffer(buffer) do
		for _, prefix in snippet.prefixes do
			if string.sub(prefix, 1, #typed) == typed then
				table.insert(items, {
					label = prefix,
					detail = snippet.description or snippet.name,
					badge = "snippet",
					text = snippet.body,
					from = pos - #typed,
					snippet = true,
				})
			end
		end
	end
	return items
end

-- Snippets come up as their prefix is typed, after the server's items,
-- while the lsp plugin, which has the menu, is loaded.
local function attach()
	require("@lsp").completion.source(offered, { adds = true })
end

if table.find(greed.plugin.list(), "lsp") then
	attach()
end

greed.on("plugin.loaded", function(event: greed.PluginLoaded)
	if event.name == "lsp" then
		attach()
	end
end)

--- Puts `snippet` in at the cursor in `view`, in place of what's selected
--- where typing replaces it, and starts typing there.
function M.insert(view: greed.View, snippet: Snippet)
	if not core.style.is_typing() then
		greed.run("insert-mode")
	end
	local selection = view:selection()
	local from, to = core.text.span(selection.ranges[selection.primary])
	core.snippet.expand(view, from, to, snippet.body)
end

greed.command({
	name = "snippet",
	doc = "Pick one of the snippets for this file's language by name and put it in",
	run = function(ctx)
		local items = {}
		for _, snippet in M.for_buffer(ctx.buffer) do
			local prefixes = table.concat(snippet.prefixes, ", ")
			local about = if snippet.description then `  {snippet.description}` else ""
			table.insert(items, { label = `{snippet.name} ({prefixes}){about}`, value = snippet })
		end
		if #items == 0 then
			greed.echo("no snippets for this language; :snippets-edit adds some")
			return
		end
		local view = ctx.view
		picker.pick("Snippets", items, function(item)
			M.insert(view, item.value :: Snippet)
		end)
	end,
})

greed.command({
	name = "snippets-edit",
	doc = "Open your snippets for this file's language, making the file if there's none",
	run = function(ctx)
		local folder = M.folder()
		if folder == nil then
			greed.echo("no config folder to keep snippets in")
			return
		end
		local path = `{folder}/{ctx.buffer:language() or "all"}.json`
		if greed.fs.stat(path) == nil then
			local ok, err = greed.fs.write(path, "{\n}\n")
			if not ok then
				greed.echo(`snippets: {err}`)
				return
			end
		end
		core.file.open(path)
	end,
})

return M
