-- The editor's own objects: the editor itself (where the inspector
-- starts), buffers, views, tabs, plugins, clients, and files and folders.

local greed = require("@greed")
local actions = require("./actions")

return function(objects: any)
	type Object = { kind: string, id: string, label: string, value: any }

	local function buffer_object(buffer: greed.Buffer): Object
		return {
			kind = "buffer",
			id = `buffer:{buffer:id()}`,
			label = buffer:title(),
			value = buffer,
		}
	end

	-- Where a view is: a pane, a float or a panel.
	local function place(view: greed.View): string
		if view:is_pane() then
			return "pane"
		end
		return if view:float_spec() then "float" else "panel"
	end

	local function view_object(view: greed.View): Object
		local title = if view:valid() then view:buffer():title() else "closed"
		return {
			kind = "view",
			id = `view:{view:id()}`,
			label = `{title} ({place(view)})`,
			value = view,
		}
	end

	local function tab_object(tab: greed.TabInfo, i: number): Object
		return {
			kind = "tab",
			id = `tab:{tab.id}`,
			label = tab.name or `tab {i}`,
			value = tab.id,
		}
	end

	local function plugin_object(name: string): Object
		return { kind = "plugin", id = `plugin:{name}`, label = name, value = name }
	end

	-- The tab with `id`, and where it is among the tabs.
	local function tab_by_id(id: number): (greed.TabInfo?, number)
		for i, tab in greed.tab.list() do
			if tab.id == id then
				return tab, i
			end
		end
		return nil, 0
	end

	-- Every view there is: each tab's panes, the floats, then the rest
	-- (panels), found through the buffers they show.
	local function all_views(): { greed.View }
		local out: { greed.View } = {}
		for _, tab in greed.tab.list() do
			for _, pane in tab.panes do
				table.insert(out, pane)
			end
		end
		for _, float in greed.floats({ hidden = true }) do
			table.insert(out, float)
		end
		local seen: { [number]: boolean } = {}
		for _, view in out do
			seen[view:id()] = true
		end
		for _, buffer in greed.buffers() do
			for _, view in buffer:views() do
				if not seen[view:id()] then
					seen[view:id()] = true
					table.insert(out, view)
				end
			end
		end
		return out
	end

	objects.kind({
		name = "editor",
		doc = "Greed itself: every kind of object there is to list",
		get = function(key: string): Object?
			return if key == ""
				then { kind = "editor", id = "editor:", label = "Greed", value = nil }
				else nil
		end,
		inspect = function(): { [string]: any }
			local project = greed.project.current()
			return {
				session = greed.session.current(),
				project = project.root,
				clients = #greed.client.list(),
				buffers = #greed.buffers(),
				tabs = #greed.tab.list(),
			}
		end,
		relations = function()
			local out = {}
			for _, kind in objects.kinds() do
				if kind.name ~= "editor" and kind.list then
					out[kind.name] = objects.list(kind.name)
				end
			end
			return out
		end,
	})

	objects.kind({
		name = "buffer",
		doc = "Text open in the editor: a file, or a page a plugin shows",
		list = function()
			local out = {}
			for _, buffer in greed.buffers() do
				table.insert(out, buffer_object(buffer))
			end
			return out
		end,
		get = function(key: string): Object?
			for _, buffer in greed.buffers() do
				if tostring(buffer:id()) == key then
					return buffer_object(buffer)
				end
			end
			return nil
		end,
		inspect = function(buffer: greed.Buffer): { [string]: any }
			return {
				path = buffer:path(),
				kind = buffer:kind(),
				language = buffer:language(),
				lines = buffer:line_count(),
				bytes = buffer:len(),
				modified = buffer:modified(),
				readonly = buffer:readonly(),
			}
		end,
		relations = function(buffer: greed.Buffer)
			local views = {}
			for _, view in buffer:views() do
				table.insert(views, view_object(view))
			end
			return { views = views }
		end,
	})

	objects.kind({
		name = "view",
		doc = "Where a buffer shows: a pane, a float or a panel",
		list = function()
			local out = {}
			for _, view in all_views() do
				table.insert(out, view_object(view))
			end
			return out
		end,
		get = function(key: string): Object?
			for _, view in all_views() do
				if tostring(view:id()) == key then
					return view_object(view)
				end
			end
			return nil
		end,
		inspect = function(view: greed.View): { [string]: any }
			local buffer = view:buffer()
			local cursor = view:cursor()
			local line = buffer:line_of(cursor)
			local area = view:area()
			return {
				place = place(view),
				focused = greed.view() == view,
				cursor = `{line + 1}:{cursor - buffer:line_start(line) + 1}`,
				size = if area then `{area.width}x{area.height}` else nil,
			}
		end,
		relations = function(view: greed.View)
			local related: { [string]: { Object } } = { buffer = { buffer_object(view:buffer()) } }
			for i, tab in greed.tab.list() do
				if table.find(tab.panes, view) then
					related.tab = { tab_object(tab, i) }
				end
			end
			return related
		end,
	})

	objects.kind({
		name = "tab",
		doc = "A tab: panes laid out together, with floats of its own",
		list = function()
			local out = {}
			for i, tab in greed.tab.list() do
				table.insert(out, tab_object(tab, i))
			end
			return out
		end,
		get = function(key: string): Object?
			local tab, i = tab_by_id(tonumber(key) or -1)
			return if tab then tab_object(tab, i) else nil
		end,
		inspect = function(id: number): { [string]: any }
			local tab = tab_by_id(id)
			if tab == nil then
				return { gone = true }
			end
			return {
				name = tab.name,
				current = tab.current,
				zoomed = tab.zoomed,
				panes = #tab.panes,
			}
		end,
		relations = function(id: number)
			local tab = tab_by_id(id)
			local panes = {}
			if tab then
				for _, pane in tab.panes do
					table.insert(panes, view_object(pane))
				end
			end
			return { panes = panes }
		end,
	})

	objects.kind({
		name = "plugin",
		doc = "A plugin: Luau code adding commands, keys, kinds and more",
		list = function()
			local out = {}
			for _, name in greed.plugin.list() do
				table.insert(out, plugin_object(name))
			end
			return out
		end,
		get = function(key: string): Object?
			return if greed.plugin.dirs()[key] then plugin_object(key) else nil
		end,
		inspect = function(name: string): { [string]: any }
			local dir = greed.plugin.dirs()[name]
			local capabilities = {}
			if dir then
				for _, capability in greed.plugin.describe(dir).capabilities do
					table.insert(capabilities, capability.name)
				end
			end
			return { dir = dir, capabilities = capabilities }
		end,
		relations = function(name: string)
			local dir = greed.plugin.dirs()[name]
			local requires = {}
			if dir then
				for _, other in greed.plugin.describe(dir).requires do
					table.insert(requires, plugin_object(other))
				end
			end
			return { requires = requires }
		end,
	})

	objects.kind({
		name = "client",
		doc = "A terminal or window showing the session",
		list = function()
			local out = {}
			for _, client in greed.client.list() do
				table.insert(out, {
					kind = "client",
					id = `client:{client.id}`,
					label = client.name,
					value = client,
				})
			end
			return out
		end,
		inspect = function(client: greed.ClientInfo): { [string]: any }
			return {
				kind = client.kind,
				remote = client.remote,
				size = if client.size then `{client.size.width}x{client.size.height}` else nil,
			}
		end,
	})

	-- Files and folders, as finders and pickers name them, by their path.
	for _, kind in { "file", "folder" } do
		objects.kind({
			name = kind,
			doc = if kind == "file" then "A file, by its path" else "A folder, by its path",
			get = function(path: string): Object?
				local stat = greed.fs.stat(path)
				local is = if stat and stat.kind == "dir" then "folder" else "file"
				return if stat and is == kind
					then { kind = kind, id = `{kind}:{path}`, label = path, value = path }
					else nil
			end,
			inspect = function(path: string): { [string]: any }
				local stat = greed.fs.stat(path)
				if stat == nil then
					return { path = path, gone = true }
				end
				return { path = path, size = stat.size, modified = stat.modified }
			end,
		})
	end

	-- What every one of these can do, wherever it shows up.
	actions.action({
		kind = "buffer",
		name = "show",
		doc = "Show it in the focused view",
		run = function(target)
			greed.view():show(target.value)
		end,
	})
	actions.action({
		kind = "buffer",
		name = "close",
		doc = "Close it, as :bc does: views showing it show another file; refuses with unsaved changes",
		run = function(target)
			require("./file").close(target.value)
		end,
	})
	actions.action({
		kind = "view",
		name = "focus",
		doc = "Go to it",
		run = function(target)
			target.value:focus()
		end,
	})
	actions.action({
		kind = "tab",
		name = "show",
		doc = "Show this tab",
		run = function(target)
			greed.tab.switch(target.value)
		end,
	})
end
