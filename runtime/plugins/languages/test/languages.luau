local test = require("@kern/test")
local kern = require("@kern")
local languages = require("@languages")

test("files get their language from the table", function()
	assert(kern.language_of("main.py") == "python", tostring(kern.language_of("main.py")))
	assert(kern.language_of("flake.nix") == "nix", "nix")
	assert(kern.language_of("Makefile") == "make", "by name")
	assert(kern.language_of("notes.zz") == nil, "unknown")
end)

test("set changes the fields it's given and keeps the rest", function()
	languages.set("python", { extensions = { "pyx" } })
	assert(kern.language_of("a.pyx") == "python", "new extension")
	assert(kern.language_of("a.py") == nil, "old one gone")
	local python = languages.get("python") :: languages.Language
	assert(python.comment == "#", "the rest stays")

	languages.set("odin", { extensions = { "odin" }, comment = "//" })
	assert(kern.language_of("main.odin") == "odin", "new languages work too")
	assert(table.find(languages.list(), "odin"), "and are listed")
end)

test(":health lists each language with its highlighting and servers", function(t)
	t:buffer("|x")
	t:run("health")
	local report = t:floats()[1]
	assert(string.find(report, "rust%s+highlighting%s+rust%-analyzer"), report)
	assert(
		string.find(
			report,
			"python%s+no grammar%s+basedpyright%-langserver, pyright%-langserver, pylsp"
		),
		report
	)
	t:keys("q")
	assert(#t:floats() == 0, "q closes it")
end)
