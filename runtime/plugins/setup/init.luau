-- Setting Greed up: the first time you start it without a config, a page
-- asks how you like to edit, which theme, whether your font has icons,
-- whether you use Claude Code and which language model to use. A style or
-- theme picked switches at once, so you can try it on the page (the theme
-- is remembered, as `:theme` does); Save writes a short init.luau from the
-- rest and opens it, and has the model's roles use the provider picked.
-- `:setup` brings the page back any time.
--
-- The page is a form in every editing style: tab and shift-tab go from
-- control to control, enter or space picks a choice or presses a button,
-- a click does too, and esc or q closes it as "Not now".

local greed = require("@greed")
local core = require("@core")
local models = require("@models")
local picker = require("@picker")
local theme = require("@theme")
local types = require("@self/types")

local M = {}

-- A control on the page: a choice of a question (`group`) or a button
-- (`kind` says which), and where it is, as byte offsets into the page.
type Control = {
	kind: string,
	group: string?,
	value: string?,
	action: string?,
	from: number,
	to: number,
}

-- The answers waiting for Save; the style and theme are options, read as
-- they are.
type Answers = { icons: boolean, claude: boolean, provider: string, ollama: string? }

type Page = {
	buffer: greed.Buffer,
	view: greed.View,
	controls: { Control },
	answers: Answers,
}

-- The setup page, if it's open.
local page: Page? = nil

local PROVIDERS = {
	{ value = "anthropic", text = "Anthropic (Claude), with an API key" },
	{ value = "openai", text = "OpenAI, with an API key" },
	{ value = "berget", text = "Berget, signing in with your account" },
	{ value = "ollama", text = "Ollama, running on this machine" },
	{ value = "none", text = "None for now" },
}

-- Whether the page shows in a window, which draws icons whatever its font.
local function in_window(): boolean
	return greed.client.current().kind == "gui"
end

-- What the page says about the model picked, and the button that helps,
-- if one does.
local function model_status(answers: Answers): (string, { text: string, action: string }?)
	local name = answers.provider
	if name == "none" then
		return "You can set one up any time with :models.", nil
	elseif name == "ollama" then
		return answers.ollama or "Not checked yet.",
			{ text = "Check again", action = "setup-model" }
	end
	local state = models.key_state(name)
	if state then
		return `{name}: {state}.`, nil
	end
	local provider = models.providers[name]
	if provider and provider.login then
		return `Not signed in to {name} yet.`, { text = "Sign in…", action = "setup-model" }
	end
	local variable = greed.secrets.variable((provider and provider.secret) or name)
	return `No API key for {name} yet (or set {variable}).`,
		{ text = "Set API key…", action = "setup-model" }
end

-- Writes the page from the options as they are and the answers, keeping
-- the cursor on the control it was on.
local function render(p: Page)
	local buffer = p.buffer
	local before: number? = nil
	if p.view:valid() then
		local cursor = p.view:cursor()
		for i, control in p.controls do
			if cursor >= control.from and cursor <= control.to then
				before = i
			end
		end
	end
	local lines: { string } = {}
	local at = 0
	local controls: { Control } = {}
	local marks: { greed.Mark } = {}
	local function add(line: string, style: string?)
		if style then
			table.insert(marks, { from = at, to = at + #line, style = style })
		end
		table.insert(lines, line)
		at += #line + 1
	end
	local function choices(
		group: string,
		options: { { value: string, text: string } },
		picked: string
	)
		for _, option in options do
			local chosen = option.value == picked
			local glyph = if chosen then "◉" else "◯"
			local start = at + 2
			table.insert(marks, {
				from = start,
				to = start + #glyph,
				style = if chosen then "markdown.chosen" else "markdown.choice",
			})
			table.insert(controls, {
				kind = "choice",
				group = group,
				value = option.value,
				from = start,
				to = start + #glyph + 1 + #option.text,
			})
			add(`  {glyph} {option.text}`)
		end
	end
	-- A line of buttons after `text`, each [ label ].
	local function buttons(text: string, list: { { text: string, action: string } })
		local line: string = text
		for _, button in list do
			local gap = if line == "" then "" else "  "
			local label = `[ {button.text} ]`
			local start = at + #line + #gap
			table.insert(marks, { from = start, to = start + #label, style = "ui.button" })
			table.insert(
				controls,
				{ kind = "button", action = button.action, from = start, to = start + #label }
			)
			line ..= gap .. label
		end
		add(line)
	end
	local a = p.answers
	add("Welcome to Greed", "markup.heading")
	add("")
	add("A few questions to set Greed up. tab and shift-tab move between the choices,")
	add("enter or space picks one, and esc closes the page. A style or theme you pick")
	add("switches now, so you can try it here; the rest waits for Save.")
	add("")
	add("How do you like to edit?", "markup.heading")
	add("")
	local styles = {}
	for _, s in core.style.list() do
		table.insert(styles, { value = s.name, text = s.doc })
	end
	choices("style", styles, greed.option.get("editing-style") :: string)
	add("")
	buttons(`Theme: {theme.current()}`, { { text = "Pick…", action = "setup-pick-theme" } })
	add("")
	if in_window() then
		-- The window draws Nerd Font icons whatever its font.
		add("Icons: the window has them built in.", "markup.heading")
	else
		add("Do you see icons here:  󰉋        ", "markup.heading")
		add("")
		choices("icons", {
			{ value = "yes", text = "Yes, they show" },
			{ value = "no", text = "No, or they're boxes" },
		}, if a.icons then "yes" else "no")
		add(
			"Boxes? Your terminal's font needs Nerd Font icons; plain ones work anywhere.",
			"comment"
		)
	end
	add("")
	add("Do you use Claude Code?", "markup.heading")
	add("")
	choices("claude", {
		{
			value = "yes",
			text = "Yes: add Greed's tools to it (claude mcp add greed -- greed mcp)",
		},
		{ value = "no", text = "No, or not now" },
	}, if a.claude then "yes" else "no")
	add("")
	add("Which language model should Greed use?", "markup.heading")
	add("")
	choices("provider", PROVIDERS, a.provider)
	add("")
	local status, helper = model_status(a)
	buttons(`  {status}`, if helper then { helper } else {})
	add("")
	buttons("", {
		{ text = "Save", action = "setup-save" },
		{ text = "Not now", action = "setup-close" },
	})
	local text = table.concat(lines, "\n")
	if buffer:text() ~= text then
		buffer:edit(function(e)
			e:replace(0, buffer:len(), text)
		end)
	end
	buffer:decorate("setup", marks)
	p.controls = controls
	if before and p.view:valid() then
		local control = controls[math.min(before, #controls)]
		p.view:set_cursor(control.from)
	end
end

-- The control the cursor is on in `p`, or the first on its line.
local function control_at(p: Page, pos: number): Control?
	local line = p.buffer:line_of(pos)
	local first: Control? = nil
	for _, control in p.controls do
		if pos >= control.from and pos < control.to then
			return control
		elseif first == nil and p.buffer:line_of(control.from) == line then
			first = control
		end
	end
	return first
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

-- Closes the page, as answered.
local function close(p: Page)
	done()
	if p.view:valid() then
		p.view:close()
	end
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

-- Picks `control`, a choice: a style switches at once, the rest waits.
local function pick(p: Page, control: Control)
	local value = control.value :: string
	if control.group == "style" then
		greed.option.set("editing-style", value)
	elseif control.group == "icons" then
		p.answers.icons = value == "yes"
	elseif control.group == "claude" then
		p.answers.claude = value == "yes"
	elseif control.group == "provider" then
		p.answers.provider = value
		if value == "ollama" then
			p.answers.ollama = check_ollama()
		end
	end
	render(p)
	p.view:set_cursor(control.from)
end

-- Presses `control`: picks a choice or runs a button's command.
local function press(p: Page, control: Control)
	p.view:set_cursor(control.from)
	if control.kind == "choice" then
		pick(p, control)
	else
		greed.run(control.action :: string)
	end
end

--- The config the page's answers make.
function M.config(answers: { icons: boolean }): string
	local style = greed.option.get("editing-style") :: string
	local icons = answers.icons
	return table.concat({
		"-- Written by Greed's setup; :setup shows its questions again.",
		"-- Change anything here: see the docs, or :options.",
		"",
		'local greed = require("@greed")',
		"",
		`greed.option.set("editing-style", "{style}")`,
		`greed.option.set("tree-icons", "{if icons then "nerd" else "none"}")`,
		`greed.option.set("statusline-caps", "{if icons then "round" else "none"}")`,
		"",
	}, "\n")
end

-- The page in `ctx`, if that's where the command runs.
local function here(ctx: greed.Context): Page?
	local p = page
	if p and p.buffer == ctx.buffer then
		return p
	end
	return nil
end

--- Opens the setup page, or goes to it if it's open.
function M.open()
	local open = page
	if open and open.view:valid() then
		open.view:focus()
		return
	end
	local reasoning = models.roles[models.playing("reasoning")]
	local provider = "none"
	for _, known in PROVIDERS do
		if reasoning and reasoning.provider == known.value then
			provider = known.value
		end
	end
	local buffer = greed.create_buffer("setup", "", { readonly = true })
	buffer:set_line_numbers(false)
	buffer:set_keys({
		tab = "setup-next",
		["shift-tab"] = "setup-prev",
		enter = "setup-press",
		space = "setup-press",
		esc = "setup-close",
		q = "setup-close",
	})
	local view = greed.float(buffer, { title = "Setup", width = "80%", height = "90%" })
	local p: Page = {
		buffer = buffer,
		view = view,
		controls = {},
		answers = {
			icons = in_window() or greed.option.get("tree-icons") == "nerd",
			claude = false,
			provider = provider,
		},
	}
	page = p
	render(p)
	view:focus()
	view:set_cursor(p.controls[1].from)
end

-- Clicks on a control press it; others move the cursor as anywhere.
core.mouse.claim("setup", function(event)
	local p = page
	local view = event.view
	if p == nil or view == nil or view ~= p.view or event.pos == nil then
		return false
	end
	if not (event.kind == "press" and event.button == "left") then
		return false
	end
	for _, control in p.controls do
		if event.pos >= control.from and event.pos < control.to then
			view:focus()
			press(p, control)
			return true
		end
	end
	return false
end)

-- The page shows the options as they are, set from anywhere.
greed.on("option.changed", function(event)
	local p = page
	if p and (event.name == "editing-style" or event.name == "tree-icons") then
		if event.name == "tree-icons" then
			p.answers.icons = event.value == "nerd"
		end
		render(p)
	end
end)

-- However the page closes (Not now, :q, a click elsewhere closing it), it
-- counts as answered, so it doesn't come back by itself.
greed.on("view.closed", function(event: greed.ViewClosed)
	local p = page
	if p and p.view:id() == event.view then
		done()
	end
end)

greed.command({
	name = "setup",
	doc = "Answer a few questions to set Greed up: editing style, theme, icons, Claude Code, a model",
	run = function()
		M.open()
	end,
})

-- Moves to the control `step` away from the cursor's, round the page.
local function move(ctx: greed.Context, step: number)
	local p = here(ctx)
	if p == nil or #p.controls == 0 then
		return
	end
	local cursor = ctx.view:cursor()
	local current = 0
	for i, control in p.controls do
		if cursor >= control.from then
			current = i
		end
	end
	if current == 0 and step < 0 then
		current = 1
	end
	local next = (current - 1 + step) % #p.controls + 1
	ctx.view:set_cursor(p.controls[next].from)
end

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
	name = "setup-press",
	doc = "Pick the choice or press the button under the cursor on the setup page",
	run = function(ctx)
		local p = here(ctx)
		local control = p and control_at(p, ctx.view:cursor())
		if p and control then
			press(p, control)
		end
	end,
})

greed.command({
	name = "setup-pick-theme",
	doc = "Pick the theme on the setup page, trying each as you move",
	run = function()
		local p = page
		if p == nil then
			return
		end
		local before = theme.current()
		local items = {}
		for _, name in theme.list() do
			table.insert(items, { label = name, value = name })
		end
		picker.pick("Theme", items, function(item)
			greed.run("theme", { args = { item.value } })
			if page == p then
				render(p)
			end
		end, {
			on_move = function(item)
				theme.use(item.value)
			end,
			on_cancel = function()
				theme.use(before)
			end,
		})
	end,
})

greed.command({
	name = "setup-model",
	doc = "On the setup page, set the API key of the model picked, sign in to it, or check Ollama again",
	run = function()
		local p = page
		if p == nil then
			return
		end
		local name = p.answers.provider
		local provider = models.providers[name]
		if name == "ollama" then
			p.answers.ollama = check_ollama()
		elseif provider and provider.login then
			greed.run("login", { args = { provider.login } })
		elseif provider then
			greed.echo(models.ask_key(name))
		end
		if page == p then
			render(p)
		end
	end,
})

greed.command({
	name = "setup-save",
	doc = "Save the setup page's answers as your config, and open it",
	run = function(ctx)
		local p = here(ctx)
		if p == nil then
			greed.echo("the setup page isn't here")
			return
		end
		local config = M.config(p.answers)
		local dir = greed.fs.dirs().config
		local file = dir and `{dir}/init.luau`
		if file and greed.fs.stat(file) == nil then
			greed.fs.write(file, config)
		end
		local said: { string } = {}
		if p.answers.provider ~= "none" then
			local unkept = models.use_provider(p.answers.provider)
			table.insert(
				said,
				if unkept
					then `can't keep the model: {unkept}`
					else `models now from {p.answers.provider} (:models changes them)`
			)
		end
		close(p)
		if p.answers.claude then
			local added =
				greed.process.run({ "claude", "mcp", "add", "greed", "--", "greed", "mcp" })
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
	end,
})

greed.command({
	name = "setup-close",
	doc = "Close the setup page without saving; :setup brings it back",
	run = function(ctx)
		local p = here(ctx)
		if p then
			close(p)
		end
	end,
})

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
