-- Setting Greed up: the first time you start it without a config, a page
-- asks how you like to edit, which theme, whether your font has icons,
-- whether you use Claude Code and which language model to use. The page
-- is setup.md, a questionnaire in Markdown (see the markdown and blocks
-- plugins): a style or theme picked switches at once, and Save writes a
-- config from the answers and opens it, and has the model's roles use the
-- provider picked. `:setup` brings the page back any time.
--
-- tab and shift-tab go from choice to choice and button to button, enter
-- (or space) or a click picks one or presses it, and esc or q closes it as
-- "Not now".

local greed = require("@greed")
local core = require("@core")
local markdown = require("@markdown")
local blocks = require("@blocks")
local models = require("@models")
local theme = require("@theme")
local types = require("@self/types")

local M = {}

type Page = { buffer: greed.Buffer, view: greed.View }

-- The setup page, if it's open.
local page: Page? = nil

-- Whether the page shows in a window, which draws icons whatever its font.
local function in_window(): boolean
	return greed.client.current().kind == "gui"
end

--- The icons question's choices: a terminal is asked whether it shows
--- them, with samples; a window has them built in.
function M.icon_choices(): { string }
	if in_window() then
		return { "(x) yes: the window has them built in" }
	end
	local nerd = greed.option.get("tree-icons") == "nerd"
	return {
		`{if nerd then "(x) " else ""}yes: they show here:  󰉋        `,
		`{if nerd then "" else "(x) "}no: or they're boxes (your terminal's font needs Nerd Font icons)`,
	}
end

local PROVIDERS = {
	{ value = "anthropic", text = "Anthropic (Claude), with an API key" },
	{ value = "openai", text = "OpenAI, with an API key" },
	{ value = "berget", text = "Berget, signing in with your account" },
	{ value = "ollama", text = "Ollama, running on this machine" },
	{ value = "none", text = "none for now" },
}

--- The language model question's choices, the provider in use picked.
function M.provider_choices(): { string }
	local reasoning = models.roles[models.playing("reasoning")]
	local now = "none"
	for _, known in PROVIDERS do
		if reasoning and reasoning.provider == known.value then
			now = known.value
		end
	end
	local list = {}
	for _, known in PROVIDERS do
		local picked = if known.value == now then "(x) " else ""
		table.insert(list, `{picked}{known.value}: {known.text}`)
	end
	return list
end

-- Whether the Ollama model is there: what the page says about it.
local function check_ollama(): string
	local pulled, why = models.ollama_models()
	local preset = (models.presets.ollama :: { fast: string, reasoning: string }).reasoning
	if pulled == nil then
		return `{why}, then \`ollama pull {preset}\`.`
	elseif #pulled == 0 then
		return `Ollama answers but has no models yet: \`ollama pull {preset}\` fetches one.`
	end
	return `Ollama answers, with {table.concat(pulled, ", ")}.`
end

--- Helps with the model `name` picked: says whether Ollama answers, signs
--- you in, or asks for the API key; says so when it's ready already. It
--- goes on after returning, since a block's code can't wait for answers.
function M.model(name: string)
	greed.spawn(function()
		local provider = models.providers[name]
		if name == "ollama" then
			greed.echo(check_ollama())
			return
		end
		local state = models.key_state(name)
		if state then
			greed.echo(`{name}: {state}`)
		elseif provider and provider.login then
			greed.run("login", { args = { provider.login } })
		elseif provider then
			greed.echo(models.ask_key(name))
		end
	end)
end

--- The config the page's answers make: what was picked, then settings
--- worth trying, commented out.
function M.config(answers: { [string]: string }): string
	local style = greed.option.get("editing-style") :: string
	local icons = answers.icons == "yes"
	local leader = if style == "vscode" then "ctrl-space" else "space"
	return table.concat({
		"-- Written by Greed's setup; :setup shows its questions again.",
		"-- This file runs again each time you save it, so a change shows at once.",
		"--",
		"-- Finding more settings:",
		`--   {leader} h o   describe an option: what it does, its value and default`,
		`--   {leader} h h   describe anything: commands, options, keys, plugins`,
		"--   :set NAME VALUE   try an option for this session; tab completes",
		"--                     names and values (:set NAME? shows one)",
		"",
		'local greed = require("@greed")',
		"",
		"-- helix, vim or vscode; :style switches while Greed runs.",
		`greed.option.set("editing-style", "{style}")`,
		"",
		"-- Icons in the file tree, and round ends on status line pills; both",
		"-- need a Nerd Font in a terminal (the window has the icons built in).",
		`greed.option.set("tree-icons", "{if icons then "nerd" else "none"}")`,
		`greed.option.set("statusline-caps", "{if icons then "round" else "none"}")`,
		"",
		"-- The theme you pick with :theme is remembered; to fix one here instead:",
		`-- require("@theme").use("{theme.current()}")`,
		"",
		"-- Remove the -- in front of a line to try it.",
		"",
		"-- Line numbers relative to the cursor's line, or hybrid (the cursor's",
		"-- line keeps its own number).",
		'-- greed.option.set("line-numbers", "relative")',
		"",
		"-- The mode, tab and session as coloured pills in the status line, and",
		"-- small animations, like a wave of light when you switch files.",
		'-- greed.option.set("statusline-pills", true)',
		'-- greed.option.set("effects", true)',
		"",
		"-- Save on its own a moment after you stop typing.",
		'-- greed.option.set("auto-save", true)',
		"",
		"-- Number where the next word motions would go; a digit jumps there.",
		'-- greed.option.set("motion-hints", true)',
		"",
		"-- How new tabs arrange their panes: manual, main-stack, columns or spiral.",
		'-- greed.option.set("pane-layout", "main-stack")',
		"",
		"-- What a terminal pane runs (your $SHELL by default), and the prompt of",
		"-- Greed's own shell: its own, or your starship prompt.",
		'-- greed.option.set("terminal-shell", "fish -l")',
		'-- greed.option.set("shell-prompt", "starship")',
		"",
		"-- Where your notes live.",
		'-- greed.option.set("notes-folder", "~/notes")',
		"",
		"-- The window (greed --gui): its font and size. ctrl-= and ctrl-- zoom.",
		'-- greed.option.set("gui-font", "JetBrains Mono")',
		'-- greed.option.set("gui-font-size", 16)',
		"",
		"-- A language's indent and formatter.",
		'-- require("@languages").set("python", { indent = 4, formatter = { "black", "-q", "-" } })',
		"",
		"-- Your own keys, here after the leader: in Helix and Vim space W saves every file.",
		'-- greed.keymap.bind({ layer = "leader" }, { W = "save-all" })',
		"",
		"-- One colour changed on top of the theme, here the comments.",
		'-- greed.theme.set({ comment = { fg = "#7f8c98", italic = true } })',
		"",
	}, "\n")
end

-- Where the page notes it was answered, so it doesn't show again by itself.
local function seen_path(): string?
	local data = greed.fs.dirs().data
	return data and `{data}/setup-seen`
end

-- Notes the page was answered and forgets it; closing its view, however
-- it closes, comes here.
local function done()
	local path = seen_path()
	if path then
		greed.fs.write(path, "")
	end
	page = nil
end

--- Closes the page, as answered.
function M.close()
	local p = page
	done()
	if p and p.view:valid() then
		p.view:close()
	end
end

--- Saves the page's `answers` as your config (or shows what to add to the
--- one you have), has the models use the provider picked, adds Greed's
--- tools to Claude Code if you said so, and closes the page.
function M.save(answers: { [string]: string })
	local config = M.config(answers)
	local dir = greed.fs.dirs().config
	local file = dir and `{dir}/init.luau`
	if file and greed.fs.stat(file) == nil then
		greed.fs.write(file, config)
	end
	local said: { string } = {}
	local provider = answers.provider
	if provider and provider ~= "none" then
		local unkept = models.use_provider(provider)
		table.insert(
			said,
			if unkept
				then `can't keep the model: {unkept}`
				else `models now from {provider} (:models changes them)`
		)
	end
	M.close()
	if answers.claude == "yes" then
		local added = greed.process.run({ "claude", "mcp", "add", "greed", "--", "greed", "mcp" })
		table.insert(
			said,
			if added and added.code == 0
				then "Greed's tools are added to Claude Code"
				else "couldn't add Greed's tools to Claude Code; run: claude mcp add greed -- greed mcp"
		)
	end
	if #said > 0 then
		greed.echo(table.concat(said, "; "))
	end
	types.update()
	if file and greed.fs.read(file) == config then
		greed.open(file)
	else
		-- A config already there stays as it is; here's what to add.
		local shown = core.floats.show_text(
			"Add to your init.luau",
			config,
			{ kind = "setup-config", language = "luau", width = "70%", height = "50%" }
		)
		shown:focus()
	end
end

--- The page's text, setup.md.
function M.text(): string
	local dir = greed.plugin.dirs().setup
	return dir and greed.fs.read(`{dir}/setup.md`) or "# Setup\n\nsetup.md is missing.\n"
end

--- Opens the setup page, or goes to it if it's open.
function M.open()
	local open = page
	if open and open.view:valid() then
		open.view:focus()
		return
	end
	local buffer =
		greed.create_buffer("setup", M.text(), { readonly = true, language = "markdown" })
	buffer:set_line_numbers(false)
	buffer:set_keys({
		tab = "setup-next",
		enter = "press-button",
		space = "press-button",
		["shift-tab"] = "setup-prev",
		esc = "setup-close",
		q = "setup-close",
	})
	local view = greed.float(buffer, { title = "Setup", width = "80%", height = "90%" })
	page = { buffer = buffer, view = view }
	view:focus()
	-- The choices made by code: the styles and themes there are now.
	blocks.refresh_choices(buffer)
	if page and page.buffer == buffer and view:valid() then
		greed.run("setup-next")
	end
end

-- The page in `ctx`, if that's where the command runs.
local function here(ctx: greed.Context): Page?
	local p = page
	if p and p.buffer == ctx.buffer then
		return p
	end
	return nil
end

-- Where the cursor goes for each choice and button showing on the page, in
-- order: a choice's box, a button's fence.
local function stops(buffer: greed.Buffer): { number }
	local hidden = markdown.questions.state(buffer)
	local found: { number } = {}
	for _, group in markdown.choices.list(buffer) do
		for _, option in group.options do
			if not hidden[option.line] then
				local box = string.find(buffer:line_text(option.line), "%(") :: number
				table.insert(found, buffer:line_start(option.line) + box - 1)
			end
		end
	end
	for _, block in blocks.parse.blocks(buffer) do
		if block.opts.button and not hidden[block.open] then
			table.insert(found, block.from)
		end
	end
	table.sort(found)
	return found
end

-- Moves to the choice or button `step` away from the cursor, round the page.
local function move(ctx: greed.Context, step: number)
	if here(ctx) == nil then
		return
	end
	local list = stops(ctx.buffer)
	if #list == 0 then
		return
	end
	local cursor = ctx.view:cursor()
	local current = 0
	for i, at in list do
		if cursor >= at then
			current = i
		end
	end
	if current == 0 and step < 0 then
		current = 1
	end
	ctx.view:set_cursor(list[(current - 1 + step) % #list + 1])
end

greed.command({
	name = "setup",
	doc = "Answer a few questions to set Greed up: editing style, theme, icons, Claude Code, a model",
	run = function()
		M.open()
	end,
})

greed.command({
	name = "setup-next",
	doc = "Go to the next choice or button on the setup page",
	run = function(ctx)
		move(ctx, 1)
	end,
})

greed.command({
	name = "setup-prev",
	doc = "Go to the previous choice or button on the setup page",
	run = function(ctx)
		move(ctx, -1)
	end,
})

greed.command({
	name = "setup-save",
	doc = "Save the setup page's answers as your config, and open it",
	run = function(ctx)
		if here(ctx) == nil then
			greed.echo("the setup page isn't here")
			return
		end
		M.save(markdown.questions.answers(ctx.buffer))
	end,
})

greed.command({
	name = "setup-close",
	doc = "Close the setup page without saving; :setup brings it back",
	run = function(ctx)
		if here(ctx) then
			M.close()
		end
	end,
})

-- However the page closes (Not now, :q, a click elsewhere closing it), it
-- counts as answered, so it doesn't come back by itself.
greed.on("view.closed", function(event: greed.ViewClosed)
	local p = page
	if p and p.view:id() == event.view then
		done()
	end
end)

-- The first time someone attaches without a config, the page shows.
greed.on("client.attached", function()
	local dirs = greed.fs.dirs()
	if page or dirs.brought or dirs.config == nil then
		return
	end
	local seen = seen_path()
	if greed.fs.stat(`{dirs.config}/init.luau`) or (seen and greed.fs.stat(seen)) then
		return
	end
	M.open()
end)

--- Type checking for your config (types.luau).
M.types = types

return M
