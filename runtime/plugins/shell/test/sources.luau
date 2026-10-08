local test = require("@greed/test")
local greed = require("@greed")
local shell = require("@shell")

type Shell = typeof(shell.open())
type Item = { label: string, text: string, detail: string?, badge: string?, from: number? }

local sources = shell.sources

-- How long an ask for completions may take: it starts programs, slow while
-- every plugin's tests run at once.
local ASK_MS = 20000

local function open(t: test.TestContext, dir: string): Shell
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = dir
	return sh
end

-- What completes `text` at `sh`'s prompt, as tab (or with `explicit`
-- false, a pause in typing) asks.
local function items_for(
	t: test.TestContext,
	sh: Shell,
	text: string,
	explicit: boolean?
): { [string]: Item }
	shell.log.set_prompt(sh, text, { greed.view() })
	local found: { Item }? = nil
	greed.spawn(function()
		found = shell.completion.items(greed.view(), { explicit = explicit ~= false }) or {}
	end)
	t:wait_for(function()
		return found ~= nil
	end, ASK_MS)
	local by: { [string]: Item } = {}
	for _, item in assert(found) do
		by[item.label] = item
	end
	return by
end

local function names(items: { [string]: Item }): string
	local list: { string } = {}
	for label in items do
		table.insert(list, label)
	end
	table.sort(list)
	return table.concat(list, " ")
end

-- The PATH of `sh`'s programs.
local function path_of(t: test.TestContext, sh: Shell): string
	local block = assert(shell.run(sh, [[printf %s "$PATH"]], { runner = "pipe" }))
	t:wait_for(function()
		return block.status ~= "running"
	end)
	return block.output
end

-- Puts executable `scripts` (name to text) in a folder in front of `sh`'s
-- PATH, and returns the folder.
local function programs(t: test.TestContext, sh: Shell, scripts: { [string]: string }): string
	local files: { [string]: string } = {}
	local list: { string } = {}
	for name, text in scripts do
		files[`bin/{name}`] = text
		table.insert(list, name)
	end
	local dir = t:tempdir(files)
	local chmod = assert(
		shell.run(sh, `chmod +x {table.concat(list, " ")}`, { cwd = `{dir}/bin`, runner = "pipe" })
	)
	t:wait_for(function()
		return chmod.status ~= "running"
	end)
	sh.env.PATH = `{dir}/bin:{path_of(t, sh)}`
	return dir
end

local COBRA = [[#!/bin/sh
# Completion ended with directive: what Cobra's programs have inside.
if [ "$1" = __complete ]; then
	shift
	echo "args:$*" >> "$COBRA_LOG"
	case "$1" in
	get) printf 'pods\tPods in a namespace\nservices\tServices\n:4\n' ;;
	files) printf ':0\n' ;;
	conf) printf 'yaml\nyml\n:8\n' ;;
	dirs) printf ':16\n' ;;
	bad) printf ':1\n' ;;
	*) printf 'get\tDisplay one or many resources\nfiles\tFile things\n:4\n' ;;
	esac
	exit 0
fi
touch "$COBRA_RAN"
]]

test("a Cobra program completes itself, its directive saying what else fits", function(t)
	local work = t:tempdir({ ["sub/x"] = "", ["a.yaml"] = "", ["b.txt"] = "" })
	local sh = open(t, work)
	local dir = programs(t, sh, { greedcobra = COBRA })
	sh.env.COBRA_LOG = `{dir}/log`
	sh.env.COBRA_RAN = `{dir}/ran`
	greed.option.set("shell-completion-sources", "cobra")
	local top = items_for(t, sh, "greedcobra ")
	assert(names(top) == "files get", names(top))
	assert(top.get.detail == "Display one or many resources", tostring(top.get.detail))
	-- Its word so far goes along: everything for it comes back, to filter.
	local get = items_for(t, sh, "greedcobra get p")
	assert(names(get) == "pods services", names(get))
	local log = assert(greed.fs.read(`{dir}/log`))
	assert(string.find(log, "args:get \n", 1, true), log)
	-- No candidates and files allowed: files.
	assert(names(items_for(t, sh, "greedcobra files ")) == "a.yaml b.txt sub/")
	assert(
		names(items_for(t, sh, "greedcobra conf ")) == "a.yaml sub/",
		"files with those extensions"
	)
	assert(names(items_for(t, sh, "greedcobra dirs ")) == "sub/", "folders only")
	assert(names(items_for(t, sh, "greedcobra bad ")) == "", "an error: nothing")
	-- The same line again within a few seconds isn't asked again.
	local asked = #string.split(assert(greed.fs.read(`{dir}/log`)), "\n")
	items_for(t, sh, "greedcobra get s")
	assert(#string.split(assert(greed.fs.read(`{dir}/log`)), "\n") == asked, "kept")
	assert(greed.fs.stat(`{dir}/ran`) == nil, "only ever run with __complete")
	greed.option.set("shell-completion-sources", "cobra fish carapace man help")
end)

test("an unknown program isn't run to see whether it's Cobra's", function(t)
	local sh = open(t, t:tempdir())
	local dir = programs(t, sh, { greedplain = '#!/bin/sh\ntouch "$PLAIN_RAN"\n' })
	sh.env.PLAIN_RAN = `{dir}/ran`
	greed.option.set("shell-completion-sources", "cobra")
	items_for(t, sh, "greedplain ")
	assert(greed.fs.stat(`{dir}/ran`) == nil, "not run")
	greed.option.set("shell-completion-sources", "cobra fish carapace man help")
end)

test("a newer ask stops a program an older one is waiting on, and so does the time", function(t)
	local sh = open(t, t:tempdir())
	local first: string? = nil
	local done = false
	greed.spawn(function()
		first = sources.run("test", { "sh", "-c", "sleep 5; echo late" }, sh.cwd, {})
		done = true
	end)
	local second: string? = nil
	greed.spawn(function()
		second = sources.run("test", { "sh", "-c", "echo now" }, sh.cwd, {})
	end)
	t:wait_for(function()
		return done and second ~= nil
	end, ASK_MS)
	assert(first == "" and second == "now\n", tostring(first))
	-- A program past shell-completion-timeout is stopped.
	local slow: string? = nil
	greed.spawn(function()
		slow = sources.run("slow", { "sh", "-c", "sleep 5; echo late" }, sh.cwd, {})
	end)
	t:wait(2500)
	t:wait_for(function()
		return slow ~= nil
	end, ASK_MS)
	assert(slow == "", tostring(slow))
end)

test("fish's completions, when fish is installed", function(t)
	local sh = open(t, t:tempdir())
	if sources.find("fish", path_of(t, sh)) == nil then
		-- Skipped: fish isn't installed here.
		return
	end
	local config = t:tempdir({
		["fish/completions/greedfish.fish"] = "complete -c greedfish -f -a 'alpha beta' -d 'a word'\n",
	})
	-- fish loads completions for programs that are there.
	programs(t, sh, { greedfish = "#!/bin/sh\n" })
	sh.env.XDG_CONFIG_HOME = config
	sh.env.XDG_DATA_HOME = t:tempdir()
	sh.env.XDG_CACHE_HOME = t:tempdir()
	greed.option.set("shell-completion-sources", "fish")
	local found = items_for(t, sh, "greedfish a")
	assert(found.alpha and found.alpha.detail == "a word", names(found))
	greed.option.set("shell-completion-sources", "cobra fish carapace man help")
end)

test("carapace's completions, when carapace is installed", function(t)
	local sh = open(t, t:tempdir())
	if sources.find("carapace", path_of(t, sh)) == nil then
		-- Skipped: carapace isn't installed here.
		return
	end
	local config = t:tempdir({
		["carapace/specs/greedcara.yaml"] = 'name: greedcara\ndescription: a test\ncompletion:\n  positional:\n    - ["one", "two"]\n',
	})
	sh.env.XDG_CONFIG_HOME = config
	sh.env.XDG_DATA_HOME = t:tempdir()
	sh.env.XDG_CACHE_HOME = t:tempdir()
	greed.option.set("shell-completion-sources", "carapace")
	local found = items_for(t, sh, "greedcara ")
	assert(found.one and found.two, names(found))
	greed.option.set("shell-completion-sources", "cobra fish carapace man help")
end)

local MAN = [[
.TH GREEDMAN 1
.SH NAME
greedman \- a page to test
.SH OPTIONS
.TP
.BR \-a ", " \-\-all
Show all of them. And more.
.TP
\fB\-w\fR, \fB\-\-width\fR=\fICOLS\fR
Set the
width.
.IP "\-q" 4
Be quiet.
.SH SEE ALSO
.BR ls (1)
]]

local MDOC = [[
.Dd October 8, 2026
.Dt GREEDMDOC 1
.Sh DESCRIPTION
.Bl -tag -width Ds
.It Fl l
List in long format.
.It Fl -color Ns = Ns Ar when
Color the output.
.El
]]

test("man pages say what flags a program takes, read without running it", function(t)
	local list = shell.sources.flags.from_man(MAN)
	local by: { [string]: string? } = {}
	for _, flag in list do
		by[flag.text] = flag.detail or ""
	end
	assert(
		by["-a"] == "Show all of them." and by["--all"] == "Show all of them.",
		tostring(by["-a"])
	)
	assert(by["-w"] == "Set the width." and by["--width"] == "Set the width.", tostring(by["-w"]))
	assert(by["-q"] == "Be quiet.", tostring(by["-q"]))
	local mdoc: { [string]: string? } = {}
	for _, flag in shell.sources.flags.from_man(MDOC) do
		mdoc[flag.text] = flag.detail or ""
	end
	assert(
		mdoc["-l"] == "List in long format." and mdoc["--color"] == "Color the output.",
		tostring(mdoc["-l"])
	)

	local pages = t:tempdir({ ["man1/greedman.1"] = MAN })
	local sh = open(t, t:tempdir({ ["file.txt"] = "" }))
	sh.env.MANPATH = pages
	greed.option.set("shell-completion-sources", "man")
	local found = items_for(t, sh, "greedman --")
	assert(
		found["--all"] and found["--width"] and found["--all"].detail == "Show all of them.",
		names(found)
	)
	-- Not a flag: files.
	assert(names(items_for(t, sh, "greedman f")) == "file.txt")
	greed.option.set("shell-completion-sources", "cobra fish carapace man help")
end)

test("what programs print for --help says what flags they take, in the usual shapes", function()
	local function flags_of(text: string): { [string]: string }
		local by: { [string]: string } = {}
		for _, flag in shell.sources.flags.from_help(text) do
			by[flag.text] = flag.detail or ""
		end
		return by
	end
	local gnu = flags_of(table.concat({
		"Usage: ls [OPTION]... [FILE]...",
		"  -a, --all                  do not ignore entries starting with .",
		"  -w, --width=COLS           set output width to COLS.  0 means no limit",
		"      --color[=WHEN]         color the output WHEN",
		"",
	}, "\n"))
	assert(gnu["-a"] == "do not ignore entries starting with ." and gnu["--all"], gnu["-a"])
	assert(
		gnu["--width"] == "set output width to COLS." and gnu["--color"] == "color the output WHEN",
		gnu["--width"]
	)
	local go = flags_of("Usage of tool:\n  -flag string\n    \tthe flag's doc\n  -v\tbe verbose\n")
	assert(go["-flag"] == "the flag's doc" and go["-v"] == "be verbose", tostring(go["-flag"]))
	local clap = flags_of(table.concat({
		"Usage: tool [OPTIONS]",
		"",
		"Options:",
		"  -c, --config <FILE>  Use a config file",
		"  -v, --verbose",
		"          Print more",
		"  -h, --help           Print help",
	}, "\n"))
	assert(
		clap["--config"] == "Use a config file" and clap["--verbose"] == "Print more",
		clap["--verbose"]
	)
	local cobra = flags_of(
		"Flags:\n  -A, --all-namespaces   If present, list across namespaces\n  -o, --output string    Output format\n"
	)
	assert(
		cobra["-A"] == "If present, list across namespaces" and cobra["--output"] == "Output format"
	)
	local argparse = flags_of(table.concat({
		"usage: tool [-h] [--foo FOO]",
		"",
		"options:",
		"  -h, --help            show this help message and exit",
		"  --foo FOO             foo of the bar",
		"  --long-option-name LONG_OPTION_NAME",
		"                        a long one",
	}, "\n"))
	assert(argparse["--foo"] == "foo of the bar" and argparse["--long-option-name"] == "a long one")
	local commands = shell.sources.flags.commands(
		"Available Commands:\n  get         Display\n  logs        Print logs\n\nFlags:\n  -h, --help   help\n"
	)
	assert(commands.get == "Display" and commands.logs == "Print logs" and commands["-h"] == nil)
end)

local HELPFUL = [[#!/bin/sh
touch "$RAN"
if [ "$1" = get ]; then
	printf 'Flags:\n      --watch   Watch for changes\n'
	exit 0
fi
printf 'Usage: greedhelp [OPTIONS]\n\nAvailable Commands:\n  get   Display\n\nFlags:\n  -a, --all   Every one\n'
]]

test("--help runs only when you ask on a flag, and never when you say so", function(t)
	local sh = open(t, t:tempdir())
	local dir = programs(t, sh, { greedhelp = HELPFUL, greedrisky = HELPFUL })
	local ran = `{dir}/ran`
	sh.env.RAN = ran
	greed.option.set("shell-completion-sources", "help")
	-- A pause in typing doesn't run it.
	assert(names(items_for(t, sh, "greedhelp -", false)) == "")
	assert(greed.fs.stat(ran) == nil, "not run while typing")
	-- Nor a word that isn't a flag.
	items_for(t, sh, "greedhelp x")
	assert(greed.fs.stat(ran) == nil, "not run for a word")
	greed.option.set("shell-help-completion", "never")
	assert(names(items_for(t, sh, "greedhelp --")) == "")
	assert(greed.fs.stat(ran) == nil, "never")
	greed.option.set("shell-help-completion", "on-flag")
	greed.option.set("shell-help-never", "greedrisky")
	assert(names(items_for(t, sh, "greedrisky --")) == "")
	assert(greed.fs.stat(ran) == nil, "on the list of programs never run")
	-- Asked for on a flag, it runs, and a subcommand its help lists has
	-- its own.
	local found = items_for(t, sh, "greedhelp -")
	assert(found["--all"] and found["--all"].detail == "Every one", names(found))
	assert(greed.fs.stat(ran) ~= nil, "run when asked")
	local sub = items_for(t, sh, "greedhelp get --w")
	assert(sub["--watch"] and sub["--watch"].detail == "Watch for changes", names(sub))
	greed.option.set(
		"shell-help-never",
		"reboot shutdown halt poweroff init telinit kill killall pkill"
	)
	greed.option.set("shell-completion-sources", "cobra fish carapace man help")
end)

test("a plugin's completer comes first, and nil leaves it to the rest", function(t)
	local sh = open(t, t:tempdir({ ["notes.txt"] = "" }))
	shell.completer("greeddeploy", function(request)
		if #request.words ~= 2 then
			return nil
		end
		local list: { any } = { "prod", { text = "staging", detail = "the other one" } }
		return list
	end)
	local found = items_for(t, sh, "greeddeploy ")
	assert(names(found) == "prod staging" and found.staging.detail == "the other one", names(found))
	greed.option.set("shell-completion-sources", "")
	assert(names(items_for(t, sh, "greeddeploy prod ")) == "notes.txt", "files")
	greed.option.set("shell-completion-sources", "cobra fish carapace man help")
end)
