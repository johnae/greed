local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")

local ran: { string } = {}
for _, name in { "keys-base", "keys-hidden" } do
	greed.command({
		name = name,
		run = function()
			table.insert(ran, name)
		end,
	})
end
greed.command({
	name = "keys-ours",
	run = function(ctx)
		table.insert(ran, "keys-ours")
		core.keys.otherwise(ctx.keys or "", "keys-ours")
	end,
})

greed.keymap.bind({}, { ["ctrl-alt-k"] = "keys-base" })
greed.keymap.bind({ kind = "test-keys" }, { ["ctrl-alt-k"] = "keys-hidden" })
greed.keymap.bind({ kind = "test-keys" }, { ["ctrl-alt-k"] = "keys-ours" })

test("otherwise runs what the key does in the layers under the command's own", function(t)
	t:buffer("|")
	greed.view():show(greed.create_buffer("test-keys", ""))
	table.clear(ran)
	t:keys("ctrl-alt-k")
	-- keys-hidden is in the command's own layer, so it's skipped.
	assert(table.concat(ran, ",") == "keys-ours,keys-base", table.concat(ran, ","))
end)

test("otherwise runs nothing when nothing is under the command", function(t)
	t:buffer("|")
	table.clear(ran)
	assert(not core.keys.otherwise("ctrl-alt-k", "keys-ours"), "not bound here")
	assert(not core.keys.otherwise("ctrl-alt-j", "keys-ours"), "nothing bound")
	assert(#ran == 0, table.concat(ran, ","))
end)
