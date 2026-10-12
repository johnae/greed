local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")
local shell = require("@shell")

test("a block is an object: its command and how it ended, acted on from anywhere", function(t)
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = t:tempdir({ ["lines.sh"] = "echo one\necho two\n" })
	local block = assert(shell.run(sh, "sh lines.sh", { view = greed.view() }))
	t:wait_for(function()
		return block.status ~= "running"
	end)
	local id = `shell-block:{sh.buffer:id()}.{block.number}`
	local found = assert(core.objects.get(id))
	local listed = false
	for _, object in core.objects.list("shell-block") do
		listed = listed or object.id == id
	end
	assert(listed, "listed")
	local state = core.objects.inspect(found)
	assert(state.command == "sh lines.sh" and state.status == "done", greed.json.encode(state))
	assert(state.exit_code == 0 and state.lines == 2, greed.json.encode(state))
	assert(core.objects.related(found).shell[1].id == `shell:{sh.buffer:id()}`)
	-- Under the cursor, it's the same object.
	greed.view():set_cursor(assert(found.from))
	local here = false
	for _, object in core.objects.at(greed.view()) do
		here = here or object.id == id
	end
	assert(here, "found under the cursor")
	-- Run again from a float, as the inspector would.
	greed.float(greed.create_buffer("elsewhere", "elsewhere"))
	local count = #sh.blocks
	assert(core.objects.act(found, "rerun"))
	t:wait_for(function()
		return #sh.blocks > count and sh.blocks[#sh.blocks].status ~= "running"
	end)
	assert(sh.blocks[#sh.blocks].command == "sh lines.sh")
end)

test("a shell is an object, with its blocks, and shows by default", function(t)
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = t:tempdir({})
	local block = assert(shell.run(sh, "echo hi", { view = greed.view() }))
	t:wait_for(function()
		return block.status ~= "running"
	end)
	local object = assert(core.objects.get(`shell:{sh.buffer:id()}`))
	local state = core.objects.inspect(object)
	assert(state.blocks == 1 and state.folder == sh.cwd, greed.json.encode(state))
	local blocks = core.objects.related(object).blocks
	assert(blocks and #blocks == 1 and blocks[1].kind == "shell-block", "its blocks")
	local up = core.objects.related(blocks[1]).shell
	assert(up and up[1].id == object.id, "a block's shell")
	assert(core.objects.actions(object)[1].name == "show")
end)
