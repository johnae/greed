-- Undo kept across restarts: saved with each save, back when the file is
-- opened again unchanged.

local test = require("@greed/test")
local greed = require("@greed")

-- Closes `path`'s buffer, the view showing something else first.
local function close(path: string)
	greed.view():show(greed.create_buffer("scratch", ""))
	for _, buffer in greed.buffers() do
		if buffer:path() == path then
			buffer:close()
		end
	end
end

-- Opens `path` afresh, as after a restart.
local function reopen(path: string)
	close(path)
	greed.open(path)
end

test("a saved file's undo comes back when it's opened again", function(t)
	local dir = t:tempdir({ ["a.txt"] = "hello" })
	local path = `{dir}/a.txt`
	greed.open(path)
	t:keys("A space w o r l d esc")
	t:run("save")
	reopen(path)
	assert(greed.view():buffer():text() == "hello world", greed.view():buffer():text())
	assert(not greed.view():buffer():modified(), "as it was saved")
	t:keys("u")
	assert(greed.view():buffer():text() == "hello", greed.view():buffer():text())
end)

test("a file changed by something else since starts afresh", function(t)
	local dir = t:tempdir({ ["a.txt"] = "hello" })
	local path = `{dir}/a.txt`
	greed.open(path)
	t:keys("A space w o r l d esc")
	t:run("save")
	close(path)
	greed.fs.write(path, "changed elsewhere")
	greed.open(path)
	t:keys("u")
	assert(greed.view():buffer():text() == "changed elsewhere", "nothing to undo")
end)

test("files named like secrets, and with undo-files off, aren't kept", function(t)
	local files = require("../undo_files")
	assert(files.secret("/p/.env") and files.secret("/p/.env.local"))
	assert(files.secret("/p/server.pem") and files.secret("/home/me/.ssh/id_ed25519"))
	assert(not files.secret("/p/main.rs"))
	local dir = t:tempdir({ [".env"] = "A=1", ["b.txt"] = "b" })
	greed.open(`{dir}/.env`)
	t:keys("A 2 esc")
	t:run("save")
	reopen(`{dir}/.env`)
	t:keys("u")
	assert(greed.view():buffer():text() == "A=12", "a secret's undo isn't kept")
	greed.option.set("undo-files", false)
	greed.open(`{dir}/b.txt`)
	t:keys("A c esc")
	t:run("save")
	reopen(`{dir}/b.txt`)
	t:keys("u")
	assert(greed.view():buffer():text() == "bc", "off, nothing's kept")
	greed.option.set("undo-files", true)
end)
