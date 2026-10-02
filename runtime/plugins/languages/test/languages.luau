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

test("set with no servers stops starting one", function()
	local before = (languages.get("python") :: languages.Language).servers
	languages.set("python", { servers = { { "pylsp" } } })
	assert(kern.lsp.servers().python[1][1] == "pylsp", "set")
	languages.set("python", { servers = {} })
	assert(kern.lsp.servers().python == nil, "removed")
	languages.set("python", { servers = before })
end)

test("each language's comment is what ctrl-c uses", function()
	local core = require("@core")
	assert(core.comment.token("rust") == "//", tostring(core.comment.token("rust")))
	assert(core.comment.token("python") == "#")
	languages.set("odin", { comment = "//" })
	assert(core.comment.token("odin") == "//")
end)

test("every language's syntax objects query works with its grammar", function(t)
	for _, name in kern.grammars() do
		local language = languages.get(name)
		local source = language and language.textobjects
		if source then
			t:buffer("|")
			local buffer = kern.view():buffer()
			buffer:set_language(name)
			local ok, err = pcall(function()
				return buffer:query(source :: string)
			end)
			assert(ok, `{name}: {err}`)
		end
	end
end)

test("m a f selects a Luau function", function(t)
	t:buffer("local function f(a, b)\n\treturn |a\nend\n")
	kern.view():buffer():set_language("luau")
	t:keys("m a f")
	t:expect("^local function f(a, b)\n\treturn a\nend|\n")
	t:buffer("local function f(a, |b)\nend\n")
	kern.view():buffer():set_language("luau")
	t:keys("m a a")
	t:expect("local function f(a^, b|)\nend\n")
end)
