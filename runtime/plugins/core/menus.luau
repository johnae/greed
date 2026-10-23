-- The window's menu bar (on macOS, the system's): menus of commands, so
-- what Greed can do is there to find with the mouse. Terminals have none;
-- the command palette lists every command anywhere.
--
-- Add your own from your config or a plugin; calling what `add` returns
-- takes the item away again:
--
--     require("@core").menus.add("Tools", "Run tests", "test-run")

local greed = require("@greed")
local registry = require("./registry")

local M = {}

export type Item = { label: string, command: string }
export type Menu = { title: string, items: { Item } }

-- Items others added.
local added: { { title: string, item: Item } } = {}

-- What the menus start with. Items whose command isn't there (a plugin
-- that isn't loaded) are left out until it is.
local defaults: { Menu } = {
	{
		title = "File",
		items = {
			{ label = "Open File…", command = "pick-file" },
			{ label = "Open Project…", command = "pick-project" },
			{ label = "New Window", command = "window-new" },
			{ label = "Switch to File…", command = "pick-buffer" },
			{ label = "Save", command = "save" },
			{ label = "Close File", command = "buffer-close" },
			{ label = "Quit", command = "quit" },
		},
	},
	{
		title = "Edit",
		items = {
			{ label = "Undo", command = "undo" },
			{ label = "Redo", command = "redo" },
			{ label = "Cut", command = "cut" },
			{ label = "Copy", command = "copy" },
			{ label = "Paste", command = "paste-after" },
			{ label = "Select All", command = "select-all" },
			{ label = "Find…", command = "search" },
			{ label = "Find in Project…", command = "grep" },
			{ label = "Format", command = "format" },
			{ label = "Rename…", command = "rename" },
		},
	},
	{
		title = "View",
		items = {
			{ label = "File Tree", command = "tree" },
			{ label = "Problems", command = "pick-problem" },
			{ label = "Outline", command = "pick-outline" },
			{ label = "Bigger Text", command = "font-bigger" },
			{ label = "Smaller Text", command = "font-smaller" },
			{ label = "Text Size Back", command = "font-reset" },
			{ label = "Theme…", command = "theme" },
		},
	},
	{
		title = "Pane",
		items = {
			{ label = "Split Right", command = "pane-split-right" },
			{ label = "Split Down", command = "pane-split-down" },
			{ label = "Next Pane", command = "pane-next" },
			{ label = "Zoom", command = "pane-zoom" },
			{ label = "Close Pane", command = "pane-close" },
		},
	},
	{
		title = "Help",
		items = {
			{ label = "All Commands…", command = "command-palette" },
			{ label = "Keys", command = "keys-help" },
			{ label = "Tutor", command = "tutor" },
		},
	},
}

-- The menus as they stand: the defaults, then what was added, each item
-- only while its command exists; empty menus left out.
local function current(): { Menu }
	local known: { [string]: boolean } = {}
	for _, command in greed.commands() do
		known[command.name] = true
	end
	local menus: { Menu } = {}
	local by_title: { [string]: Menu } = {}
	local function put(title: string, item: Item)
		local menu = by_title[title]
		if menu == nil then
			menu = { title = title, items = {} }
			by_title[title] = menu
			-- New menus go before Help, which stays last.
			local help = if menus[#menus] and menus[#menus].title == "Help"
				then #menus
				else #menus + 1
			table.insert(menus, help, menu)
		end
		if known[item.command] then
			table.insert(menu.items, item)
		end
	end
	for _, menu in defaults do
		for _, item in menu.items do
			put(menu.title, item)
		end
	end
	for _, entry in added do
		put(entry.title, entry.item)
	end
	local shown = {}
	for _, menu in menus do
		if #menu.items > 0 then
			table.insert(shown, menu)
		end
	end
	return shown
end

-- Whether the menus are to be sent again once what's running now is done.
local pending = false

-- Sends the window the menus again, once for all the changes made in a
-- row: starting loads every plugin and adds every item, and listing every
-- command for each of them was much of the time starting took.
local function publish()
	if pending then
		return
	end
	pending = true
	greed.spawn(function()
		greed.sleep(0)
		pending = false
		greed.set_menus(current())
	end)
end

--- The menus as the window shows them.
M.list = current

--- Adds an item running `command` to the menu titled `title`, making the
--- menu if there's none. It goes when the plugin (or config) that added
--- it does, or when what it returns is called.
function M.add(title: string, label: string, command: string): () -> ()
	local take = registry.put(added, { title = title, item = { label = label, command = command } })
	publish()
	local function remove()
		take()
		publish()
	end
	greed.plugin.cleanup(remove)
	return remove
end

-- Plugins loading and unloading bring commands and take them away.
greed.on("plugin.loaded", publish)
greed.on("plugin.unloaded", publish)
publish()

return M
