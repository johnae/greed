-- Completing a command's arguments from what knows them, in turn: a
-- completer a plugin added for the program; the program itself when it's
-- built with Cobra (kubectl, helm, gh, docker, flux, argocd, ...); fish's
-- completions when fish is installed; carapace's when it is; and for a
-- flag, the program's man page, read from the file, then what it prints
-- for `--help`, run only when you ask (tab) on a flag. The first to answer
-- wins; with no answer the shell completes files.
--
-- The programs run in the background, in the shell's folder and with its
-- variables, for a moment at most; a newer ask stops an older one, and an
-- answer is kept a few seconds for the same line, so typing more of a word
-- filters what came instead of asking again. The command itself never
-- runs, except for `--help`.

local greed = require("@greed")
local core = require("@core")
local flags = require("./flags")

local M = {}

--- Reading flags from man pages and --help.
M.flags = flags

--- Something that could complete the word, with what it is.
export type Candidate = { text: string, detail: string? }

--- What a source found: `items`, and whether files fit there too
--- (`files`): only folders with `dirs`, only those ending in one of
--- `extensions`. `from` names the source.
export type Found = {
	items: { Candidate },
	files: boolean,
	dirs: boolean?,
	extensions: { string }?,
	from: string,
}

--- An ask for completions: the command's words up to the cursor, the
--- program first and the word being completed last ("" after a space),
--- the command's text up to the cursor, the folder and variables it
--- would run with, and whether you asked (tab) or typing paused.
export type Request = {
	words: { string },
	line: string,
	cwd: string,
	env: { [string]: string | false },
	explicit: boolean,
}

--- Completes a program's arguments: candidates, as text or with a
--- detail, or nil to leave it to the next source.
export type Completer = (request: Request) -> { Candidate | string }?

local completers: { [string]: Completer } = {}

--- Completes the arguments of program `name` with `complete`, ahead of
--- the other sources. It goes when the plugin that added it does.
function M.completer(name: string, complete: Completer)
	greed.plugin.tie(core.registry.set(completers, name, complete))
end

greed.option.define({
	name = "shell-completion-sources",
	needs = "proc",
	doc = "Where a shell completes a program's arguments from, in order: cobra, fish, carapace, man, help",
	default = "cobra fish carapace man help",
})

greed.option.define({
	name = "shell-completion-timeout",
	doc = "Milliseconds a program asked for completions (kubectl, fish, carapace, --help) gets to answer",
	default = 2000,
})

greed.option.define({
	name = "shell-help-completion",
	doc = "When a shell runs a program with --help to complete its flags: on-flag (when you press tab on one) or never",
	default = "on-flag",
	choices = { "on-flag", "never" },
})

greed.option.define({
	name = "shell-help-never",
	doc = "Programs a shell never runs with --help to complete their flags",
	default = "reboot shutdown halt poweroff init telinit kill killall pkill",
})

-- Programs whose own completions are Cobra's, even when looking inside
-- them doesn't say so, as for a wrapper script.
local COBRA: { [string]: boolean } = {
	kubectl = true,
	helm = true,
	gh = true,
	docker = true,
	flux = true,
	argocd = true,
}

-- Cobra prints this after its completions, so every program built with it
-- has it inside.
local COBRA_MARK = "Completion ended with directive"

-- Cobra's directives: bits of the number on its last line.
local ERROR, NO_FILES, EXTENSIONS, DIRS = 1, 4, 8, 16

-- The program running for each source, so a newer ask stops it.
local running: { [string]: greed.Child } = {}

--- Runs `argv` for `source` in `cwd` with `env`, with its input closed,
--- for `shell-completion-timeout` at most; a newer run for the same source
--- stops it. Returns what it printed, its exit code and its errors, or
--- nil when it couldn't start.
function M.run(
	source: string,
	argv: { string },
	cwd: string,
	env: { [string]: string | false }
): (string?, number?, string?)
	local before = running[source]
	if before then
		before:kill()
	end
	local mine: greed.Child? = nil
	local ran = greed.process.run(argv, {
		cwd = cwd,
		env = env,
		group = true,
		timeout = greed.option.get("shell-completion-timeout") :: number,
		on_start = function(child: greed.Child)
			mine = child
			running[source] = child
		end,
	})
	if mine and running[source] == mine then
		running[source] = nil
	end
	if ran == nil then
		return nil, nil, nil
	end
	return ran.stdout, ran.code, ran.stderr
end

--- The path of program `name` in the folders of `path` (a PATH).
function M.find(name: string, path: string?): string?
	if string.find(name, "/", 1, true) then
		return if greed.fs.stat(name) then name else nil
	end
	for dir in string.gmatch(path or "", "[^:]+") do
		local candidate = `{dir}/{name}`
		local info = greed.fs.stat(candidate)
		if info and info.kind ~= "dir" then
			return candidate
		end
	end
	return nil
end

-- Lines of `text` as candidates: each the value, then a tab and what it is.
local function tabbed(text: string): { Candidate }
	local items: { Candidate } = {}
	for _, line in string.split(text, "\n") do
		local value, detail = string.match(line, "^([^\t]*)\t(.*)$")
		local candidate: string = value or line
		if candidate ~= "" then
			table.insert(items, { text = candidate, detail = if detail ~= "" then detail else nil })
		end
	end
	return items
end

--- What Cobra's `__complete` printed, read: candidates, then the directive
--- on the last line; nil when it isn't Cobra's.
function M.read_cobra(text: string): Found?
	local lines = string.split(text, "\n")
	while #lines > 0 and lines[#lines] == "" do
		table.remove(lines)
	end
	local directive = tonumber(string.match(lines[#lines] or "", "^:(%d+)$"))
	if directive == nil then
		return nil
	end
	table.remove(lines)
	if bit32.band(directive, ERROR) ~= 0 then
		return { items = {}, files = false, from = "cobra" }
	end
	local items = tabbed(table.concat(lines, "\n"))
	if bit32.band(directive, EXTENSIONS) ~= 0 then
		local extensions: { string } = {}
		for _, item in items do
			table.insert(extensions, item.text)
		end
		return { items = {}, files = true, extensions = extensions, from = "cobra" }
	elseif bit32.band(directive, DIRS) ~= 0 then
		return { items = {}, files = true, dirs = true, from = "cobra" }
	end
	return {
		items = items,
		files = #items == 0 and bit32.band(directive, NO_FILES) == 0,
		from = "cobra",
	}
end

--- What carapace's `export` printed, read; nil when it found nothing.
function M.read_carapace(text: string): Found?
	local value = greed.json.decode(text)
	if type(value) ~= "table" or type(value.values) ~= "table" then
		return nil
	end
	local items: { Candidate } = {}
	for _, item in value.values do
		if type(item) == "table" and type(item.value) == "string" and item.value ~= "" then
			local detail = item.description
			table.insert(items, {
				text = item.value,
				detail = if type(detail) == "string" and detail ~= "" then detail else nil,
			})
		end
	end
	return if #items > 0 then { items = items, files = false, from = "carapace" } else nil
end

-- Whether each program, by its path, completes as Cobra does.
local cobra: { [string]: boolean } = {}

-- Whether the program at `path` (named `name`) is built with Cobra: one of
-- the known ones, or one with Cobra's completion inside. A program isn't
-- run to find out, as it could do anything with arguments it doesn't know.
local function is_cobra(path: string, name: string): boolean
	local known = cobra[path]
	if known ~= nil then
		return known
	end
	local yes = COBRA[name] == true
	if not yes then
		local found = greed.process.run({ "grep", "-q", COBRA_MARK, path })
		yes = found ~= nil and found.code == 0
	end
	cobra[path] = yes
	return yes
end

-- The name of `request`'s program, without its folder.
local function program_name(request: Request): string
	local program: string = request.words[1]
	return string.match(program, "([^/]+)$") or program
end

-- `into` with `request`'s words after the program added.
local function args_into(request: Request, into: { string }): { string }
	return table.move(request.words, 2, #request.words, #into + 1, into)
end

-- The PATH `request` runs with.
local function search_path(request: Request): string?
	local path = request.env.PATH
	return if type(path) == "string" then path else nil
end

-- Folders fish looks in for completions, which `--no-config` leaves out:
-- yours, then those packages install.
local function fish_paths(request: Request, fish: string): { string }
	local env = request.env
	local home = greed.fs.dirs().home
	local config = if type(env.XDG_CONFIG_HOME) == "string"
		then env.XDG_CONFIG_HOME
		elseif home then `{home}/.config`
		else nil
	local dirs: { string } = {}
	if config then
		table.insert(dirs, `{config}/fish/completions`)
	end
	local data = if type(env.XDG_DATA_DIRS) == "string"
		then env.XDG_DATA_DIRS
		else "/usr/local/share:/usr/share"
	for dir in string.gmatch(data, "[^:]+") do
		table.insert(dirs, `{dir}/fish/vendor_completions.d`)
	end
	-- Fish's own, for a fish that doesn't carry them inside.
	local prefix = string.match(fish, "^(.*)/bin/[^/]+$")
	if prefix then
		table.insert(dirs, `{prefix}/share/fish/completions`)
	end
	return dirs
end

-- The man page of `name` in a folder of MANPATH, or the usual ones and
-- those beside the folders on PATH.
local function man_page(name: string, request: Request): string?
	local env = request.env
	local roots: { string } = {}
	if type(env.MANPATH) == "string" then
		for dir in string.gmatch(env.MANPATH, "[^:]+") do
			table.insert(roots, dir)
		end
	end
	for dir in string.gmatch(search_path(request) or "", "[^:]+") do
		local prefix = string.match(dir, "^(.*)/bin$")
		if prefix then
			table.insert(roots, `{prefix}/share/man`)
		end
	end
	for _, dir in { "/usr/local/share/man", "/usr/share/man", "/opt/homebrew/share/man" } do
		table.insert(roots, dir)
	end
	for _, root in roots do
		for _, section in { "1", "8", "6" } do
			for _, suffix in { "", ".gz" } do
				local path = `{root}/man{section}/{name}.{section}{suffix}`
				if greed.fs.stat(path) then
					return path
				end
			end
		end
	end
	return nil
end

-- Flags read before, by where from (a man page's path, or a program's path
-- and the subcommand), with when that file last changed, and for a
-- program's own help, the subcommands it lists.
type Read = { modified: number?, flags: { flags.Flag }, commands: { [string]: string }? }
local read_flags: { [string]: Read } = {}

-- The flags kept for `key`, read from `path`, when that's still as it was.
local function remembered(key: string, path: string): ({ flags.Flag }?, number?)
	local info = greed.fs.stat(path)
	local modified = info and info.modified
	local kept = read_flags[key]
	if kept and kept.modified == modified then
		return kept.flags, modified
	end
	return nil, modified
end

-- The flags `request`'s program's man page documents, read from the file.
local function man_flags(request: Request): { flags.Flag }?
	local name = program_name(request)
	local page = man_page(name, request)
	if page == nil then
		return nil
	end
	local found, modified = remembered(page, page)
	if found then
		return found
	end
	local roff: string
	if string.match(page, "%.gz$") then
		local result = greed.process.run({ "gzip", "-dc", page })
		if result == nil or result.code ~= 0 then
			return nil
		end
		roff = result.stdout
	else
		local text = greed.fs.read(page)
		if text == nil then
			return nil
		end
		roff = text
	end
	local list = flags.from_man(roff)
	read_flags[page] = { modified = modified, flags = list }
	return list
end

-- Whether `--help` may run for `request`'s program.
local function may_ask_help(request: Request): boolean
	if not request.explicit or greed.option.get("shell-help-completion") ~= "on-flag" then
		return false
	end
	local name = program_name(request)
	for never in string.gmatch(greed.option.get("shell-help-never") :: string, "[^%s,]+") do
		if never == name then
			return false
		end
	end
	return true
end

-- What the program at `path` prints for `--help` (`args` before it), from
-- its output or, if it printed none, its errors.
local function help_text(request: Request, path: string, args: { string }): string?
	local argv = { path }
	table.move(args, 1, #args, 2, argv)
	table.insert(argv, "--help")
	local out, _, err = M.run("help", argv, request.cwd, request.env)
	if out and string.find(out, "%S") then
		return out
	end
	return if err and string.find(err, "%S") then err else nil
end

-- The flags `request`'s program prints for `--help`, or with a subcommand
-- its help lists typed after it, for that one's.
local function help_flags(request: Request, path: string): { flags.Flag }?
	local found, modified = remembered(path, path)
	if found == nil then
		local top = help_text(request, path, {})
		if top == nil then
			return nil
		end
		local read = flags.from_help(top)
		read_flags[path] = { modified = modified, flags = read, commands = flags.commands(top) }
		found = read
	end
	local sub = request.words[2]
	local commands = read_flags[path].commands
	if #request.words > 2 and commands and commands[sub] then
		local key = `{path}\0{sub}`
		local kept = remembered(key, path)
		if kept then
			return kept
		end
		local text = help_text(request, path, { sub })
		if text then
			local read = flags.from_help(text)
			read_flags[key] = { modified = modified, flags = read }
			return read
		end
	end
	return found
end

-- Whether the word being completed is a flag.
local function on_flag(request: Request): boolean
	return string.sub(request.words[#request.words], 1, 1) == "-"
end

-- Flags as candidates.
local function flag_items(list: { flags.Flag }?, from: string): Found?
	if list == nil or #list == 0 then
		return nil
	end
	local items: { Candidate } = {}
	for _, flag in list do
		table.insert(items, { text = flag.text, detail = flag.detail })
	end
	return { items = items, files = false, from = from }
end

-- Each source by name: what it found for `request`, whose program is at
-- `path` (nil when it isn't on PATH), or nil.
local SOURCES: { [string]: (request: Request, path: string?) -> Found? } = {
	cobra = function(request, path)
		if path == nil or not is_cobra(path, program_name(request)) then
			return nil
		end
		local text =
			M.run("cobra", args_into(request, { path, "__complete" }), request.cwd, request.env)
		local found = if text then M.read_cobra(text) else nil
		if found == nil then
			-- It isn't Cobra's after all, or this one has no __complete.
			cobra[path] = false
		end
		return found
	end,
	fish = function(request)
		local fish = M.find("fish", search_path(request))
		if fish == nil then
			return nil
		end
		local argv = {
			fish,
			"--no-config",
			"-c",
			"set -p fish_complete_path $argv[2..]; complete --do-complete $argv[1]",
			request.line,
		}
		local paths = fish_paths(request, fish)
		table.move(paths, 1, #paths, #argv + 1, argv)
		local text = M.run("fish", argv, request.cwd, request.env)
		local items = if text then tabbed(text) else {}
		return if #items > 0 then { items = items, files = false, from = "fish" } else nil
	end,
	carapace = function(request)
		local carapace = M.find("carapace", search_path(request))
		if carapace == nil then
			return nil
		end
		local name = request.words[1]
		local text = M.run(
			"carapace",
			args_into(request, { carapace, name, "export", name }),
			request.cwd,
			request.env
		)
		return if text then M.read_carapace(text) else nil
	end,
	man = function(request)
		if not on_flag(request) then
			return nil
		end
		return flag_items(man_flags(request), "man")
	end,
	help = function(request, path)
		if path == nil or not on_flag(request) or not may_ask_help(request) then
			return nil
		end
		return flag_items(help_flags(request, path), "help")
	end,
}

-- Asks the sources in turn for `request`, whose program is at `path`.
local function ask(request: Request, path: string?): Found?
	local own = completers[program_name(request)]
	if own then
		local ok, list = pcall(own, request)
		if ok and list then
			local items: { Candidate } = {}
			for _, item in list do
				table.insert(items, if type(item) == "string" then { text = item } else item)
			end
			return { items = items, files = false, from = "plugin" }
		end
	end
	for name in string.gmatch(greed.option.get("shell-completion-sources") :: string, "[^%s,]+") do
		local source = SOURCES[name]
		if source then
			local ok, found = pcall(source, request, path)
			if ok and found then
				return found
			end
		end
	end
	return nil
end

-- Answers kept a little while, by the line and folder they're for.
local kept: { [string]: { at: number, found: Found? } } = {}

-- How long an answer is kept, in milliseconds.
local KEEP_MS = 5000

--- What the sources say could complete the last of `request.words`, or
--- nil when none knows. It runs programs, so it waits.
function M.complete(request: Request): Found?
	local key = `{request.cwd}\0{request.line}\0{request.explicit}`
	local now = greed.now()
	local hit = kept[key]
	if hit and now - hit.at < KEEP_MS then
		return hit.found
	end
	local found = ask(request, M.find(request.words[1], search_path(request)))
	for other, entry in kept do
		if now - entry.at >= KEEP_MS then
			kept[other] = nil
		end
	end
	kept[key] = { at = now, found = found }
	return found
end

return M
