local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")
local languages = require("@languages")

-- Opens a file in a language whose formatter squeezes runs of spaces, and
-- fails on "oops". Returns the file's path.
local function squeezing(t: test.TestContext, text: string): string
	languages.set("squeezed", {
		extensions = { "sq" },
		formatter = {
			"sh",
			"-c",
			"input=$(cat); case $input in *oops*) echo 'bad input' >&2; exit 1;; esac; printf %s \"$input\" | tr -s ' '",
		},
	})
	local dir = t:tempdir({ ["a.sq"] = text })
	-- Formatting on save runs only in a project you trusted.
	core.project.trust(dir)
	greed.open(dir .. "/a.sq")
	return dir .. "/a.sq"
end

test("saving in a project you haven't trusted doesn't run its formatter", function(t)
	greed.option.set("project-trust", "ask")
	languages.set("squeezed", { extensions = { "sq" }, formatter = { "tr", "-s", " " } })
	local dir = t:tempdir({ ["a.sq"] = "one    two" })
	greed.open(dir .. "/a.sq")
	t:run("save")
	assert(greed.fs.read(dir .. "/a.sq") == "one    two", (greed.fs.read(dir .. "/a.sq")))
end)

test("saving formats the file, changing only what the formatter changed", function(t)
	local path = squeezing(t, "one    two three")
	t:keys("g l b")
	t:expect("one    two |three^")
	t:run("save")
	assert(greed.fs.read(path) == "one two three", (greed.fs.read(path)))
	t:expect("one two |three^")
end)

test(
	"a formatter that fails leaves the text alone and says why; the file is still saved",
	function(t)
		local path = squeezing(t, "oops  here")
		t:run("save")
		assert(greed.fs.read(path) == "oops  here", (greed.fs.read(path)))
		local said = table.concat(t:messages(), "\n")
		assert(string.find(said, "bad input", 1, true), said)
	end
)

test(":format formats without saving, and format-on-save off leaves saving alone", function(t)
	local path = squeezing(t, "a   b")
	greed.option.set("format-on-save", false)
	t:run("save")
	assert(greed.fs.read(path) == "a   b")
	t:run("format")
	assert(greed.view():buffer():text() == "a b")
	assert(greed.view():buffer():modified(), "not saved")
	greed.option.set("format-on-save", true)
end)

test("a formatter that isn't installed is skipped", function(t)
	languages.set("missing", { extensions = { "miss" }, formatter = { "no-such-formatter-here" } })
	local dir = t:tempdir({ ["a.miss"] = "x  y" })
	greed.open(dir .. "/a.miss")
	t:run("format")
	assert(greed.view():buffer():text() == "x  y")
	local messages = t:messages()
	assert(messages[#messages] == "nothing to format this with", messages[#messages])
end)

test("formatting next to characters of more than one byte keeps them whole", function(t)
	languages.set(
		"accents",
		{ extensions = { "acc" }, formatter = { "sh", "-c", "sed 's/é/è/'" } }
	)
	local dir = t:tempdir({ ["a.acc"] = "café\n" })
	greed.open(dir .. "/a.acc")
	t:run("format")
	assert(greed.view():buffer():text() == "cafè\n", greed.view():buffer():text())
end)
