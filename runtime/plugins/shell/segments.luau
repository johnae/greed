-- Pieces of the prompt before the shell's folder: the branch of the
-- repository the shell is in, and those plugins add with `segment`, like
-- the kubernetes context. A segment can be a warning, like a context
-- named like production (`shell-production-contexts`), which turns the
-- prompt's glyph red.
--
-- They're worked out in the background, as some run programs, when a
-- shell opens and after each command, and kept until the next time.

local greed = require("@greed")
local core = require("@core")
local state = require("./state")
local log = require("./log")
local starship = require("./starship")

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

--- A segment's icon: one any font has, and one from a Nerd Font.
export type Icons = { plain: string, nerd: string }

local providers: { { name: string, provider: Provider } } = {}

greed.option.define({
	name = "shell-production-contexts",
	doc = "Patterns for kubernetes contexts a shell's prompt warns about, like prod; space between them",
	default = "prod",
})

greed.option.define({
	name = "shell-prompt",
	doc = 'What draws a shell\'s prompt before its ❯: "greed" (its own segments and folder) or "starship" (your starship prompt, when starship is installed)',
	default = "greed",
	choices = { "greed", "starship" },
})

greed.option.define({
	name = "shell-icons",
	doc = 'The icons of a shell\'s prompt segments: "plain" ones any font has, or "nerd" ones a Nerd Font has',
	default = "plain",
	choices = { "plain", "nerd" },
})

-- The icon of each segment that has one, plain and from a Nerd Font.
local ICONS: { [string]: Icons } = {
	git = { plain = "⎇", nerd = "\u{e0a0}" },
	environment = { plain = "❄", nerd = "\u{f313}" },
}

--- Gives segment `name` its icon: `plain` any font has, `nerd` one from a
--- Nerd Font, for `shell-icons` to pick. It goes when the plugin that gave
--- it does.
function M.add_icon(name: string, icons: Icons)
	greed.plugin.tie(core.registry.set(ICONS, name, icons))
end

--- The icon segment `name` starts with, as `shell-icons` says; "" for a
--- segment without one.
function M.icon(name: string): string
	local icons = ICONS[name]
	if icons == nil then
		return ""
	end
	return if greed.option.get("shell-icons") == "nerd" then icons.nerd else icons.plain
end

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
--- prompt with them: starship's, with `shell-prompt` set to "starship",
--- keeping the warnings the shell's own segments give.
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
			local warning = false
			for _, entry in table.clone(providers) do
				local ok, segment = pcall(entry.provider, ctx)
				if ok and segment and segment.text ~= "" then
					table.insert(found, segment)
					warning = warning or segment.warning == true
				end
			end
			local drawn = if greed.option.get("shell-prompt") == "starship"
				then starship.prompt(shell, ctx.cwd, ctx.env)
				else nil
			if drawn then
				drawn[1].folder = true
				drawn[1].warning = warning
			end
			shell.segments = drawn or found
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

-- What finds a folder's branch for the git segment, the latest added
-- last; `head_branch` when there's none.
local branch_finders: { (dir: string) -> string? } = {}

--- Has the git segment show the branch `find(dir)` gives for a shell's
--- folder (nil outside a repository) instead of the one `.git/HEAD`
--- names, as the vcs plugin does to show jj's too. It goes when the
--- plugin that gave it does.
function M.branch_finder(find: (dir: string) -> string?)
	greed.plugin.tie(core.registry.put(branch_finders, find))
	for _, shell in state.list() do
		M.refresh(shell)
	end
end

M.segment("git", function(ctx: Context): Segment?
	local find: (dir: string) -> string? = branch_finders[#branch_finders] or M.head_branch
	local branch = find(ctx.cwd)
	return if branch
		then { text = `{M.icon("git")} {branch}`, style = "shell.segment.git" }
		else nil
end)

-- Another prompt or other icons show at once.
greed.on("option.changed", function(event: greed.OptionChanged)
	if event.name == "shell-prompt" or event.name == "shell-icons" then
		for _, shell in state.list() do
			M.refresh(shell)
		end
	end
end)

return M
