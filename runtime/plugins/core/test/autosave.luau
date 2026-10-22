local test = require("@greed/test")
local greed = require("@greed")

test("with auto-save on, a file is saved once its edits stop", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one\n" })
	local path = dir .. "/a.txt"
	greed.open(path)
	greed.option.set("auto-save", true)
	t:keys("i x esc")
	t:wait(500)
	t:keys("i y esc")
	t:wait(500)
	assert(greed.fs.read(path) == "one\n", "not while the edits keep coming")
	t:wait(600)
	assert(greed.fs.read(path) == "xyone\n", tostring((greed.fs.read(path))))
	assert(not greed.view():buffer():modified())
end)

test("auto-save is off unless asked for", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one\n" })
	local path = dir .. "/a.txt"
	greed.open(path)
	t:keys("i x esc")
	t:wait(2000)
	assert(greed.fs.read(path) == "one\n")
	assert(greed.view():buffer():modified())
end)

test(
	"auto-save waits as long as auto-save-delay says, and leaves buffers without files",
	function(t)
		local dir = t:tempdir({ ["a.txt"] = "one\n" })
		local path = dir .. "/a.txt"
		greed.option.set("auto-save", true)
		greed.option.set("auto-save-delay", 3000)
		t:buffer("|scratch")
		t:keys("i x esc")
		t:wait(3500)
		greed.open(path)
		t:keys("i x esc")
		t:wait(2000)
		assert(greed.fs.read(path) == "one\n", "not yet")
		t:wait(1500)
		assert(greed.fs.read(path) == "xone\n", tostring((greed.fs.read(path))))
	end
)

test("enabling auto-save seeds dirty files and uses manual save hooks", function(t)
	local core = require("@core")
	local dir = t:tempdir({ ["a.txt"] = "one" })
	greed.open(dir .. "/a.txt")
	local buffer = greed.view():buffer()
	local calls = 0
	core.file.before_save("seed-test", function(b)
		calls += 1
		b:edit(function(e)
			e:replace(0, 0, "hook ")
		end)
	end)
	buffer:edit(function(e)
		e:replace(0, 0, "new ")
	end)
	greed.option.set("auto-save-delay", 30)
	greed.option.set("auto-save", true)
	t:wait_for(function()
		return not buffer:modified()
	end, 1500)
	assert(greed.fs.read(dir .. "/a.txt") == "hook new one")
	assert(calls == 1)
	core.file.save(buffer)
	assert(greed.fs.read(dir .. "/a.txt") == "hook hook new one")
	assert(calls == 2)
end)

test("overlapping saves share hooks and release every waiter", function(t)
	local core = require("@core")
	local dir = t:tempdir({ ["a.txt"] = "one" })
	greed.open(dir .. "/a.txt")
	local buffer = greed.view():buffer()
	buffer:edit(function(e)
		e:replace(0, 0, "new ")
	end)
	local entered = false
	local calls = 0
	core.file.before_save("overlap-test", function()
		entered = true
		calls += 1
		greed.sleep(50)
	end)
	local completed = 0
	greed.spawn(function()
		core.file.save(buffer)
		completed += 1
	end)
	t:wait_for(function()
		return entered
	end, 1500)
	for _ = 1, 2 do
		greed.spawn(function()
			core.file.save(buffer)
			completed += 1
		end)
	end
	t:wait_for(function()
		return completed == 3
	end, 1500)
	assert(calls == 1)
	assert(greed.fs.read(dir .. "/a.txt") == "new one")
end)

test("overlapping failed writes report failure to every caller", function(t)
	local core = require("@core")
	local dir = t:tempdir({ ["a.txt"] = "one" })
	greed.open(dir .. "/a.txt")
	local buffer = greed.view():buffer()
	local release = greed.signal()
	local entered = false
	core.file.before_save("failed-write-test", function()
		entered = true
		release:wait()
		-- A shown buffer cannot be closed; hook errors alone do not abort a save.
		greed.view():show(greed.create_buffer("test", ""))
		buffer:close()
	end)
	local failed = 0
	local function save()
		if not pcall(core.file.save, buffer, nil, nil, nil) then
			failed += 1
		end
	end
	greed.spawn(save)
	t:wait_for(function()
		return entered
	end, 1500)
	for _ = 1, 2 do
		greed.spawn(save)
	end
	release:send()
	t:wait_for(function()
		return failed == 3
	end, 1500)
	assert(greed.fs.read(dir .. "/a.txt") == "one")
end)

test("unloading a foreign save caller releases waiters and permits another save", function(t)
	local core = require("@core")
	local dir = t:tempdir({ ["a.txt"] = "one" })
	greed.open(dir .. "/a.txt")
	local buffer = greed.view():buffer()
	local plugin = t:tempdir({
		["init.luau"] = [[
local greed = require("@greed")
local core = require("@core")
core.file.before_save("cancel-save-test", function() greed.sleep(1000) end)
greed.spawn(function() core.file.save(greed.view():buffer()) end)
]],
	})
	greed.plugin.load(plugin, "cancel-save-test")
	local failed = 0
	for _ = 1, 2 do
		greed.spawn(function()
			if not pcall(core.file.save, buffer, nil, nil, nil) then
				failed += 1
			end
		end)
	end
	buffer:edit(function(e)
		e:replace(0, 0, "new ")
	end)
	greed.plugin.unload("cancel-save-test")
	t:wait_for(function()
		return failed == 2
	end, 1500)
	core.file.save(buffer)
	assert(greed.fs.read(dir .. "/a.txt") == "new one")
	assert(not buffer:modified())
end)

test("kind-specific quiet keepers still run with file auto-save disabled", function(t)
	local core = require("@core")
	greed.option.set("auto-save", false)
	greed.option.set("auto-save-delay", 30)
	local buffer = greed.create_buffer("quiet-test", "one")
	greed.view():show(buffer)
	local kept
	core.autosave.on_quiet("quiet-test", function(b)
		kept = b:text()
	end)
	buffer:edit(function(e)
		e:replace(0, 0, "new ")
	end)
	t:wait_for(function()
		return kept ~= nil
	end, 1500)
	assert(kept == "new one")
end)

test("a queued save as can recover from another destination's write failure", function(t)
	local core = require("@core")
	local dir = t:tempdir({ ["a.txt"] = "one" })
	local path, backup = dir .. "/a.txt", dir .. "/backup.txt"
	greed.open(path)
	local buffer = greed.view():buffer()
	buffer:edit(function(e)
		e:replace(0, 0, "new ")
	end)
	core.file.before_save("delayed-save", function()
		greed.sleep(10)
	end)
	local first_ok, second_done
	greed.spawn(function()
		first_ok = pcall(core.file.save, buffer, nil, nil, nil)
	end)
	assert(greed.fs.remove(path))
	assert(greed.fs.mkdir(path))
	greed.spawn(function()
		core.file.save(buffer, backup)
		second_done = true
	end)
	t:wait(100)
	assert(first_ok == false)
	assert(second_done == true)
	assert(greed.fs.read(backup) == "new one")
	assert(buffer:path() == backup)
end)

test("enabling file auto-save does not seed kind-specific quiet keepers", function(t)
	local core = require("@core")
	local buffer = greed.create_buffer("quiet-test", "one")
	greed.view():show(buffer)
	buffer:edit(function(e)
		e:replace(0, 0, "new ")
	end)
	local kept = false
	core.autosave.on_quiet("quiet-test", function()
		kept = true
	end)
	greed.option.set("auto-save-delay", 30)
	greed.option.set("auto-save", true)
	t:wait(100)
	assert(not kept)
end)
