local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")
local shell = require("@shell")

type Shell = typeof(shell.open())
type Block = typeof(assert(shell.run(shell.open(), "true")))

-- A shell whose `docker` and `ps` print tables for `ps` and say what they
-- were asked otherwise.
local function fake(t: test.TestContext): (Shell, string)
	local dir = t:tempdir({
		["bin/docker"] = '#!/bin/sh\nif [ "$1" = "ps" ]; then\n  printf "CONTAINER ID   IMAGE      NAMES\\n3f2a1b4c5d6e   nginx      web\\n"\nelse\n  echo "docker $*"\nfi\n',
		-- The same ps everywhere: macOS's prints other columns than Linux's.
		["bin/ps"] = '#!/bin/sh\nprintf "USER         PID %%CPU %%MEM COMMAND\\nroot           1  0.0  0.1 /sbin/init\\nme          4711  1.5  2.0 greed\\n"\n',
	})
	assert(greed.process.run({ "chmod", "+x", `{dir}/bin/docker`, `{dir}/bin/ps` }))
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = dir
	local path = assert(greed.process.run({ "printenv", "PATH" })).stdout
	sh.env.PATH = `{dir}/bin:{string.gsub(path, "\n$", "")}`
	return sh, dir
end

local function ran(t: test.TestContext, sh: Shell, line: string): Block
	local block = assert(shell.run(sh, line, { view = greed.view() }))
	t:wait_for(function()
		return block.status ~= "running"
	end)
	return block
end

-- Puts the cursor on the line of `block`'s output holding `text`.
local function on(sh: Shell, block: Block, text: string)
	local from = shell.log.output_range(sh, block)
	assert(from, "a block with output")
	local at = assert(string.find(sh.buffer:text(), text, from + 1, true), text)
	greed.view():set_cursor(at - 1)
end

-- The thing of `kind` at the cursor, as `space .` finds it.
local function thing_here(kind: string): core.Target?
	for _, target in core.actions.at(greed.view()) do
		if target.kind == kind then
			return target
		end
	end
	return nil
end

-- Runs action `name` on `target` and gives back the block it ran.
local function act(t: test.TestContext, sh: Shell, target: any, name: string): Block
	local count = #sh.blocks
	for _, action in core.actions.for_kind(target.kind) do
		if action.name == name then
			action.run(target)
		end
	end
	t:wait_for(function()
		local last = sh.blocks[#sh.blocks]
		return #sh.blocks > count and last.status ~= "running"
	end)
	return sh.blocks[#sh.blocks]
end

test("ls -l's rows are files and folders; enter opens one and goes into the other", function(t)
	local sh = fake(t)
	greed.fs.write(`{sh.cwd}/notes.txt`, "hello\n")
	local listing = ran(t, sh, "ls -l")
	assert(listing.called and listing.called.many == "files")
	on(sh, listing, "notes.txt")
	local file = assert(thing_here("file"))
	assert(file.value == `{sh.cwd}/notes.txt`, tostring(file.value))
	t:keys("esc")
	on(sh, listing, "notes.txt")
	local row = greed.view():cursor()
	t:keys("enter")
	assert(greed.view():buffer():path() == `{sh.cwd}/notes.txt`, "opened")
	-- Back comes to the row it opened from, forward to the file again.
	t:run("jump-back")
	assert(greed.view():buffer() == sh.buffer, "back in the shell")
	assert(greed.view():cursor() == row, `{greed.view():cursor()} ~= {row}`)
	t:run("jump-forward")
	assert(greed.view():buffer():path() == `{sh.cwd}/notes.txt`, "forward to the file")
end)

test("ps's rows are processes and docker ps's containers", function(t)
	local sh = fake(t)
	local listed = ran(t, sh, "ps aux")
	assert(listed.called and listed.called.many == "processes")
	on(sh, listed, "4711")
	local me = assert(thing_here("process"))
	local folder = act(t, sh, me, "its folder")
	assert(folder.command == "lsof -a -d cwd -p 4711", folder.command)
	local containers = ran(t, sh, "docker ps")
	assert(containers.called and containers.called.many == "containers")
	on(sh, containers, "nginx")
	local web = assert(thing_here("container"))
	assert(web.label == "web")
	local logs = act(t, sh, web, "logs")
	assert(logs.command == "docker logs --tail 200 web", logs.command)
	assert(string.find(logs.output, "docker logs --tail 200 web", 1, true), logs.output)
end)

-- What completion offers with `text` at `sh`'s prompt, in order.
local function offered(
	t: test.TestContext,
	sh: Shell,
	text: string
): { { label: string, detail: string? } }
	shell.log.set_prompt(sh, text, { greed.view() })
	local found: { any }? = nil
	greed.spawn(function()
		found = shell.completion.items(greed.view(), { explicit = true }) or {}
	end)
	t:wait_for(function()
		return found ~= nil
	end, 10000)
	return assert(found)
end

local function labels(items: { { label: string, detail: string? } }): string
	local out = {}
	for _, item in items do
		table.insert(out, item.label)
	end
	return table.concat(out, ",")
end

test(
	"completion offers processes for kill and containers for docker, from blocks above",
	function(t)
		local sh = fake(t)
		local listed = ran(t, sh, "ps aux")
		local kill = offered(t, sh, "kill ")
		assert(kill[1] and string.match(kill[1].label, "^%d+$"), labels(kill))
		assert(
			string.find(kill[1].detail or "", `${listed.number}`, 1, true),
			tostring(kill[1].detail)
		)
		ran(t, sh, "docker ps")
		assert(offered(t, sh, "docker logs --tail 50 ")[1].label == "web")
		-- A one-word alias or a path to the program counts as it.
		shell.aliases.use({ d = "docker" })
		assert(offered(t, sh, "d logs ")[1].label == "web")
		assert(offered(t, sh, `{sh.cwd}/bin/docker logs `)[1].label == "web")
		shell.aliases.use(nil)
	end
)

-- The ids of `objects`, in order.
local function ids(objects: { core.Object }): string
	local out = {}
	for _, object in objects do
		table.insert(out, object.id)
	end
	return table.concat(out, ",")
end

test("process rows are process:PID and container rows container:NAME", function(t)
	local sh = fake(t)
	ran(t, sh, "ps aux")
	local process = assert(core.objects.get("process:4711"))
	assert(process.label == "4711 greed", process.label)
	assert(core.objects.inspect(process).row["%CPU"] == "1.5")
	ran(t, sh, "docker ps")
	local web = assert(core.objects.get("container:web"))
	assert(core.objects.inspect(web).row.IMAGE == "nginx")
end)

test("the rows of a table no kind reads are plain rows of their block", function(t)
	local sh = fake(t)
	greed.fs.write(`{sh.cwd}/fruit.txt`, "NAME    COLOR\napple   red\npear    green\n")
	local fruit = ran(t, sh, "cat fruit.txt")
	local block = assert(core.objects.get(`shell-block:{sh.buffer:id()}.{fruit.number}`))
	local rows = assert(core.objects.related(block).rows)
	local prefix = `row:{sh.buffer:id()}.{fruit.number}`
	assert(ids(rows) == `{prefix}.1,{prefix}.2`, ids(rows))
	local pear = assert(core.objects.get(`{prefix}.2`))
	assert(pear.kind == "row" and pear.label == "pear", pear.label)
	assert(core.objects.inspect(pear).COLOR == "green")
	assert(assert(core.objects.related(pear).block)[1].id == block.id)
	on(sh, fruit, "pear")
	assert(string.find(ids(core.objects.at(greed.view())), `{prefix}.2`, 1, true) ~= nil)
	-- A filter shows fewer rows; the objects stay where they are.
	shell.rows.set(sh, fruit, "pear")
	local still = assert(core.objects.get(`{prefix}.2`))
	local from = assert(still.from)
	assert(string.sub(sh.buffer:text(), from + 1, from + 4) == "pear", "on its line")
	assert(assert(core.objects.get(`{prefix}.1`)).from == nil, "apple isn't shown")
	on(sh, fruit, "pear")
	assert(string.find(ids(core.objects.at(greed.view())), `{prefix}.2`, 1, true) ~= nil)
end)

test("a PID column makes rows processes, whatever printed them", function(t)
	local sh = fake(t)
	greed.fs.write(
		`{sh.cwd}/open.txt`,
		"COMMAND    PID USER   FD   TYPE NAME\nnginx     812 root    6u  IPv4 *:http\nsshd      977 root    3u  IPv4 *:ssh\n"
	)
	local open = ran(t, sh, "cat open.txt")
	assert(open.called and open.called.many == "processes", "read by its columns")
	local nginx = assert(core.objects.get("process:812"))
	assert(nginx.label == "812 nginx" and core.objects.inspect(nginx).row.FD == "6u", nginx.label)
	-- nu's ps names its columns in lower case.
	greed.fs.write(`{sh.cwd}/ps.json`, '[{"pid": 42, "ppid": 1, "name": "fish", "cpu": 0.1}]')
	ran(t, sh, "cat ps.json")
	assert(assert(core.objects.get("process:42")).label == "42 fish")
end)

test("name and type columns of files and folders make rows files, as nu's ls prints", function(t)
	local sh = fake(t)
	greed.fs.write(
		`{sh.cwd}/ls.json`,
		'[{"name": "notes.txt", "type": "file", "size": 6}, {"name": "src", "type": "dir", "size": 0}]'
	)
	local listing = ran(t, sh, "cat ls.json")
	assert(listing.called and listing.called.many == "files")
	local ids_of = ids(
		core.objects.related(
			assert(core.objects.get(`shell-block:{sh.buffer:id()}.{listing.number}`))
		).rows or {}
	)
	assert(ids_of == `file:{sh.cwd}/notes.txt,folder:{sh.cwd}/src`, ids_of)
	-- A type that isn't a file's (lsblk's disks) isn't read as files.
	greed.fs.write(`{sh.cwd}/disks.txt`, "NAME   TYPE  SIZE\nsda    disk  1T\nsda1   part  512M\n")
	assert(ran(t, sh, "cat disks.txt").called == nil, "not files")
end)

test("a cell is an object to copy or filter by, and a plain row copies as text or JSON", function(t)
	local sh = fake(t)
	greed.fs.write(`{sh.cwd}/fruit.txt`, "NAME    COLOR\napple   red\npear    green\n")
	local fruit = ran(t, sh, "cat fruit.txt")
	on(sh, fruit, "green")
	local here = core.objects.at(greed.view())
	local cell = `cell:{sh.buffer:id()}.{fruit.number}.2.COLOR`
	assert(here[1].id == cell and here[1].label == "COLOR: green", ids(here))
	assert(here[2].id == `row:{sh.buffer:id()}.{fruit.number}.2`, ids(here))
	local found = assert(core.objects.get(cell))
	assert(assert(core.objects.related(found).row)[1].label == "pear")
	assert(core.objects.act(found, "copy"))
	assert(assert(greed.clipboard.get())[1] == "green")
	assert(core.objects.act(found, "filter by this"))
	assert(fruit.shown and fruit.shown.filter == "COLOR=green", "filtered")
	assert(#fruit.shown.rows == 1 and fruit.shown.rows[1] == 2)
	-- The row, as text and as JSON.
	local row = here[2]
	assert(core.objects.act(row, "copy"))
	assert(assert(greed.clipboard.get())[1] == "pear\tgreen")
	assert(core.objects.act(row, "copy as JSON"))
	local copied = greed.json.decode(assert(greed.clipboard.get())[1])
	assert(copied.NAME == "pear" and copied.COLOR == "green")
end)

test("filtering by a cell with spaces keeps the rows with its words", function(t)
	local sh = fake(t)
	ran(t, sh, "docker ps")
	local status = ran(t, sh, "docker ps")
	local cell = assert(core.objects.get(`cell:{sh.buffer:id()}.{status.number}.1.CONTAINER ID`))
	assert(core.objects.act(cell, "filter by this"))
	assert(
		status.shown and status.shown.filter == "3f2a1b4c5d6e",
		tostring(status.shown and status.shown.filter)
	)
end)
