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

test("the bundled query files load, each working with its grammar", function()
	local problems = languages.load_queries()
	assert(#problems == 0, table.concat(problems, "\n"))
	for _, name in { "rust", "luau", "json", "toml", "markdown" } do
		assert(kern.syntax.query(name, "textobjects"), `{name} has no textobjects query`)
	end
end)

test("a plugin's query files replace or extend the bundled ones, until it goes", function(t)
	local bundled = kern.syntax.query("rust", "textobjects") :: string
	local dir = t:tempdir({
		["more/plugin.toml"] = 'name = "more"\n',
		["more/init.luau"] = "",
		["more/queries/rust/textobjects.scm"] = "; extends\n(macro_invocation) @function.around\n",
		["other/plugin.toml"] = 'name = "other"\n',
		["other/init.luau"] = "",
		["other/queries/rust/textobjects.scm"] = "(line_comment) @comment.around\n",
		["broken/plugin.toml"] = 'name = "broken"\n',
		["broken/init.luau"] = "",
		["broken/queries/rust/folds.scm"] = "(no_such_node) @fold\n",
	})
	kern.plugin.load(dir .. "/more")
	local extended = kern.syntax.query("rust", "textobjects") :: string
	assert(string.find(extended, bundled, 1, true), "the bundled query stays")
	assert(string.find(extended, "macro_invocation", 1, true), "and the plugin's is added")

	-- Plugins are read in name order, so "other" replaces what came before.
	kern.plugin.load(dir .. "/other")
	assert(kern.syntax.query("rust", "textobjects") == "(line_comment) @comment.around\n")

	kern.plugin.load(dir .. "/broken")
	local problems = languages.load_queries()
	assert(#problems == 1 and string.find(problems[1], "rust/folds", 1, true), problems[1])

	kern.plugin.unload("broken")
	kern.plugin.unload("other")
	kern.plugin.unload("more")
	assert(kern.syntax.query("rust", "textobjects") == bundled, "back to the bundled one")
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

test("the newest query set is used, and a plugin's goes with it", function(t)
	local dir = t:tempdir({
		["first/plugin.toml"] = 'name = "first"\n',
		["first/init.luau"] = "require('@kern').syntax.set_query('rust', 'folds', '(block) @a')\n",
		["second/plugin.toml"] = 'name = "second"\n',
		["second/init.luau"] = "require('@kern').syntax.set_query('rust', 'folds', '(block) @b')\n",
	})
	kern.plugin.load(dir .. "/first")
	kern.plugin.load(dir .. "/second")
	assert(kern.syntax.query("rust", "folds") == "(block) @b")
	kern.plugin.unload("second")
	assert(kern.syntax.query("rust", "folds") == "(block) @a", "the first one's is back")
	kern.plugin.unload("first")
	assert(kern.syntax.query("rust", "folds") == nil, "and then none")
	-- The grammar's own highlights stay when nothing replaces them.
	assert(string.find(kern.syntax.query("rust", "highlights") or "", "@keyword", 1, true) ~= nil)
	assert(not pcall(kern.syntax.set_query, "rust", "highlights", "(no_such_node) @x"))
end)
