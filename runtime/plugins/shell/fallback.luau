-- Lines the shell doesn't read itself (pipes, globs, variables, a shell's
-- own syntax) run in a real shell: your `$SHELL` when it's one of a family
-- the shell knows, else `sh`, or what `shell-fallback` names. A small
-- wrapper around the line writes the folder and the environment it left
-- behind to files, so `cd` and `export` in it carry over to the next
-- command as they would in a terminal.
--
-- sh, bash, zsh, dash and ksh share a POSIX wrapper that `eval`s the line;
-- fish has its own. nu can't evaluate a string, so its wrapper is written
-- around the line. Any other shell runs the line as it is, and its block
-- says that `cd` and `export` in it don't carry over.

local greed = require("@greed")
local parse = require("./parse")
local state = require("./state")

type Block = state.Block

local M = {}

greed.option.define({
	name = "shell-fallback",
	needs = "proc",
	doc = 'The shell that runs lines with pipes, globs and the like, e.g. "bash"; empty for your $SHELL (sh unless it\'s sh, bash, zsh, dash, ksh, fish or nu)',
	default = "",
})

greed.option.define({
	name = "shell-fallback-rc",
	needs = "proc",
	doc = "Whether the shell running those lines reads its startup files (-i), for your aliases and functions",
	default = false,
})

-- Runs the line (`$1`), then writes where it left the shell and what its
-- environment is to the folder `$2`, and exits as the line did. The
-- environment comes from `greed --env0` (`$GREED_BIN`, which state.luau
-- sets), the same on every system; without it, from `env -0`. The line
-- runs on the wrapper's first line, so the line numbers in its errors are
-- its own: "bash: line 1: nope: command not found", as in a terminal.
local POSIX = [[
__greed_line=$1; __greed_dir=$2; shift 2; __greed_env() { if [ -n "${GREED_BIN:-}" ]; then "$GREED_BIN" --env0; else env -0; fi; }; __greed_env > "$__greed_dir/before"; eval "$__greed_line"
__greed_status=$?
pwd > "$__greed_dir/cwd"
__greed_env > "$__greed_dir/after"
exit "$__greed_status"]]

local FISH = [[
set -l __greed_line $argv[1]
set -l __greed_dir $argv[2]
function __greed_env
	if test -n "$GREED_BIN"
		$GREED_BIN --env0
	else
		env -0
	end
end
__greed_env > $__greed_dir/before
eval $__greed_line
set -l __greed_status $status
pwd > $__greed_dir/cwd
__greed_env > $__greed_dir/after
exit $__greed_status]]

-- nu runs the line inside a command that keeps its environment changes,
-- and prints what it gives back. An external program's exit code is lost
-- once its output is printed, so only errors make a nu line fail. A table
-- it gives back is also saved as JSON (its first 10000 rows, so a stream
-- that doesn't end can't fill memory), and printed with its row numbers,
-- which say which row each line of the drawn table is.
local NU = [[
def __greed_env [] {
	if ($env.GREED_BIN? | is-not-empty) { ^$env.GREED_BIN --env0 } else { ^env -0 }
}
def __greed_keep [] {
	let value = $in
	if (($value | describe) starts-with "table") { $value | to json -r | save -f r#'DIR/value'# }
}
__greed_env | save -f --raw r#'DIR/before'#
$env.config.table.index_mode = "always"
def --env __greed_run [] {
LINE
}
let __greed_code = try {
	__greed_run | tee { try { first 10000 | __greed_keep } } | print
	$env.LAST_EXIT_CODE? | default 0 | into int
} catch {|e|
	let code = ($env.LAST_EXIT_CODE? | default 0 | into int)
	if $code != 0 { $code } else { print -e $e.msg; 1 }
}
$env.PWD | save -f r#'DIR/cwd'#
__greed_env | save -f --raw r#'DIR/after'#
exit $__greed_code]]

-- Picks the shell: `$5` when given, else `$SHELL`, which is `sh` when it
-- isn't of a family the shell knows. Says which in `$2/shell`, and runs
-- the line `$1` in it with the right wrapper; `$3` is 1 to read its startup
-- files, `$4` the nu script.
local DISPATCH = [[
greed_line=$1
greed_dir=$2
greed_rc=$3
greed_nu=$4
greed_program=${5:-${SHELL:-sh}}
case ${greed_program##*/} in
sh | bash | zsh | dash | ksh | mksh | ash | yash | posh) greed_family=posix ;;
fish) greed_family=fish ;;
nu) greed_family=nu ;;
*) greed_family=other ;;
esac
if [ "$greed_family" = other ] && [ -z "$5" ]; then
	greed_program=sh
	greed_family=posix
fi
printf '%s\n%s\n' "$greed_family" "$greed_program" > "$greed_dir/shell"
case $greed_family in
posix)
	if [ "$greed_rc" = 1 ]; then
		exec "$greed_program" -i -c POSIX "${greed_program##*/}" "$greed_line" "$greed_dir"
	fi
	exec "$greed_program" -c POSIX "${greed_program##*/}" "$greed_line" "$greed_dir"
	;;
fish)
	if [ "$greed_rc" = 1 ]; then
		exec "$greed_program" -c FISH "$greed_line" "$greed_dir"
	fi
	exec "$greed_program" --no-config -c FISH "$greed_line" "$greed_dir"
	;;
nu)
	if [ "$greed_rc" = 1 ]; then
		exec "$greed_program" -c "$greed_nu"
	fi
	exec "$greed_program" --no-config-file -c "$greed_nu"
	;;
*)
	exec "$greed_program" -c "$greed_line"
	;;
esac]]

local script = string.gsub(DISPATCH, "POSIX", function()
	return parse.quote(POSIX)
end)
script = string.gsub(script, "FISH", function()
	return parse.quote(FISH)
end)

-- The shells of each family the wrappers know, by their program's name.
local FAMILY: { [string]: string } = {
	sh = "posix",
	bash = "posix",
	zsh = "posix",
	dash = "posix",
	ksh = "posix",
	mksh = "posix",
	ash = "posix",
	yash = "posix",
	posh = "posix",
	fish = "fish",
	nu = "nu",
}

--- The shell your lines run in, as DISPATCH picks it, and whether cd
--- and export in it carry over: `shell-fallback` when set, else `$SHELL`
--- when it's of a family the wrappers know, else `sh`. Asks the editor's
--- environment, so only where that can wait.
function M.which(): (string, boolean)
	local function basename(path: string): string
		return string.match(path, "([^/]+)$") or path
	end
	local chosen = greed.option.get("shell-fallback") :: string
	if chosen ~= "" then
		local name = basename(chosen)
		return name, FAMILY[name] ~= nil
	end
	local name = basename(state.editor_environment().SHELL or "")
	if FAMILY[name] then
		return name, true
	end
	return "sh", true
end

-- Variables every shell sets for itself, which don't count as changes.
local OWN: { [string]: boolean } =
	{ _ = true, PWD = true, OLDPWD = true, SHLVL = true, LAST_EXIT_CODE = true }

-- A tag keeping this editor's run folders apart from those of others sharing
-- the cache folder (two sessions, say), whose blocks are numbered from 1 too.
local INSTANCE = string.format("%06x%06x", math.random(0, 0xffffff), math.random(0, 0xffffff))

--- A run of a line in a real shell: the program to start, and the folder
--- its wrapper writes to.
export type Run = {
	argv: { string },
	dir: string?,
}

--- How to run `line` for `block` in a real shell, through its wrapper:
--- `program` (default: the `shell-fallback` option, else `$SHELL`), with
--- its startup files when `rc` and the `shell-fallback-rc` option say so.
--- Without a cache folder to write to, the line runs in `sh` as it is.
function M.prepare(block: Block, line: string, opts: { program: string?, rc: boolean }): Run
	local cache = greed.fs.dirs().cache
	if cache == nil then
		block.note = "cd and export here don't carry over"
		return { argv = { "sh", "-c", line } }
	end
	local dir = `{cache}/shell/run/{INSTANCE}-{block.uid}`
	greed.fs.remove(dir, { recursive = true })
	greed.fs.mkdir(dir)
	local nu = string.gsub(NU, "DIR", function()
		return dir
	end)
	nu = string.gsub(nu, "LINE", function()
		return line
	end)
	local rc = if opts.rc and greed.option.get("shell-fallback-rc") then "1" else "0"
	local chosen = opts.program or (greed.option.get("shell-fallback") :: string)
	return {
		argv = { "sh", "-c", script, "greed-shell", line, dir, rc, nu, chosen },
		dir = dir,
	}
end

-- The variables in `text`, as `greed --env0` or `env -0` printed them.
local function variables(text: string?): { [string]: string }?
	if text == nil then
		return nil
	end
	local vars: { [string]: string } = {}
	for _, entry in string.split(text, "\0") do
		local name, value = string.match(entry, "^([^=]+)=(.*)$")
		if name and value and not OWN[name] then
			vars[name] = value
		end
	end
	return vars
end

--- What `run` left behind once it's done: the shell it ran in, the folder
--- it ended in (`block.cwd_after`, when it moved) and the variables it set
--- or took away (`block.env_changed`). Returns those, then clears up.
function M.collect(block: Block, run: Run): (string?, { [string]: string | false }?)
	local dir = run.dir
	if dir == nil then
		return nil, nil
	end
	local which = greed.fs.read(`{dir}/shell`)
	local family, program = string.match(which or "", "^(%S+)\n(.-)\n")
	if program then
		block.program = string.match(program, "([^/]+)$") or program
	end
	if family == "other" then
		block.note = `cd and export in {block.program} don't carry over`
	end
	local cwd = greed.fs.read(`{dir}/cwd`)
	local moved = if cwd then string.match(cwd, "^(.-)\n?$") else nil
	local changed = M.changes(dir)
	local saved = greed.fs.read(`{dir}/value`)
	if saved then
		local ok, value = pcall(greed.json.decode, saved)
		block.data = if ok then value else nil
	end
	greed.fs.remove(dir, { recursive = true })
	if moved and moved ~= "" and moved ~= block.cwd then
		block.cwd_after = moved
	end
	if changed == nil or next(changed) == nil then
		return block.cwd_after, nil
	end
	block.env_changed = changed
	return block.cwd_after, changed
end

--- The variables set (a string) or taken away (false) between the files
--- `before` and `after` in `dir`, each as `greed --env0` printed them; nil
--- without both.
function M.changes(dir: string): { [string]: string | false }?
	local before = variables((greed.fs.read(`{dir}/before`)))
	local after = variables((greed.fs.read(`{dir}/after`)))
	if before == nil or after == nil then
		return nil
	end
	local changed: { [string]: string | false } = {}
	for name, value in after do
		if before[name] ~= value then
			changed[name] = value
		end
	end
	for name in before do
		if after[name] == nil then
			changed[name] = false
		end
	end
	return changed
end

return M
