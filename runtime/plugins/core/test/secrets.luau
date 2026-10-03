local test = require("@kern/test")
local kern = require("@kern")

test(":secret-set keeps a secret behind dots, and kern.secrets.get finds it", function(t)
	t:buffer("|x")
	t:run("secret-set", { "kern-test" })
	t:keys("s 3 c r e t")
	local marks = kern.view():buffer():decorations("prompt-secret")
	assert(marks[1] and marks[1].text == "••••••", "dots over what's typed")
	t:keys("enter")
	t:wait(100)
	local messages = t:messages()
	assert(string.find(messages[#messages], "kept kern-test in", 1, true), messages[#messages])
	local found
	kern.spawn(function()
		found = kern.secrets.get("kern-test")
	end)
	t:wait(100)
	assert(found == "s3cret", tostring(found))
end)

test("the secrets file can't be read or written as a file", function(t)
	local home = kern.fs.dirs().home :: string
	local file = home .. "/state/secrets.json"
	kern.fs.write(home .. "/state/other.txt", "x")
	local ok, err = pcall(kern.fs.read, file, nil)
	assert(
		not ok and string.find(tostring(err), "only read through kern.secrets", 1, true),
		tostring(err)
	)
	ok = pcall(kern.fs.write, file, "{}")
	assert(not ok, "nor written")
end)

test("a plugin reads only the secrets it declares", function(t)
	local dir = t:tempdir({
		["plugin.toml"] = 'name = "asker"\ncapabilities = ["secrets:mine"]\n',
		["init.luau"] = 'local kern = require("@kern")\n'
			.. 'kern.command({ name = "asker-go", run = function()\n'
			.. '  local ok, err = pcall(kern.secrets.get, "theirs")\n'
			.. '  kern.echo(if ok then "read it" else tostring(err))\n'
			.. "end })\n",
	})
	kern.plugin.load(dir, nil)
	t:buffer("|x")
	t:run("asker-go")
	t:wait(50)
	local messages = t:messages()
	assert(string.find(messages[#messages], 'add "secrets:theirs"', 1, true), messages[#messages])
end)
