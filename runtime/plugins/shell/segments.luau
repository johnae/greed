-- Pieces of the prompt before the shell's folder: the branch of the
-- repository the shell is in, and the kubernetes context and namespace
-- kubectl would use, read from its config file without running it. A
-- context named like production (`shell-production-contexts`) shows as a
-- warning and turns the prompt's glyph red. Plugins add their own with
-- `segment`.
--
-- They're worked out in the background, as some run programs, when a
-- shell opens and after each command, and kept until the next time.

local greed = require("@greed")
local core = require("@core")
local state = require("./state")
local log = require("./log")

type Shell = state.Shell

local M = {}

--- What a segment gets: the shell, its folder, and the variables its
--- programs get.
export type Context = { shell: Shell, cwd: string, env: { [string]: string } }

--- A piece of the prompt: its text, its style ("shell.segment" by
--- default), and whether it's a warning, which turns the prompt's glyph
--- red too.
export type Segment = state.Segment

--- Works out a segment for a shell, or nil to show nothing.
export type Provider = (ctx: Context) -> Segment?

local providers: { { name: string, provider: Provider } } = {}

greed.option.define({
	name = "shell-production-contexts",
	doc = "Patterns for kubernetes contexts a shell's prompt warns about, like prod; space between them",
	default = "prod",
})

--- Shows what `provider` says in the prompt of every shell, before its
--- folder, after the segments added before it; one added again with the
--- same `name` takes its place. It goes when the plugin that added it
--- does.
function M.segment(name: string, provider: Provider)
	greed.plugin.tie(
		core.registry.put(providers, { name = name, provider = provider }, function(other)
			return other.name == name
		end)
	)
	for _, shell in state.list() do
		M.refresh(shell)
	end
end

--- The segments' names, in the order they show.
function M.names(): { string }
	local names: { string } = {}
	for _, entry in providers do
		table.insert(names, entry.name)
	end
	return names
end

-- Shells whose segments are being worked out, and whether to again after.
local busy: { [Shell]: boolean } = setmetatable({}, { __mode = "k" }) :: any

--- Works out `shell`'s segments again in the background and draws its
--- prompt with them.
function M.refresh(shell: Shell)
	if busy[shell] ~= nil then
		busy[shell] = true
		return
	end
	busy[shell] = false
	greed.spawn(function()
		repeat
			busy[shell] = false
			local ctx: Context = { shell = shell, cwd = shell.cwd, env = state.variables(shell) }
			local found: { Segment } = {}
			for _, entry in table.clone(providers) do
				local ok, segment = pcall(entry.provider, ctx)
				if ok and segment and segment.text ~= "" then
					table.insert(found, segment)
				end
			end
			shell.segments = found
			if shell.buffer:valid() then
				log.draw_prompt(shell)
			end
		until not busy[shell]
		busy[shell] = nil
	end)
end

--- The branch `.git/HEAD` names in the repository `dir` is in (its commit,
--- short, when detached), read without running git; nil outside one.
function M.head_branch(dir: string): string?
	local at: string? = dir
	while at and at ~= "" do
		local git = `{at}/.git`
		local info = greed.fs.stat(git)
		if info then
			local head_dir = git
			if info.kind ~= "dir" then
				-- A worktree's .git is a file naming the real one.
				local pointer = greed.fs.read(git) or ""
				local real = string.match(pointer, "gitdir:%s*(%S+)")
				if real == nil then
					return nil
				end
				head_dir = core.project.resolve(real, at)
			end
			local head = greed.fs.read(`{head_dir}/HEAD`) or ""
			local branch = string.match(head, "^ref: refs/heads/(%S+)")
			if branch then
				return branch
			end
			local commit = string.match(head, "^(%x+)")
			return if commit then string.sub(commit, 1, 7) else nil
		end
		at = string.match(at, "^(.*)/[^/]*$")
	end
	return nil
end

--- The kubeconfig files kubectl would read for `ctx`'s shell: those
--- KUBECONFIG names, else `~/.kube/config`. KUBECONFIG from the editor
--- counts only when Greed's home is the editor's, so a test's own home
--- never reads yours.
function M.kubeconfigs(ctx: Context): { string }
	local home = greed.fs.dirs().home
	local own = ctx.shell.env.KUBECONFIG
	local inherited = state.editor_environment()
	local list = if type(own) == "string"
		then own
		elseif own == nil and home == inherited.HOME then inherited.KUBECONFIG
		else nil
	local files: { string } = {}
	if list and list ~= "" then
		for path in string.gmatch(list, "[^:]+") do
			table.insert(files, path)
		end
	elseif home then
		table.insert(files, `{home}/.kube/config`)
	end
	return files
end

-- A YAML scalar without the quotes around it.
local function scalar(text: string): string
	local trimmed = string.match(text, "^%s*(.-)%s*$") or ""
	return string.match(trimmed, '^"(.*)"$') or string.match(trimmed, "^'(.*)'$") or trimmed
end

--- The context `yaml`, a kubeconfig, says is current, and its namespace
--- (nil when it sets none).
function M.read_kubeconfig(yaml: string): (string?, string?)
	local lines = string.split(string.gsub(yaml, "\r", ""), "\n")
	local current: string? = nil
	for _, line in lines do
		local value = string.match(line, "^current%-context:(.*)$")
		if value then
			current = scalar(value)
		end
	end
	if current == nil or current == "" then
		return nil, nil
	end
	-- The contexts: a list of items each with a name and a context map,
	-- under the top-level `contexts:`.
	local inside = false
	local name: string?, namespace: string? = nil, nil
	local found: string? = nil
	local function close()
		if name == current then
			found = namespace
		end
		name, namespace = nil, nil
	end
	for _, line in lines do
		-- A top-level key; a list's items may start at the line's start too.
		if string.match(line, "^[^%s%-]") then
			if inside then
				close()
			end
			inside = string.match(line, "^contexts:") ~= nil
		elseif inside then
			if string.match(line, "^%s*%- ") then
				close()
			end
			local item = string.gsub(line, "^(%s*)%- ", "%1  ")
			local key, value = string.match(item, "^%s*([%w_-]+):(.*)$")
			if key == "name" and value then
				name = scalar(value)
			elseif key == "namespace" and value then
				namespace = scalar(value)
			end
		end
	end
	if inside then
		close()
	end
	local ns = found
	return current, if ns and ns ~= "" then ns else nil
end

--- Whether `context` is a production one: it matches a pattern of
--- `shell-production-contexts`.
function M.production(context: string): boolean
	for pattern in string.gmatch(greed.option.get("shell-production-contexts") :: string, "[^%s,]+") do
		local ok, found = pcall(function(): boolean
			return string.find(context, pattern) ~= nil
		end)
		if ok and found then
			return true
		end
	end
	return false
end

M.segment("git", function(ctx: Context): Segment?
	local branch = if table.find(greed.plugin.list(), "vcs")
		then require("@vcs").branch(ctx.cwd)
		else M.head_branch(ctx.cwd)
	return if branch then { text = `⎇ {branch}` } else nil
end)

M.segment("kubernetes", function(ctx: Context): Segment?
	for _, path in M.kubeconfigs(ctx) do
		local context, namespace = M.read_kubeconfig(greed.fs.read(path) or "")
		if context then
			local warn = M.production(context)
			return {
				text = if namespace then `⎈ {context}:{namespace}` else `⎈ {context}`,
				style = if warn then "shell.segment.warning" else "shell.segment",
				warning = warn,
			}
		end
	end
	return nil
end)

return M
