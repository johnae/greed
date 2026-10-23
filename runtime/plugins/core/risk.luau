-- Which command lines change or destroy something that matters, so an
-- agent running one is asked about it every time: `kubectl delete`, `git
-- push --force`, `curl -X DELETE`, `rm -rf`. Each program's rules say why
-- a command of it is risky, given its words; the plugin that knows a
-- program adds its rules (kubectl's are the kubernetes plugin's).
--
-- It reads command lines leniently: every command of a pipeline or list
-- (`a | b && c; d`, and what's inside `$(...)`), past `env`, `nohup` and
-- variable assignments. It's there to catch mistakes, not someone hiding
-- a command; running anything is already something you allow.

local greed = require("@greed")
local registry = require("./registry")

local M = {}

--- Why a command (its words, the program first, as typed) is risky, or nil
--- when it isn't.
export type Rule = (words: { string }) -> string?

type Entry = { program: string, rule: Rule }

local rules: { Entry } = {}

--- Adds `rule` for commands running `program` (its name, without a
--- folder), until the plugin that added it goes.
function M.rule(program: string, rule: Rule)
	local entry: Entry = { program = program, rule = rule }
	greed.plugin.cleanup(registry.put(rules, entry, function(other: Entry): boolean
		return other == entry
	end))
end

-- Greed's own commands that do something an agent should ask about, by
-- name: why.
local editor_commands: { [string]: string } = {}

--- Says running Greed's command `name` is risky for an agent, and `why`
--- ("sends the mail being written"), until the plugin that said so goes.
function M.editor_command(name: string, why: string)
	greed.plugin.cleanup(registry.set(editor_commands, name, why))
end

--- Why running Greed's command `name` is risky for an agent, or nil.
function M.of_editor_command(name: string): string?
	return editor_commands[name]
end

-- The commands in `line`, each as its words: split at the characters that
-- end a command outside quotes, quotes taken off.
local function commands(line: string): { { string } }
	local out: { { string } } = {}
	local words: { string } = {}
	local word: { string }? = nil
	local quote: string? = nil
	local function end_word()
		if word then
			table.insert(words, table.concat(word))
			word = nil
		end
	end
	local function end_command()
		end_word()
		if #words > 0 then
			table.insert(out, words)
		end
		words = {}
	end
	for i = 1, #line do
		local ch = string.sub(line, i, i)
		if quote then
			if ch == quote then
				quote = nil
			else
				table.insert(word :: { string }, ch)
			end
		elseif ch == "'" or ch == '"' then
			quote = ch
			word = word or {}
		elseif ch == " " or ch == "\t" then
			end_word()
		elseif
			ch == "&"
			and (string.sub(line, i - 1, i - 1) == ">" or string.sub(line, i + 1, i + 1) == ">")
		then
			-- A redirection, like `2>&1` or `&>`, not the end of a command.
			word = word or {}
			table.insert(word :: { string }, ch)
		elseif string.find("|&;\n()`", ch, 1, true) then
			end_command()
		elseif ch == "$" and string.sub(line, i + 1, i + 1) == "(" then
			end_command()
		else
			word = word or {}
			table.insert(word :: { string }, ch)
		end
	end
	end_command()
	return out
end

-- Words that run the command after them.
local RUNS_NEXT: { [string]: boolean } = {
	sudo = true,
	doas = true,
	env = true,
	nohup = true,
	time = true,
	command = true,
	exec = true,
	nice = true,
	xargs = true,
}

-- `words` from the program it runs: past `sudo`, `env`, their flags and
-- variable assignments.
local function program_words(words: { string }): { string }
	local i = 1
	while i <= #words do
		local word = words[i]
		local assignment = string.match(word, "^[%a_][%w_]*=") ~= nil
		local flag = i > 1 and RUNS_NEXT[words[i - 1]] and string.sub(word, 1, 1) == "-"
		if not (assignment or RUNS_NEXT[word] or flag) then
			break
		end
		i += 1
	end
	return table.move(words, i, #words, 1, {})
end

-- Words that run what follows as another user.
local AS_ROOT: { [string]: boolean } = { sudo = true, doas = true }

--- The commands in `line` (each of a pipeline or list, and what's inside
--- `$(...)`), each as its words from the program it runs, quotes taken
--- off; and whether any of them runs as root.
function M.commands(line: string): ({ { string } }, boolean)
	local out: { { string } } = {}
	local root = false
	for _, typed in commands(line) do
		for _, word in typed do
			root = root or AS_ROOT[word] == true
		end
		local words = program_words(typed)
		if #words > 0 then
			table.insert(out, words)
		end
	end
	return out, root
end

--- Why `line` is risky to run: what the first risky command in it does,
--- by its program's rules, or else that something in it runs as root; nil
--- when nothing in it is.
function M.of(line: string): string?
	local found, root = M.commands(line)
	for _, words in found do
		local program = M.program(words)
		for _, entry in rules do
			if entry.program == program then
				local ok, why = pcall(entry.rule, words)
				if ok and why then
					return why
				end
			end
		end
	end
	return if root then "runs as root" else nil
end

--- The name of the program `words` run, without its folder.
function M.program(words: { string }): string
	return string.match(words[1], "([^/]+)$") or words[1]
end

--- Whether `words` has any of `flags`, alone or with a value (`--force`,
--- `--force=true`), or a short one among others (`-rf` has `-f`).
function M.has_flag(words: { string }, flags: { string }): boolean
	for _, word in words do
		for _, flag in flags do
			if word == flag or string.sub(word, 1, #flag + 1) == flag .. "=" then
				return true
			end
			local short = string.match(flag, "^%-(%a)$")
			if short and string.match(word, "^%-%a+$") and string.find(word, short, 2, true) then
				return true
			end
		end
	end
	return false
end

--- The words of `words` that aren't flags, from the second.
function M.args(words: { string }): { string }
	local out: { string } = {}
	for i = 2, #words do
		if string.sub(words[i], 1, 1) ~= "-" then
			table.insert(out, words[i])
		end
	end
	return out
end

--- Whether a command (its words, the program first) is safe: it only
--- looks, or builds and tests what's there, changing nothing else.
export type Safe = (words: { string }) -> boolean

type SafeEntry = { program: string, safe: Safe }

local safe_rules: { SafeEntry } = {}

--- Says commands running `program` are safe when `safe` says so of their
--- words (always, without it), until the plugin that said so goes.
function M.safe_when(program: string, safe: Safe?)
	local entry: SafeEntry = {
		program = program,
		safe = safe or function()
			return true
		end,
	}
	greed.plugin.cleanup(registry.put(safe_rules, entry, function(other: SafeEntry): boolean
		return other == entry
	end))
end

-- Whether `line` sends output into a file: a `>` outside quotes, unless
-- into /dev/null or another output (`2>&1`).
local function into_file(line: string): boolean
	local quote: string? = nil
	for i = 1, #line do
		local ch = string.sub(line, i, i)
		if quote then
			if ch == quote then
				quote = nil
			end
		elseif ch == "'" or ch == '"' then
			quote = ch
		elseif ch == ">" and string.sub(line, i + 1, i + 1) ~= ">" then
			local target = string.match(string.sub(line, i + 1), "^%s*(%S*)") or ""
			if target ~= "/dev/null" and not string.match(target, "^&%d") then
				return true
			end
		end
	end
	return false
end

--- Whether `line` is safe to run: every command in it is one a rule
--- (`safe_when`) says only looks, or builds and tests, and nothing goes
--- into a file. A command no rule knows isn't, nor one run as root.
function M.safe(line: string): boolean
	local found, root = M.commands(line)
	if root or #found == 0 or into_file(line) then
		return false
	end
	for _, words in found do
		local program = M.program(words)
		local known = false
		for _, entry in safe_rules do
			if entry.program == program then
				local ok, safe = pcall(entry.safe, words)
				known = known or (ok and safe == true)
			end
		end
		if not known then
			return false
		end
	end
	return true
end

-- The rules for programs no plugin knows better.

M.rule("rm", function(words)
	return if M.has_flag(words, { "-r", "-R", "-f", "--recursive", "--force" })
		then "deletes files without asking"
		else "deletes files"
end)

for _, program in { "dd", "mkfs", "shutdown", "reboot", "halt", "poweroff" } do
	M.rule(program, function()
		return `changes the machine itself ({program})`
	end)
end

for _, program in { "chmod", "chown" } do
	M.rule(program, function(words)
		return if M.has_flag(words, { "-R", "--recursive" })
			then `changes who may use every file under a folder`
			else nil
	end)
end

M.rule("kill", function()
	return "stops a program"
end)
M.rule("pkill", function()
	return "stops programs by name"
end)
M.rule("killall", function()
	return "stops programs by name"
end)

M.rule("git", function(words)
	local args = M.args(words)
	local command = args[1]
	if command == "push" then
		if M.has_flag(words, { "-f", "--force", "--force-with-lease", "--delete", "-d" }) then
			return "pushes over or deletes what's on a remote"
		end
		return "sends commits to a remote"
	elseif command == "reset" and M.has_flag(words, { "--hard" }) then
		return "throws away changes"
	elseif command == "clean" then
		return "deletes files git doesn't track"
	elseif command == "branch" and M.has_flag(words, { "-D" }) then
		return "deletes a branch, merged or not"
	elseif command == "checkout" and table.find(words, "--") then
		return "throws away changes to files"
	elseif command == "restore" then
		return "throws away changes to files"
	end
	return nil
end)

M.rule("jj", function(words)
	local args = M.args(words)
	if args[1] == "git" and args[2] == "push" then
		return "sends changes to a remote"
	elseif args[1] == "abandon" then
		return "abandons changes"
	elseif args[1] == "op" and (args[2] == "restore" or args[2] == "abandon") then
		return "rewinds the repository's history"
	end
	return nil
end)

-- The HTTP methods that change something.
local CHANGING: { [string]: boolean } = { POST = true, PUT = true, PATCH = true, DELETE = true }

M.rule("curl", function(words)
	for i, word in words do
		local method = if word == "-X" or word == "--request"
			then words[i + 1]
			else string.match(word, "^%-%-request=(.+)$") or string.match(word, "^%-X(%a+)$")
		if method and CHANGING[string.upper(method)] then
			return `sends a {string.upper(method)} request`
		end
	end
	if
		M.has_flag(words, {
			"-d",
			"--data",
			"--data-raw",
			"--data-binary",
			"--json",
			"-F",
			"--form",
			"-T",
			"--upload-file",
		})
	then
		return "sends data in a request"
	end
	return nil
end)

for _, program in { "http", "https", "xh" } do
	M.rule(program, function(words)
		local method = M.args(words)[1]
		return if method and CHANGING[string.upper(method)]
			then `sends a {string.upper(method)} request`
			else nil
	end)
end

-- The helm commands that change a cluster.
local HELM_CHANGES: { [string]: boolean } =
	{ install = true, upgrade = true, uninstall = true, delete = true, rollback = true }

M.rule("helm", function(words)
	local command = M.args(words)[1]
	return if command and HELM_CHANGES[command] then `changes a cluster (helm {command})` else nil
end)

M.rule("terraform", function(words)
	local command = M.args(words)[1]
	if command == "apply" or command == "destroy" or command == "import" or command == "taint" then
		return `changes real infrastructure (terraform {command})`
	elseif command == "state" then
		return "changes terraform's state"
	end
	return nil
end)

-- The safe commands of programs no plugin knows better.

for _, program in
	{
		"ls",
		"cat",
		"head",
		"tail",
		"wc",
		"grep",
		"egrep",
		"fgrep",
		"rg",
		"ag",
		"fd",
		"tree",
		"bat",
		"pwd",
		"cd",
		"echo",
		"printf",
		"which",
		"type",
		"file",
		"stat",
		"du",
		"df",
		"diff",
		"cmp",
		"uniq",
		"cut",
		"tr",
		"column",
		"nl",
		"basename",
		"dirname",
		"realpath",
		"readlink",
		"date",
		"uname",
		"whoami",
		"id",
		"hostname",
		"true",
		"false",
		"test",
		"[",
		"seq",
		"jq",
		"tokei",
	}
do
	M.safe_when(program)
end

M.safe_when("sort", function(words)
	return not M.has_flag(words, { "-o", "--output" })
end)

M.safe_when("sed", function(words)
	for _, word in words do
		if string.sub(word, 1, 2) == "-i" or string.sub(word, 1, 10) == "--in-place" then
			return false
		end
	end
	return not M.has_flag(words, { "-i" })
end)

-- What makes `find` change things or write files.
local FIND_ACTS: { [string]: boolean } = {
	["-delete"] = true,
	["-exec"] = true,
	["-execdir"] = true,
	["-ok"] = true,
	["-okdir"] = true,
	["-fprint"] = true,
	["-fprint0"] = true,
	["-fprintf"] = true,
	["-fls"] = true,
}

M.safe_when("find", function(words)
	for _, word in words do
		if FIND_ACTS[word] then
			return false
		end
	end
	return true
end)

-- `words`' subcommand and what follows it: past flags, and the values of
-- `with_value`'s flags (git's `-C dir`).
local function subcommand(words: { string }, with_value: { [string]: boolean }): { string }
	local i = 2
	while i <= #words and string.sub(words[i], 1, 1) == "-" do
		i += if with_value[words[i]] then 2 else 1
	end
	return table.move(words, i, #words, 1, {})
end

-- The git commands that only look.
local GIT_LOOKS: { [string]: boolean } = {
	status = true,
	log = true,
	diff = true,
	show = true,
	blame = true,
	["rev-parse"] = true,
	["ls-files"] = true,
	["ls-tree"] = true,
	grep = true,
	describe = true,
	shortlog = true,
	["cat-file"] = true,
	reflog = true,
	["merge-base"] = true,
}

M.safe_when("git", function(words)
	local rest = subcommand(words, { ["-C"] = true, ["-c"] = true })
	local command = rest[1]
	if command and GIT_LOOKS[command] then
		return true
	end
	-- Listing, without a name to make, rename or delete.
	local listing = #M.args(rest) == 0
	if command == "branch" or command == "tag" or command == "remote" or command == "stash" then
		return (listing and not M.has_flag(rest, { "-d", "-D", "-m", "-M", "--delete" }))
			or (command == "stash" and rest[2] == "list")
	end
	return command == "config" and M.has_flag(rest, { "--get", "--list", "-l" })
end)

-- The jj commands that only look.
local JJ_LOOKS: { [string]: boolean } = {
	log = true,
	status = true,
	st = true,
	diff = true,
	show = true,
	evolog = true,
	obslog = true,
	root = true,
	help = true,
}

-- jj's commands with a second word that only look: `jj op log`.
local JJ_LOOKS_IN: { [string]: { [string]: boolean } } = {
	op = { log = true, show = true },
	file = { show = true, list = true, annotate = true },
	bookmark = { list = true },
	workspace = { list = true, root = true },
	config = { get = true, list = true },
}

M.safe_when("jj", function(words)
	local rest = subcommand(words, { ["-R"] = true, ["--repository"] = true, ["-r"] = true })
	local command = rest[1]
	if command == nil then
		return false
	end
	local inner = JJ_LOOKS_IN[command]
	return JJ_LOOKS[command] == true or (inner ~= nil and inner[rest[2] or ""] == true)
end)

-- The cargo commands that build, test or look, in the project.
local CARGO_BUILDS: { [string]: boolean } = {
	check = true,
	build = true,
	test = true,
	clippy = true,
	tree = true,
	metadata = true,
	doc = true,
	bench = true,
	version = true,
}

M.safe_when("cargo", function(words)
	local rest = subcommand(words, {})
	local command = rest[1]
	if command == "fmt" then
		return M.has_flag(rest, { "--check" })
	end
	return command ~= nil
		and CARGO_BUILDS[command] == true
		and not M.has_flag(rest, { "--fix", "--allow-dirty" })
end)

-- The go commands that build, test or look.
local GO_BUILDS: { [string]: boolean } =
	{ build = true, test = true, vet = true, list = true, env = true, version = true }

M.safe_when("go", function(words)
	local command = subcommand(words, {})[1]
	return command ~= nil and GO_BUILDS[command] == true
end)

return M
