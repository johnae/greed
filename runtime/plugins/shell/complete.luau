-- Completion at a shell's prompt, through the completion menu's sources.
-- The shell's own things are marked "greed": its builtins and their
-- arguments (cd folders, open files and buffers, export and unset
-- variables, help topics), the table stages after `$3 |` with the columns
-- of the table they read, `$3`, `buf:`, `@sel` and `@file`. A command's
-- first word is a builtin or a program on PATH; a program's arguments come
-- from sources.luau (Cobra, fish, carapace, man pages, --help), and files
-- and folders from the shell's folder.

local greed = require("@greed")
local core = require("@core")
local parse = require("./parse")
local state = require("./state")
local log = require("./log")
local data = require("./data")
local tables = require("./tables")
local sources = require("./sources")

type Shell = state.Shell
type Item = { label: string, detail: string?, badge: string?, text: string, from: number? }

local M = {}

--- The badge on what the shell itself knows, as against programs.
M.BADGE = "greed"

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

-- The stages by name.
local STAGES: { [string]: tables.Stage } = {}
for _, stage in tables.STAGES do
	STAGES[stage.name] = stage
end

-- What's being completed: the word before the cursor, where it starts,
-- and the command it's in.
type Spot = {
	shell: Shell,
	word: string,
	from: number,
	-- The command's words before the word, and its text up to the word.
	words: { string },
	text: string,
	-- Whether the command starts the line, and the line's start when it
	-- reads a source (`$3 |`) with only table stages since: the source,
	-- and the stages before this command.
	first_command: boolean,
	source: string?,
	stages: string?,
	explicit: boolean,
}

-- `text` cut at each `|`, `;`, `&` and `(` outside quotes, with the
-- character that ended each piece.
local function commands(text: string): { { text: string, ends: string } }
	local parts: { { text: string, ends: string } } = {}
	local start, quote = 1, nil :: string?
	for i = 1, #text do
		local ch = string.sub(text, i, i)
		if quote then
			if ch == quote then
				quote = nil
			end
		elseif ch == "'" or ch == '"' then
			quote = ch
		elseif string.find("|;&(", ch, 1, true) then
			table.insert(parts, { text = string.sub(text, start, i - 1), ends = ch })
			start = i + 1
		end
	end
	table.insert(parts, { text = string.sub(text, start), ends = "" })
	return parts
end

-- Where the cursor in `view` is, for completing at a shell's prompt.
local function spot(shell: Shell, view: greed.View, explicit: boolean): Spot
	local buffer = shell.buffer
	local start = log.prompt_start(shell)
	local before = buffer:slice(start, view:cursor())
	local at = 1
	for i = #before, 1, -1 do
		if string.match(string.sub(before, i, i), BREAK) then
			at = i + 1
			break
		end
	end
	local parts = commands(string.sub(before, 1, at - 1))
	local text = parts[#parts].text
	local words: { string } = {}
	for word in string.gmatch(text, "%S+") do
		table.insert(words, word)
	end
	-- A source starting the line, piped only through stages since.
	local source: string? = nil
	local stages: { string } = {}
	local first = parts[1]
	local head = string.match(first.text, "^%s*(.-)%s*$") or ""
	if #parts > 1 and first.ends == "|" and parse.is_source(head) then
		source = head
		for i = 2, #parts - 1 do
			local name = string.match(parts[i].text, "^%s*(%S+)")
			if parts[i].ends ~= "|" or name == nil or STAGES[name] == nil then
				source = nil
				break
			end
			table.insert(stages, parts[i].text)
		end
	end
	return {
		shell = shell,
		word = string.sub(before, at),
		from = start + at - 1,
		words = words,
		text = text,
		first_command = #parts == 1,
		source = source,
		stages = if #stages > 0 then table.concat(stages, "|") else nil,
		explicit = explicit,
	}
end

-- Adds an item for `text` at `s`'s word to `items`.
local function add(
	items: { Item },
	s: Spot,
	text: string,
	detail: string?,
	badge: string?,
	from: number?
)
	table.insert(
		items,
		{ label = text, text = text, detail = detail, badge = badge, from = from or s.from }
	)
end

-- Files and folders for `s`'s word, from the shell's folder, in the folder
-- the word names so far: only folders with `dirs`, only files ending in
-- one of `extensions`.
local function files(items: { Item }, s: Spot, dirs: boolean?, extensions: { string }?)
	local word = s.word
	local folder = string.match(word, "^(.*/)") or ""
	local typed = string.sub(word, #folder + 1)
	local dir = if folder == "" then s.shell.cwd else core.project.resolve(folder, s.shell.cwd)
	local entries = greed.fs.list(dir, { hidden = string.sub(typed, 1, 1) == ".", ignored = true })
	if entries == nil then
		return
	end
	for _, entry in entries do
		local fits = entry.dir or not dirs
		if fits and extensions and not entry.dir then
			fits = false
			for _, extension in extensions do
				if string.sub(entry.name, -#extension - 1) == "." .. extension then
					fits = true
					break
				end
			end
		end
		if fits then
			add(items, s, folder .. entry.name .. (if entry.dir then "/" else ""))
		end
	end
end

-- The open buffers as `buf:NAME`, the ones `> buf:` made first.
local function buffers(items: { Item }, s: Spot)
	for _, name in data.names() do
		add(items, s, "buf:" .. name, "made by > buf:", M.BADGE)
	end
	for _, open in greed.buffers() do
		local path = open:path()
		if path then
			add(
				items,
				s,
				"buf:" .. (core.project.basename(path) or path),
				core.project.short(path),
				M.BADGE
			)
		end
	end
end

-- The variables of `s`'s shell, each followed by `after`: those it sets
-- first, saying so.
local function variables(items: { Item }, s: Spot, after: string)
	local own: { [string]: boolean } = {}
	for name, value: string | false in s.shell.env do
		if value ~= false then
			own[name] = true
			add(items, s, name .. after, "set in this shell")
		end
	end
	for name in environment(s.shell) do
		if not own[name] then
			add(items, s, name .. after)
		end
	end
end

-- What completes a builtin's argument at `s`.
local function builtin_args(items: { Item }, s: Spot, builtin: parse.Builtin)
	local args = builtin.args
	if args == "folder" then
		files(items, s, true)
	elseif args == "path" then
		files(items, s)
		buffers(items, s)
	elseif args == "assignment" then
		variables(items, s, "=")
	elseif args == "variable" then
		variables(items, s, "")
	elseif args == "topic" and #s.words == 1 then
		for _, topic in parse.HELP_TOPICS do
			add(items, s, topic.name, topic.about, M.BADGE)
		end
	end
end

-- A table's column names as they're typed: spaces as `_`.
local function column_names(tbl: tables.Table): { string }
	local names: { string } = {}
	for _, column in tbl.columns do
		table.insert(names, (string.gsub(column, "%s+", "_")))
	end
	return names
end

-- The table the stage at `s` reads: the source's, through the stages
-- before it.
local function stage_input(s: Spot): tables.Table?
	local source = s.source
	if source == nil then
		return nil
	end
	local text, value = data.read(s.shell, source, s.shell.cwd)
	local tbl = data.table(s.shell, source, text, value)
	local before = s.stages
	if before then
		tbl = tables.pipeline(tbl, text, before)
	end
	return tbl
end

-- The different cells of `column` in `tbl`, at most a hundred.
local function cells_of(tbl: tables.Table, column: string): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for _, row in tbl.rows do
		local cell = row[column] or ""
		if cell ~= "" and not seen[cell] then
			seen[cell] = true
			table.insert(out, cell)
			if #out >= 100 then
				break
			end
		end
	end
	return out
end

-- What completes a stage's argument at `s`: columns of the table it reads,
-- comparisons, a column's cells, flags and formats.
local function stage_args(items: { Item }, s: Spot, stage: tables.Stage)
	local args = stage.args
	local count = #s.words
	if args == "header" then
		add(items, s, "-H", "no header: columns named 1, 2, ...", M.BADGE)
		return
	elseif args == "format" then
		if count == 1 then
			for _, format in { "csv", "tsv", "json" } do
				add(items, s, format, nil, M.BADGE)
			end
		end
		return
	end
	local tbl = stage_input(s)
	if tbl == nil then
		return
	end
	local word = s.word
	if args == "columns" then
		-- After the last comma, the columns not named yet.
		local listed = string.match(word, "^(.*,)") or ""
		local named: { [string]: boolean } = {}
		for name in string.gmatch(listed, "[^,]+") do
			named[string.lower(name)] = true
		end
		for _, name in column_names(tbl) do
			if not named[string.lower(name)] then
				add(items, s, name, "column", M.BADGE, s.from + #listed)
			end
		end
	elseif args == "column" then
		if count == 1 then
			for _, name in column_names(tbl) do
				add(items, s, name, "column", M.BADGE)
			end
		end
		add(items, s, "-r", "from the greatest", M.BADGE)
	elseif args == "condition" then
		local column = if count >= 2 then tables.column(tbl, s.words[2]) else nil
		if count == 1 then
			-- A column, or `COL=` and what's typed after it.
			for _, op in tables.OPS do
				local at = string.find(word, op, 1, true)
				local typed_column = if at
					then tables.column(tbl, string.sub(word, 1, at - 1))
					else nil
				if at and typed_column then
					for _, cell in cells_of(tbl, typed_column) do
						add(items, s, cell, typed_column, M.BADGE, s.from + at - 1 + #op)
					end
					return
				end
			end
			for _, name in column_names(tbl) do
				add(items, s, name, "column", M.BADGE)
			end
		elseif count == 2 and column then
			for _, op in tables.OPS do
				add(items, s, op, nil, M.BADGE)
			end
		elseif count == 3 and column then
			for _, cell in cells_of(tbl, column) do
				add(items, s, cell, column, M.BADGE)
			end
		end
	end
end

-- The word up to where the sources' answers change: its leading dashes,
-- then up to its last `/`, `=`, `:` or `,`, so typing more of a word
-- filters what came instead of asking again.
local function settled(word: string): string
	local dashes = string.match(word, "^%-*") or ""
	local rest = string.sub(word, #dashes + 1)
	return dashes .. (string.match(rest, "^(.*[/=:,])") or "")
end

-- What completes a program's argument at `s`: what the sources say, and
-- files when they say nothing, or that files fit.
local function program_args(items: { Item }, s: Spot)
	local prefix = settled(s.word)
	local words = table.clone(s.words)
	table.insert(words, prefix)
	local env: { [string]: string | false } = { PAGER = "cat", GIT_PAGER = "cat" }
	for name, value in environment(s.shell) do
		env[name] = value
	end
	local found = sources.complete({
		words = words,
		line = s.text .. prefix,
		cwd = s.shell.cwd,
		env = env,
		explicit = s.explicit,
	})
	if found then
		for _, item in found.items do
			add(items, s, item.text, item.detail)
		end
	end
	if found == nil or found.files then
		files(items, s, found and found.dirs, found and found.extensions)
	end
end

--- What could complete the word before the cursor in `view`, when it shows
--- a shell's prompt; nil for any other buffer, so other sources and the
--- language server get asked. Asking programs, it waits.
function M.items(view: greed.View, ask: { explicit: boolean }?): { Item }?
	local shell = state.of(view:buffer())
	if shell == nil then
		return nil
	end
	if not log.in_prompt(shell, view:cursor()) then
		return {}
	end
	local s = spot(shell, view, ask ~= nil and ask.explicit)
	local items: { Item } = {}
	local word = s.word
	local first = #s.words == 0
	if string.sub(word, 1, 1) == "$" then
		for _, block in shell.blocks do
			add(items, s, `${block.number}`, block.command, M.BADGE)
		end
		for name in environment(shell) do
			add(items, s, "$" .. name)
		end
	elseif first and s.first_command and string.sub(word, 1, 1) == "@" then
		add(items, s, "@sel", "the selection in the file you're in", M.BADGE)
		add(items, s, "@file", "the file you're in", M.BADGE)
	elseif string.sub(word, 1, 4) == "buf:" then
		buffers(items, s)
	elseif first and not string.find(word, "/", 1, true) then
		if s.first_command then
			for _, name in parse.builtin_names() do
				add(items, s, name, parse.BUILTINS[name].doc, M.BADGE)
			end
		elseif s.source then
			for _, stage in tables.STAGES do
				add(items, s, stage.name, stage.doc, M.BADGE)
			end
		end
		local path = environment(shell).PATH
		if path then
			for _, name in executables(path) do
				add(items, s, name)
			end
		end
	elseif not first then
		local command = s.words[1]
		local builtin = if s.first_command then parse.BUILTINS[command] else nil
		local stage = if s.source then STAGES[command] else nil
		if builtin then
			builtin_args(items, s, builtin)
		elseif stage then
			stage_args(items, s, stage)
		else
			program_args(items, s)
		end
	else
		files(items, s)
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
