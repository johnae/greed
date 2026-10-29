-- Shell integration without setup: a terminal starting bash, zsh or fish
-- points it at Greed's own scripts (in `shells/` beside this file)
-- through its environment, as Ghostty does, and those load your config as
-- the shell would, then add the marks Greed reads (OSC 133 around prompts,
-- commands and output, OSC 7 for the folder). Nothing of yours is written,
-- so it works on read-only and immutable systems; the scripts are only
-- read, from wherever the runtime is. nushell sends the marks itself, and
-- other shells, or a shell given a command or script to run, start as they
-- are.

local greed = require("@greed")

local M = {}

greed.option.define({
	name = "terminal-shell-integration",
	doc = "Whether a terminal's bash, zsh or fish gets the marks around prompts, commands and output and the folder it's in, with nothing to set up",
	default = true,
})

-- The folder of the integration scripts, in the runtime.
local function folder(): string?
	local own = greed.plugin.dirs().terminal
	return if own then `{own}/shells` else nil
end

-- Variable `name` as the terminal will get it: from `env` when that sets
-- or leaves it out, else the editor's own.
local function inherited(env: { [string]: string | false }, name: string): string?
	local set = env[name]
	if type(set) == "string" then
		return set
	elseif set == false then
		return nil
	end
	return greed.process.env(name)
end

-- Whether `program` is macOS's own bash, 3.2, whose POSIX mode skips ENV.
local function apples_bash(program: string): boolean
	return program == "/bin/bash" and greed.fs.stat("/System/Library/CoreServices") ~= nil
end

--- What to start for `command` (nil for your shell, as a login shell),
--- with integration: the command, changed for bash, zsh or fish, and
--- what it needs set in `env`, which this adds to. Anything else comes
--- back as it was, and so does everything with
--- `terminal-shell-integration` off.
function M.wrap(command: { string }?, env: { [string]: string | false }): { string }?
	local dir = folder()
	if dir == nil or not greed.option.get("terminal-shell-integration") then
		return command
	end
	local program: string
	local login = command == nil
	if command then
		program = command[1]
		-- Only a shell started to type into: a command or a script to run
		-- goes as it is.
		for i = 2, #command do
			local arg = command[i]
			if arg == "-l" or arg == "--login" then
				login = true
			elseif arg ~= "-i" and arg ~= "--interactive" then
				return command
			end
		end
	else
		program = inherited(env, "SHELL") or "sh"
	end
	local name = string.match(program, "([^/]+)$") or program
	if name == "zsh" then
		local had = inherited(env, "ZDOTDIR")
		env.ZDOTDIR = `{dir}/zsh`
		env.GREED_ZSH_ZDOTDIR = had or false
		return if login then { program, "-l" } else { program }
	elseif name == "fish" then
		local had = inherited(env, "XDG_DATA_DIRS")
		env.XDG_DATA_DIRS = `{dir}:{had or "/usr/local/share:/usr/share"}`
		env.GREED_SHELL_INTEGRATION_XDG_DIR = dir
		env.GREED_XDG_DATA_DIRS_UNSET = if had then false else "1"
		return if login then { program, "-l" } else { program }
	elseif name == "bash" and not apples_bash(program) then
		env.GREED_BASH_ENV = inherited(env, "ENV") or false
		env.ENV = `{dir}/bash/greed.bash`
		if inherited(env, "HISTFILE") == nil then
			local home = inherited(env, "HOME") or greed.fs.dirs().home
			if home then
				env.HISTFILE = `{home}/.bash_history`
				env.GREED_BASH_UNEXPORT_HISTFILE = "1"
			end
		end
		env.GREED_BASH_LOGIN = if login then "1" else false
		return { program, "--posix" }
	end
	return command
end

return M
