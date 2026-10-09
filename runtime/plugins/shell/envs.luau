-- Environments a folder brings with it, as devenv and direnv give them: a
-- shell in such a folder runs its commands with them, loads them again
-- when the files they come from change, and drops them on leaving. The
-- prompt says which is loaded, and `env` says more.
--
-- A provider says which folder's environment applies where a shell is
-- (`root`) and loads it (`load`). They're asked in the order
-- `shell-environments` names them; the first with an answer wins. Loaded
-- environments are kept by provider and folder, so every shell in a
-- project shares one load.

local greed = require("@greed")
local core = require("@core")
local state = require("./state")
local log = require("./log")
local fallback = require("./fallback")
local sources = require("./sources")
local segments = require("./segments")

type Shell = state.Shell
type Block = state.Block
type Environment = state.Environment

local M = {}

--- What loading an environment gives: the variables it sets (a string) or
--- takes away (false), the files whose change means loading it again,
--- and what it printed.
export type Loaded = { vars: { [string]: string | false }, watch: { string }, output: string }

export type Provider = {
	--- The folder whose environment applies in `dir`, given the shell's
	--- variables `env`; or nil, with why when there's one it won't load,
	--- like one not allowed yet. It runs often, so it should be quick.
	root: (dir: string, env: { [string]: string }) -> (string?, string?),
	--- Loads the environment of `root`, starting from the editor's
	--- variables with `env` on top. Fails saying why.
	load: (root: string, env: { [string]: string | false }) -> Loaded,
}

greed.option.define({
	name = "shell-environments",
	needs = "proc",
	doc = "Which environments a shell loads in folders that bring one, in order, the first that applies winning: devenv, direnv, and those plugins add; empty for none",
	default = "devenv direnv",
})

local providers: { [string]: Provider } = {}

--- Adds an environment provider called `name`, for `shell-environments`
--- to name. It goes when the plugin that added it does.
function M.provider(name: string, provider: Provider)
	greed.plugin.tie(core.registry.set(providers, name, provider))
end

-- Loaded environments, by provider and folder.
local loaded: { [string]: Environment } = {}

-- The environments watching each file, by path.
local watching: { [string]: { [Environment]: boolean } } = {}

-- The provider and folder whose environment applies in `dir`, or why the
-- first that has one won't load it.
local function find(dir: string, env: { [string]: string }): (string?, string?, string?)
	local names = tostring(greed.option.get("shell-environments") or "")
	for name in string.gmatch(names, "[%w_%-]+") do
		local provider = providers[name]
		if provider then
			local ok, root, why = pcall(provider.root, dir, env)
			if ok and root then
				return name, root, nil
			elseif ok and why then
				return nil, nil, `{name}: {why}`
			end
		end
	end
	return nil, nil, nil
end

-- Loads `entry` in the background, waking what waits for it when done.
local function load(entry: Environment, env: { [string]: string | false })
	local provider = providers[entry.provider]
	local started = greed.now()
	greed.spawn(function()
		local ok, result = pcall(provider.load, entry.root, env)
		entry.seconds = (greed.now() - started) / 1000
		if ok then
			local got = result :: Loaded
			entry.status = "loaded"
			entry.vars = got.vars
			entry.output = got.output
			entry.error = nil
			entry.watch = got.watch
			for _, path in got.watch do
				local set = watching[path] or {}
				watching[path] = set
				if next(set) == nil then
					greed.fs.watch(path)
				end
				set[entry] = true
			end
		else
			entry.status = "failed"
			entry.error = tostring(result)
		end
		for _, waiter in entry.waiters do
			waiter:send(true)
		end
		entry.waiters = {}
	end)
end

-- The environment of `root` from `provider`: as loaded, or loading now
-- when it isn't yet or what it came from changed.
local function ensure(
	provider: string,
	root: string,
	env: { [string]: string | false }
): Environment
	local key = `{provider}\0{root}`
	local entry = loaded[key]
	if entry and (entry.status == "loading" or (entry.status == "loaded" and not entry.stale)) then
		return entry
	end
	if entry then
		for _, path in entry.watch do
			(watching[path] or {})[entry] = nil
		end
	end
	local fresh: Environment = {
		provider = provider,
		root = root,
		status = "loading",
		vars = if entry then entry.vars else {},
		output = "",
		error = nil,
		seconds = nil,
		watch = {},
		stale = false,
		waiters = {},
	}
	loaded[key] = fresh
	load(fresh, env)
	return fresh
end

-- The variables a shell's commands start from, to load an environment
-- with: its own, and where greed is, to print what it leaves behind.
local function base(shell: Shell): { [string]: string | false }
	local env = table.clone(shell.env)
	env.GREED_BIN = state.program() or false
	return env
end

-- A signal sent once `entry`, loading now, has loaded: one for each
-- waiter, as a signal wakes only one.
local function loading(entry: Environment): greed.Signal
	local signal = greed.signal()
	table.insert(entry.waiters, signal)
	return signal
end

-- Whether `dir` is `root` or in it.
local function inside(dir: string, root: string): boolean
	return dir == root or string.sub(dir, 1, #root + 1) == root .. "/"
end

--- Works out the environment where `shell` is, loading it if it needs
--- to, and redraws its prompt; drops the one it had on leaving its folder.
--- Waits for the load, so only in a command, handler or greed.spawn.
function M.refresh(shell: Shell)
	local vars = state.variables(shell)
	local provider, root, why = find(shell.cwd, vars)
	shell.unloaded = why
	if provider == nil or root == nil then
		shell.environment = nil
		shell.provided = {}
		segments.refresh(shell)
		return
	end
	local entry = ensure(provider, root, base(shell))
	shell.environment = entry
	segments.refresh(shell)
	if entry.status == "loading" then
		loading(entry):wait()
	end
	if shell.environment == entry then
		shell.provided = if entry.status == "loaded" then entry.vars else {}
		segments.refresh(shell)
	end
end

--- Gives `block` the variables of the environment where it runs, waiting
--- for it to load first, where that can wait; interrupting the block
--- while it waits runs it without.
function M.prepare(shell: Shell, block: Block)
	if not coroutine.isyieldable() then
		block.provided = shell.provided
		return
	end
	local entry = shell.environment
	if entry == nil or not inside(block.cwd, entry.root) then
		local provider, root = find(block.cwd, state.variables(shell))
		entry = if provider and root then ensure(provider, root, base(shell)) else nil
	end
	if entry == nil then
		return
	end
	if entry.status == "loading" then
		local pending: Environment = entry
		local waited = greed.signal()
		local function stop()
			waited:send(false)
		end
		block.note = `waiting for {entry.provider}`
		block.job = { interrupt = stop, kill = stop }
		log.draw_block(shell, block)
		greed.spawn(function()
			waited:send(loading(pending):wait())
		end)
		local loaded_in_time = waited:wait()
		block.note = nil
		block.job = nil
		if not loaded_in_time then
			return
		end
	end
	if entry.status == "loaded" then
		block.provided = entry.vars
	end
end

--- Loads the environment where `shell` is again, as if what it came from
--- changed.
function M.reload(shell: Shell)
	local entry = shell.environment
	if entry then
		entry.stale = true
	end
	M.refresh(shell)
end

--- What `env` says about the environment where `shell` is, a line each.
function M.describe(shell: Shell): { string }
	local entry = shell.environment
	if entry == nil then
		return if shell.unloaded then { shell.unloaded } else {}
	end
	local root = core.project.tilde(entry.root)
	if entry.status == "loading" then
		return { `{entry.provider} for {root}: loading` }
	elseif entry.status == "failed" then
		local lines = { `{entry.provider} for {root}: failed - env reload tries again` }
		for _, line in string.split(entry.error or "", "\n") do
			table.insert(lines, `  {line}`)
		end
		return lines
	end
	local count = 0
	for _ in entry.vars do
		count += 1
	end
	local took = if entry.seconds then string.format(" in %.1fs", entry.seconds) else ""
	local plural = if count == 1 then "" else "s"
	return { `{entry.provider} for {root}: {count} variable{plural}, loaded{took}` }
end

greed.on("file.changed", function(event: greed.FileChanged)
	local set = watching[event.path]
	if set == nil then
		return
	end
	for entry in set do
		entry.stale = true
	end
	for _, shell in state.list() do
		if shell.environment and set[shell.environment] then
			greed.spawn(function()
				M.refresh(shell)
			end)
		end
	end
end)

-- The prompt says which environment is loaded, while it loads, or that it
-- failed or isn't allowed.
segments.segment("environment", function(ctx: segments.Context): state.Segment?
	local entry = ctx.shell.environment
	local icon = segments.icon("environment")
	local style = "shell.segment.environment"
	if entry == nil then
		local unloaded = ctx.shell.unloaded
		return if unloaded then { text = `{icon} {unloaded}`, style = style } else nil
	end
	if entry.status == "loading" then
		return { text = `{icon} {entry.provider}…`, style = style }
	elseif entry.status == "failed" then
		return { text = `{icon} {entry.provider} failed`, style = "shell.failed" }
	end
	return { text = `{icon} {entry.provider}`, style = style }
end)

-- devenv: the nearest folder up with a devenv.nix, when `devenv allow`
-- let it, loaded as devenv's own direnv support does it. The environment
-- comes from `devenv direnv-export`, which runs devenv's enterShell too,
-- and the wrapper writes the variables before and after.

-- The files devenv reads, whose change means loading it again.
local DEVENV_FILES =
	{ "devenv.nix", "devenv.yaml", "devenv.lock", "devenv.local.nix", "devenv.local.yaml" }

-- Loads devenv's environment in bash as devenv's direnvrc does, keeping
-- the temporary folders and putting its PATH and XDG_DATA_DIRS before the
-- ones it had, then writes the variables before and after to `$1`.
local DEVENV_SCRIPT = [==[
__greed_dir=$1
__greed_env() { if [ -n "${GREED_BIN:-}" ]; then "$GREED_BIN" --env0; else env -0; fi; }
__greed_env > "$__greed_dir/before"
__greed_export=$(_DEVENV_CALLER=direnv devenv direnv-export) || exit $?
__greed_keep() { if [ "$2" = __unset__ ]; then unset "$1"; else export "$1=$2"; fi; }
__greed_join() {
	local IFS=: out= dir
	for dir in $1; do
		dir=${dir%/}
		case ":$out:" in *":$dir:"*) ;; *) out=$out${out:+:}$dir ;; esac
	done
	printf '%s' "$out"
}
__greed_tmp=${TMP-__unset__} __greed_tmpdir=${TMPDIR-__unset__}
__greed_temp=${TEMP-__unset__} __greed_tempdir=${TEMPDIR-__unset__}
__greed_top=${NIX_BUILD_TOP-__unset__}
__greed_path=${PATH-} __greed_xdg=${XDG_DATA_DIRS-}
eval "$__greed_export"
if [[ -n "${NIX_BUILD_TOP+x}" && "$NIX_BUILD_TOP" == */nix-shell.* && -d "$NIX_BUILD_TOP" ]]; then
	rm -rf "$NIX_BUILD_TOP"
fi
__greed_keep NIX_BUILD_TOP "$__greed_top"
__greed_keep TMP "$__greed_tmp"
__greed_keep TMPDIR "$__greed_tmpdir"
__greed_keep TEMP "$__greed_temp"
__greed_keep TEMPDIR "$__greed_tempdir"
export PATH=$(__greed_join "${PATH-}${__greed_path:+:$__greed_path}")
export XDG_DATA_DIRS=$(__greed_join "${XDG_DATA_DIRS-}${__greed_xdg:+:$__greed_xdg}")
__greed_env > "$__greed_dir/after"]==]

-- The nearest folder from `dir` up holding `file`.
local function nearest(dir: string, file: string): string?
	local at: string? = dir
	while at and at ~= "" do
		if greed.fs.stat(`{at}/{file}`) then
			return at
		end
		at = string.match(at, "^(.*)/[^/]*$")
	end
	return if greed.fs.stat(`/{file}`) then "/" else nil
end

-- Runs `argv` in `cwd` with `env` on top of the editor's, its input
-- closed, and gives back its exit code, what it printed and its errors.
local function run(
	argv: { string },
	cwd: string,
	env: { [string]: string | false }
): (number?, string, string)
	local child, err = greed.process.spawn(argv, { cwd = cwd, env = env })
	if child == nil then
		error(err or `can't start {argv[1]}`, 0)
	end
	local c = child :: greed.Child
	c:close()
	local parts: { string } = {}
	while true do
		local piece = c:read()
		if piece == nil then
			break
		end
		table.insert(parts, piece)
	end
	return c:wait(), table.concat(parts), c:stderr()
end

-- devenv and direnv keep what you allowed in your home, so they load only
-- there: a test's own home never loads your projects.
local function yours(): boolean
	return greed.fs.dirs().home == state.editor_environment().HOME
end

M.provider("devenv", {
	root = function(dir: string, env: { [string]: string }): (string?, string?)
		if not yours() then
			return nil, nil
		end
		local found = nearest(dir, "devenv.nix")
		if found == nil then
			return nil, nil
		end
		local devenv = sources.find("devenv", env.PATH)
		if devenv == nil then
			return nil, "not installed"
		end
		local result = greed.process.run({ devenv, "hook-should-activate" }, { cwd = dir })
		if result == nil then
			return nil, nil
		end
		local root = string.match(result.stdout, "^%s*(.-)%s*$")
		if result.code == 0 and root and root ~= "" then
			return root, nil
		end
		return nil, if result.code == 0 then nil else "not allowed, devenv allow"
	end,
	load = function(root: string, env: { [string]: string | false }): Loaded
		local cache = greed.fs.dirs().cache
		if cache == nil then
			error("there's no cache folder to load it in", 0)
		end
		local dir = `{cache}/shell/env/{state.new_uid()}`
		greed.fs.mkdir(dir)
		local code, out, errors = run({ "bash", "-c", DEVENV_SCRIPT, "greed-env", dir }, root, env)
		local output = out .. errors
		local vars = fallback.changes(dir)
		greed.fs.remove(dir, { recursive = true })
		if code ~= 0 or vars == nil then
			error(if output ~= "" then output else `devenv exited with {code}`, 0)
		end
		local watch: { string } = {}
		for _, name in DEVENV_FILES do
			table.insert(watch, `{root}/{name}`)
		end
		local dotfile = vars.DEVENV_DOTFILE
		local inputs = if type(dotfile) == "string"
			then greed.fs.read(`{dotfile}/input-paths.txt`)
			else nil
		for _, path in string.split(inputs or "", "\n") do
			if path ~= "" and string.sub(path, 1, 11) ~= "/nix/store/" then
				table.insert(watch, path)
			end
		end
		return { vars = vars, watch = watch, output = output }
	end,
})

-- direnv: the nearest folder up with an .envrc, once `direnv allow` let
-- it, loaded with `direnv export json`. It's asked as if nothing was
-- loaded, so it gives the whole environment rather than a change to the
-- one the editor started in.

-- The variables where direnv keeps what it loaded.
local DIRENV_STATE = { "DIRENV_DIR", "DIRENV_FILE", "DIRENV_DIFF", "DIRENV_WATCHES" }

-- `env` without what direnv loaded.
local function unloaded(env: { [string]: string | false }): { [string]: string | false }
	local clean = table.clone(env)
	for _, name in DIRENV_STATE do
		clean[name] = false
	end
	return clean
end

-- direnv's program, on `path` or else the editor's PATH.
local function direnv(path: (string | false)?): string?
	return sources.find(
		"direnv",
		if type(path) == "string" then path else state.editor_environment().PATH
	)
end

--- What `direnv export json` printed, as variables: `null` is one it
--- takes away, which decoding would lose, so it's read as false.
function M.direnv_vars(text: string): { [string]: string | false }
	local marked = string.gsub(text, '("[^"\\]*"%s*:%s*)null', "%1false")
	local decoded = greed.json.decode(marked)
	local vars: { [string]: string | false } = {}
	if type(decoded) == "table" then
		for name, value in decoded do
			if type(name) == "string" and (type(value) == "string" or value == false) then
				vars[name] = value
			end
		end
	end
	return vars
end

M.provider("direnv", {
	root = function(dir: string, env: { [string]: string }): (string?, string?)
		if not yours() or nearest(dir, ".envrc") == nil then
			return nil, nil
		end
		local program = direnv(env.PATH)
		if program == nil then
			return nil, "not installed"
		end
		local _, out = run({ program, "status", "--json" }, dir, unloaded({}))
		local status = greed.json.decode(out)
		local found = type(status) == "table"
			and type(status.state) == "table"
			and status.state.foundRC
		if type(found) ~= "table" or type(found.path) ~= "string" then
			return nil, nil
		end
		if found.allowed ~= 0 then
			return nil, if found.allowed == 2 then "denied" else "not allowed, direnv allow"
		end
		return string.match(found.path, "^(.*)/[^/]*$"), nil
	end,
	load = function(root: string, env: { [string]: string | false }): Loaded
		local program = direnv(env.PATH)
		if program == nil then
			error("direnv isn't installed", 0)
		end
		local code, out, errors = run({ program, "export", "json" }, root, unloaded(env))
		if code ~= 0 then
			error(if errors ~= "" then errors else `direnv exited with {code}`, 0)
		end
		return {
			vars = M.direnv_vars(out),
			watch = { `{root}/.envrc`, `{root}/.env` },
			output = errors,
		}
	end,
})

return M
