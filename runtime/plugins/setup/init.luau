-- Setting Greed up: the first time you start it without a config, a page
-- asks how you like to edit, which theme, whether your font has icons, and
-- whether you use Claude Code. A style or theme picked switches at once, so
-- you can try it on the page (the theme is remembered, as `:theme` does);
-- Save writes a short init.luau from the rest and opens it. `:setup` brings
-- the page back any time.
--
-- The page is Markdown with choices (`- ( )`): it reads as plain text, and
-- what's picked is the text itself.

local greed = require("@greed")
local core = require("@core")
local markdown = require("@markdown")
local picker = require("@picker")
local theme = require("@theme")
local types = require("@self/types")

local M = {}

local QUESTIONS = {
	style = "How do you like to edit?",
	icons = "Do you see an icon here: 󰉋",
	claude = "Do you use Claude Code?",
}

-- The setup page, if it's open.
local page: greed.Buffer? = nil

local function choice(picked: boolean, text: string): string
	return `- ({if picked then "x" else " "}) {text}`
end

-- The page, with what's in use now picked.
local function text(): string
	local style = greed.option.get("editing-style")
	local styles = {}
	for _, s in core.style.list() do
		table.insert(styles, choice(style == s.name, s.doc))
	end
	local icons = greed.option.get("tree-icons") == "nerd"
	return table.concat({
		"# Welcome to Greed",
		"",
		"A few questions to set Greed up. Pick with `enter` or a click: a style or",
		"theme switches now so you can try it here, the rest waits for Save.",
		"",
		`### {QUESTIONS.style}`,
		"",
		table.concat(styles, "\n"),
		"",
		`Theme: {theme.current()}`,
		"",
		`### {QUESTIONS.icons}`,
		"",
		choice(icons, "Yes, it shows"),
		choice(not icons, "No, or it's a box"),
		"",
		`### {QUESTIONS.claude}`,
		"",
		choice(false, "Yes: add Greed's tools to it (`claude mcp add greed -- greed mcp`)"),
		choice(true, "No, or not now"),
		"",
		"When you're done:",
	}, "\n")
end

-- The picked option's text for `question` on the page.
local function picked(buffer: greed.Buffer, question: string): string?
	for _, group in markdown.choices.list(buffer) do
		if group.question == question then
			for _, option in group.options do
				if option.picked then
					return option.text
				end
			end
		end
	end
	return nil
end

-- The editing style a choice's text is the doc of.
local function style_of(text: string?): string?
	for _, s in core.style.list() do
		if s.doc == text then
			return s.name
		end
	end
	return nil
end

-- The line saying the theme, after a pick.
local function show_theme(buffer: greed.Buffer, name: string)
	for line = 0, buffer:line_count() - 1 do
		if string.match(buffer:line_text(line), "^Theme: ") then
			local start, finish = buffer:line_start(line), buffer:line_end(line)
			buffer:edit(function(e)
				e:replace(start, finish, `Theme: {name}`)
			end)
			return
		end
	end
end

-- Buttons: Pick... after the theme, Save and Not now at the end.
local function buttons(buffer: greed.Buffer)
	local marks: { greed.Mark } = {}
	local function button(line: number, label: string, action: string)
		local at = buffer:line_start(line)
		table.insert(
			marks,
			{ from = at, to = at, style = "ui.button", text = label, eol = true, action = action }
		)
	end
	for line = 0, buffer:line_count() - 1 do
		local words = buffer:line_text(line)
		if string.match(words, "^Theme: ") then
			button(line, "Pick…", "setup-pick-theme")
		elseif words == "When you're done:" then
			button(line, "Save", "setup-save")
			button(line, "Not now", "setup-close")
		end
	end
	buffer:decorate("setup", marks)
end

-- Where the page notes it was answered, so it doesn't show again by itself.
local function seen_path(): string?
	local data = greed.fs.dirs().data
	return data and `{data}/setup-seen`
end

-- Closes the page, noting it was answered.
local function close(view: greed.View)
	local path = seen_path()
	if path then
		greed.fs.write(path, "")
	end
	page = nil
	view:close()
end

--- The config the page's answers make.
function M.config(buffer: greed.Buffer): string
	local style = style_of(picked(buffer, QUESTIONS.style)) or "helix"
	local icons = picked(buffer, QUESTIONS.icons) == "Yes, it shows"
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

--- Opens the setup page.
function M.open()
	local buffer = greed.create_buffer("file", text(), { language = "markdown" })
	page = buffer
	buttons(buffer)
	greed.float(buffer, { title = "Setup", width = "80%", height = "90%" })
end

-- Picking a style tries it at once.
markdown.choices.on_pick(function(buffer, group)
	if buffer == page and group.question == QUESTIONS.style then
		local style = style_of(picked(buffer, QUESTIONS.style))
		if style then
			greed.option.set("editing-style", style)
		end
	end
end)

greed.command({
	name = "setup",
	doc = "Answer a few questions to set Greed up: editing style, theme, icons, Claude Code",
	run = function()
		M.open()
	end,
})

greed.command({
	name = "setup-pick-theme",
	doc = "Pick the theme on the setup page, trying each as you move",
	run = function()
		local buffer = page
		if buffer == nil then
			return
		end
		local before = theme.current()
		local items = {}
		for _, name in theme.list() do
			table.insert(items, { label = name, value = name })
		end
		picker.pick("Theme", items, function(item)
			greed.run("theme", { args = { item.value } })
			show_theme(buffer, item.value)
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
	name = "setup-save",
	doc = "Save the setup page's answers as your config, and open it",
	run = function(ctx)
		local buffer = page
		if buffer == nil or buffer ~= ctx.buffer then
			greed.echo("the setup page isn't here")
			return
		end
		local config = M.config(buffer)
		local dir = greed.fs.dirs().config
		local file = dir and `{dir}/init.luau`
		if file and greed.fs.stat(file) == nil then
			greed.fs.write(file, config)
		end
		local claude = picked(buffer, QUESTIONS.claude)
		close(ctx.view)
		if claude and string.match(claude, "^Yes") then
			local done =
				greed.process.run({ "claude", "mcp", "add", "greed", "--", "greed", "mcp" })
			greed.echo(
				if done and done.code == 0
					then "Greed's tools are added to Claude Code"
					else "couldn't add Greed's tools to Claude Code; run: claude mcp add greed -- greed mcp"
			)
		end
		types.update()
		if file and greed.fs.read(file) == config then
			greed.open(file)
		else
			-- A config already there stays as it is; here's what to add.
			local shown = greed.create_buffer("file", config, { language = "luau" })
			greed.float(shown, { title = "Add to your init.luau", width = "70%", height = "50%" })
		end
	end,
})

greed.command({
	name = "setup-close",
	doc = "Close the setup page without saving; :setup brings it back",
	run = function(ctx)
		close(ctx.view)
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
