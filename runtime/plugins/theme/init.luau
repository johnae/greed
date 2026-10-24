-- Themes: what every style name looks like. Greed comes with the default
-- (the terminal's 16 colors) and the usual ones from other editors: Nord,
-- Dracula, Catppuccin, Gruvbox, Tokyo Night, One Dark and more.
--
--   :theme NAME   switch to a theme
--   :theme        pick one, trying each as you move; esc goes back
--
-- The theme picked is remembered (in the cache folder) until you pick
-- another. To set it from your config, or define your own:
--
--     local theme = require("@theme")
--     theme.use("nord")
--     theme.define("mine", {
--         palette = { bg = "#101418", ... },  -- see palette.luau
--         styles = { comment = { fg = "#5c6773" } },
--     })
--     theme.define("nord-bold", { inherits = "nord", styles = { keyword = { bold = true } } })
--
-- A theme is the base under `greed.theme.set`: entries set that way, from
-- your config or a plugin, stay on top whichever theme is in use.

local greed = require("@greed")
local picker = require("@picker")
local cmdline = require("@cmdline")
local palette = require("@self/palette")

export type Palette = palette.Palette
export type Styles = { [string]: greed.ThemeEntry }

--- A theme: styles from a palette, styles of its own on top, and another
--- theme to start from.
export type Theme = {
	inherits: string?,
	palette: Palette?,
	styles: Styles?,
}

local M = {}

local themes: { [string]: Theme } = { default = { styles = require("@self/default") :: any } }
for name, colors in require("@self/themes") do
	themes[name] = { palette = colors }
end

local current = "default"
-- The theme in use before tab on `:theme` started trying others.
local tried_from: string? = nil
-- A theme asked for before a plugin added it, like one fetched from git on
-- the first start, or the one picked last when its plugin loads after this.
local wanted: string? = nil

--- Adds a theme, or replaces the one called `name`, until the plugin (or
--- config) that added it goes. One asked for before it was there is used now.
function M.define(name: string, theme: Theme)
	themes[name] = theme
	greed.plugin.cleanup(function()
		if themes[name] == theme then
			themes[name] = nil
		end
	end)
	if wanted == name then
		M.use(name)
	end
end

--- Every theme's name, sorted.
function M.list(): { string }
	local names = {}
	for name in themes do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

--- The theme in use.
function M.current(): string
	return current
end

-- `under` with the fields `over` gives changed, the surfaces' too.
local function patch(under: greed.ThemeEntry?, over: greed.ThemeEntry): greed.ThemeEntry
	local out: { [string]: any } = table.clone(under or {}) :: any
	for key, value in over :: { [string]: any } do
		local surface = out[key]
		if type(value) == "table" and type(surface) == "table" then
			local merged = table.clone(surface)
			for k, v in value do
				merged[k] = v
			end
			out[key] = merged
		else
			out[key] = value
		end
	end
	return out :: any
end

-- The styles of theme `name`, with what it inherits under them.
local function styles(name: string, seen: { [string]: boolean }): Styles
	local theme = themes[name]
	if theme == nil then
		error(`there's no theme called {name}`, 0)
	elseif seen[name] then
		error(`theme {name} inherits from itself`, 0)
	end
	seen[name] = true
	local out: Styles = if theme.inherits then styles(theme.inherits, seen) else {}
	if theme.palette then
		for style, entry in palette.styles(theme.palette) do
			out[style] = patch(out[style], entry)
		end
	end
	local own: Styles = theme.styles or {}
	for style, entry in own do
		out[style] = patch(out[style], entry)
	end
	return out
end

--- Switches to theme `name`. With `effects-dim` on, the text of the panes
--- you're not in is dimmed: blended towards the background in the window,
--- the terminal's dim attribute in a terminal.
function M.use(name: string)
	if themes[name] == nil then
		-- Its plugin may not be there yet; it's used once it adds it.
		wanted = name
		return
	end
	wanted = nil
	local base = styles(name, {})
	if greed.option.get("effects-dim") == true then
		base["ui.pane.inactive"] = patch(base["ui.pane.inactive"], { dim = true })
	end
	greed.theme.base(base)
	current = name
end

greed.on("option.changed", function(event: greed.OptionChanged)
	if event.name == "effects-dim" then
		M.use(current)
	end
end)

-- Where the theme picked last is kept.
local function remembered(): string?
	local cache = greed.fs.dirs().cache
	return cache and `{cache}/theme`
end

-- Switches to `name` and remembers it for next time.
local function pick(name: string)
	tried_from = nil
	M.use(name)
	local path = remembered()
	if path then
		greed.fs.write(path, name .. "\n")
	end
end

cmdline.completer("theme", function()
	local items = {}
	for _, name in M.list() do
		table.insert(items, { text = name, doc = if name == current then "in use" else nil })
	end
	return items
end, function(name)
	-- Tab tries each theme; closing without running puts the old one back.
	if name == nil then
		if tried_from then
			M.use(tried_from)
		end
		tried_from = nil
	elseif themes[name] then
		tried_from = tried_from or current
		M.use(name)
	end
end)

greed.command({
	name = "theme",
	doc = "Switch to a theme, or pick one trying each as you move",
	args = { { name = "name", doc = "e.g. nord or dracula", complete = "theme" } },
	run = function(ctx)
		local name = ctx.args[1]
		if name then
			if themes[name] == nil then
				error(`there's no theme called {name}`, 0)
			end
			pick(name)
			return
		end
		local before = current
		-- The theme in use comes first, so opening the picker changes nothing.
		local items = { { label = current, value = current } }
		for _, theme in M.list() do
			if theme ~= current then
				table.insert(items, { label = theme, value = theme })
			end
		end
		picker.pick("Theme", items, function(item)
			pick(item.value)
		end, {
			on_move = function(item)
				M.use(item.value)
			end,
			on_cancel = function()
				M.use(before)
			end,
		})
	end,
})

local saved = remembered()
local name = saved and string.match(greed.fs.read(saved) or "", "^%s*(%S+)")
-- The default meanwhile, when the one picked last comes from a plugin that
-- loads after this.
M.use("default")
if name then
	M.use(name)
end

-- Once everything has loaded, one asked for that hasn't come is said: a
-- plugin still being fetched, or a misspelled name.
greed.on("editor.started", function()
	if wanted then
		greed.echo(
			`theme {wanted} isn't there yet; it's used once a plugin adds it (:theme lists them)`
		)
	end
end)

return M
