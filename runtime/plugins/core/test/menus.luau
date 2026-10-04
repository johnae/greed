local test = require("@greed/test")
local menus = require("@core").menus

local function titles(): { string }
	local out = {}
	for _, menu in menus.list() do
		table.insert(out, menu.title)
	end
	return out
end

local function labels(title: string): { string }
	for _, menu in menus.list() do
		if menu.title == title then
			local out = {}
			for _, item in menu.items do
				table.insert(out, item.label)
			end
			return out
		end
	end
	return {}
end

test("the menus hold the commands there are, Help last", function(t)
	t:buffer("|")
	local all = titles()
	assert(all[1] == "File", table.concat(all, " "))
	local help = table.find(all, "Help")
	assert(help == nil or help == #all, "Help, when there is one, is last")
	local file = table.concat(labels("File"), ", ")
	assert(string.find(file, "Save", 1, true), file)
end)

test("plugins add items and take them away; new menus go before Help", function(t)
	t:buffer("|")
	local remove = menus.add("Tools", "Undo it", "undo")
	local all = titles()
	local tools = table.find(all, "Tools") :: number
	local help = table.find(all, "Help")
	assert(if help then tools == help - 1 else tools == #all, table.concat(all, " "))
	assert(labels("Tools")[1] == "Undo it")
	local gone = menus.add("Tools", "Nothing", "no-such-command")
	assert(#labels("Tools") == 1, "an item without its command is left out")
	remove()
	gone()
	assert(not table.find(titles(), "Tools"), "an emptied menu goes")
end)
