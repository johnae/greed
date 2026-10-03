local test = require("@greed/test")
local greed = require("@greed")
local languages = require("@languages")

test("files get their language from the table", function()
	assert(greed.language_of("main.py") == "python", tostring(greed.language_of("main.py")))
	assert(greed.language_of("flake.nix") == "nix", "nix")
	assert(greed.language_of("Makefile") == "make", "by name")
	assert(greed.language_of("notes.zz") == nil, "unknown")
end)

test("set changes the fields it's given and keeps the rest", function()
	languages.set("python", { extensions = { "pyx" } })
	assert(greed.language_of("a.pyx") == "python", "new extension")
	assert(greed.language_of("a.py") == nil, "old one gone")
	local python = languages.get("python") :: languages.Language
	assert(python.comment == "#", "the rest stays")

	languages.set("odin", { extensions = { "odin" }, comment = "//" })
	assert(greed.language_of("main.odin") == "odin", "new languages work too")
	assert(table.find(languages.list(), "odin"), "and are listed")
end)

test(":health lists each language with its highlighting and servers", function(t)
	t:buffer("|x")
	t:run("health")
	local report = t:floats()[1]
	assert(string.find(report, "rust%s+highlighting%s+rust%-analyzer"), report)
	assert(string.find(report, "ruby%s+downloads%s+ruby%-lsp, solargraph"), report)
	assert(string.find(report, "zig%s+no grammar%s+zls"), report)
	t:keys("q")
	assert(#t:floats() == 0, "q closes it")
end)

test("set with no servers stops starting one", function()
	local before = (languages.get("python") :: languages.Language).servers
	languages.set("python", { servers = { { "pylsp" } } })
	assert(greed.lsp.servers().python[1][1] == "pylsp", "set")
	languages.set("python", { servers = {} })
	assert(greed.lsp.servers().python == nil, "removed")
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
	for _, name in greed.grammars() do
		assert(greed.syntax.query(name, "textobjects"), `{name} has no textobjects query`)
	end
end)

test("a plugin's query files replace or extend the bundled ones, until it goes", function(t)
	-- Queries are checked when a buffer in their language is open.
	t:buffer("|fn a() {}")
	greed.view():buffer():set_language("rust")
	local bundled = greed.syntax.query("rust", "textobjects") :: string
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
	greed.plugin.load(dir .. "/more")
	local extended = greed.syntax.query("rust", "textobjects") :: string
	assert(string.find(extended, bundled, 1, true), "the bundled query stays")
	assert(string.find(extended, "macro_invocation", 1, true), "and the plugin's is added")

	-- Plugins are read in name order, so "other" replaces what came before.
	greed.plugin.load(dir .. "/other")
	assert(greed.syntax.query("rust", "textobjects") == "(line_comment) @comment.around\n")

	greed.plugin.load(dir .. "/broken")
	local problems = languages.load_queries()
	assert(#problems == 1 and string.find(problems[1], "rust/folds", 1, true), problems[1])

	greed.plugin.unload("broken")
	greed.plugin.unload("other")
	greed.plugin.unload("more")
	assert(greed.syntax.query("rust", "textobjects") == bundled, "back to the bundled one")
end)

test("m a f selects a Luau function", function(t)
	t:buffer("local function f(a, b)\n\treturn |a\nend\n")
	greed.view():buffer():set_language("luau")
	t:keys("m a f")
	t:expect("^local function f(a, b)\n\treturn a\nend|\n")
	t:buffer("local function f(a, |b)\nend\n")
	greed.view():buffer():set_language("luau")
	t:keys("m a a")
	t:expect("local function f(a^, b|)\nend\n")
end)

test("the newest query set is used, and a plugin's goes with it", function(t)
	t:buffer("|fn a() {}")
	greed.view():buffer():set_language("rust")
	local dir = t:tempdir({
		["first/plugin.toml"] = 'name = "first"\n',
		["first/init.luau"] = "require('@greed').syntax.set_query('rust', 'scratch', '(block) @a')\n",
		["second/plugin.toml"] = 'name = "second"\n',
		["second/init.luau"] = "require('@greed').syntax.set_query('rust', 'scratch', '(block) @b')\n",
	})
	greed.plugin.load(dir .. "/first")
	greed.plugin.load(dir .. "/second")
	assert(greed.syntax.query("rust", "scratch") == "(block) @b")
	greed.plugin.unload("second")
	assert(greed.syntax.query("rust", "scratch") == "(block) @a", "the first one's is back")
	greed.plugin.unload("first")
	assert(greed.syntax.query("rust", "scratch") == nil, "and then none")
	-- The grammar's own highlights stay when nothing replaces them.
	assert(string.find(greed.syntax.query("rust", "highlights") or "", "@keyword", 1, true) ~= nil)
	assert(not pcall(greed.syntax.set_query, "rust", "highlights", "(no_such_node) @x"))
end)

-- A grammar source standing in for a download: the small JSON grammar the
-- Rust tests use, and queries from `dir`.
local function local_source(dir: string, sha256: string?): any
	local wasm =
		`{greed.plugin.dirs().languages}/../../../crates/greed-core/tests/samples/tree-sitter-json.wasm`
	return {
		repo = "example/tree-sitter-jsonish",
		version = "v1",
		sha256 = sha256 or "d2119fb98d5912719b13f9458574f8608d2d29dfbe45f6be1f860ea1fe2a2405",
		symbol = "json",
		url = "file://" .. wasm,
		queries = `file://{dir}/{"{kind}"}.scm`,
	}
end

test("a grammar is downloaded when a file in its language opens, and kept", function(t)
	local dir = t:tempdir({ ["highlights.scm"] = "(number) @number\n(string) @string\n" })
	languages.grammars.sources.jsonish = local_source(dir)
	languages.set("jsonish", { extensions = { "jsonish" } })
	local file = t:tempdir({ ["a.jsonish"] = '{"a": 42}' }) .. "/a.jsonish"
	greed.open(file)
	t:wait_for(function()
		return table.find(greed.grammars(), "jsonish") ~= nil
	end)
	assert(greed.view():buffer():tree(), "it parses")
	local query = greed.syntax.query("jsonish", "highlights") :: string
	assert(string.find(query, "@constant.numeric", 1, true), "capture names are Greed's: " .. query)

	-- Once kept, it loads again without downloading.
	languages.grammars.sources.jsonish.url = "file:///nowhere/gone.wasm"
	assert(languages.grammars.ensure("jsonish", function()
		return false
	end))
end)

test(
	"a download that doesn't match its checksum is refused, and turning downloads off stops them",
	function(t)
		local dir = t:tempdir({})
		languages.grammars.sources.badsum = local_source(dir, string.rep("0", 64))
		local ok, err = pcall(languages.ensure_grammar, "badsum")
		assert(not ok and string.find(tostring(err), "checksum", 1, true), tostring(err))
		assert(table.find(greed.grammars(), "badsum") == nil)

		languages.grammars.sources.off = local_source(dir)
		greed.option.set("grammar-download", false)
		assert(languages.ensure_grammar("off") == false, "not downloaded")
		greed.option.set("grammar-download", true)
		assert(languages.ensure_grammar("off"), "and downloaded once it's on")
	end
)

test("queries from other editors get Greed's names, and catch-alls go last", function()
	local adapted = languages.grammars.adapt(
		"(identifier) @variable\n(call function: (identifier) @function.call)\n(x) @spell\n((pattern/wildcard) @number)"
	)
	assert(
		adapted
			== "(call function: (identifier) @function)\n(x) \n((wildcard) @constant.numeric)\n(identifier) @variable",
		adapted
	)
end)

test("each bundled folds and indents query compiles with its grammar", function()
	languages.load_queries()
	for _, name in greed.grammars() do
		for _, kind in { "folds", "indents" } do
			local source = greed.syntax.query(name, kind)
			if source then
				local buffer = greed.create_buffer("file", "")
				buffer:set_language(name)
				local ok, err = pcall(function()
					return buffer:query(source)
				end)
				assert(ok, `{name} {kind}: {err}`)
			end
		end
	end
	assert(
		greed.syntax.query("nix", "folds") and greed.syntax.query("nix", "indents"),
		"nix has both"
	)
end)

test("z a folds the smallest block the folds query finds around the cursor", function(t)
	languages.load_queries()
	t:buffer("fn a() {\n    if x {\n        |y();\n    }\n}\n")
	greed.view():buffer():set_language("rust")
	t:keys("z a")
	local hidden = greed.view():hidden_lines()
	assert(#hidden == 1 and hidden[1].from == 2 and hidden[1].to == 3, "the if's block")
	t:keys("z a k z a")
	hidden = greed.view():hidden_lines()
	assert(#hidden == 1 and hidden[1].from == 1 and hidden[1].to == 4, "the function")
end)

-- A buffer in `language` with `text`, then `keys`, expecting `after`.
local function typed(
	t: test.TestContext,
	language: string,
	text: string,
	keys: string,
	after: string
)
	t:buffer(text)
	greed.view():buffer():set_language(language)
	t:keys(keys)
	t:expect(after)
end

test("new lines in Rust go a level in inside a block, and } lines up", function(t)
	languages.load_queries()
	typed(t, "rust", "fn a() {|}", "i enter", "fn a() {\n    |\n}")
	typed(
		t,
		"rust",
		"fn a() {\n    let x = 1;|\n}",
		"i enter",
		"fn a() {\n    let x = 1;\n    |\n}"
	)
	typed(t, "rust", "fn a() {\n    f(|)\n}", "i enter", "fn a() {\n    f(\n        |\n    )\n}")
	typed(t, "rust", "impl A {\n    fn b() {}|\n}", "o", "impl A {\n    fn b() {}\n    |\n}")
end)

test("new lines in Nix use its two spaces, inside sets, lists and let", function(t)
	languages.load_queries()
	typed(t, "nix", "{\n  a = [|];\n}", "i enter", "{\n  a = [\n    |\n  ];\n}")
	typed(t, "nix", "let|\nin x", "i enter", "let\n  |\nin x")
	typed(t, "nix", "let\n  a = 1;|\nin x", "i enter", "let\n  a = 1;\n  |\nin x")
	typed(t, "nix", "let\n  a = 1;\n  |in x", "i enter", "let\n  a = 1;\n\n|in x")
end)

test("new lines in Luau indent with tabs inside functions and ifs", function(t)
	languages.load_queries()
	typed(t, "luau", "local function f()|\nend", "i enter", "local function f()\n\t|\nend")
	typed(t, "luau", "if x then\n\ty()|\nend", "i enter", "if x then\n\ty()\n\t|\nend")
	typed(t, "luau", "if x then\n\ty()|end", "i enter", "if x then\n\ty()\n|end")
end)

test("Python and YAML go a level in after a colon", function(t)
	typed(t, "python", "def f():|", "a enter", "def f():\n    |")
	typed(t, "yaml", "a:|", "a enter", "a:\n  |")
	typed(t, "python", "x = 1|", "a enter", "x = 1\n|")
end)

test("> and < use the language's indent", function(t)
	t:buffer("|a")
	greed.view():buffer():set_language("go")
	t:keys(">")
	t:expect("|\ta")
	greed.view():buffer():set_language("nix")
	t:keys("< >")
	t:expect("|  a")
end)

test(
	"Ruby indents by its keywords while the grammar isn't there or the code doesn't parse",
	function(t)
		-- Typing a method from scratch: its `end` lines up when enter is pressed.
		typed(
			t,
			"ruby",
			"def hello|",
			"a enter p r i n t enter e n d enter",
			"def hello\n  print\nend\n|"
		)
		typed(t, "ruby", "if x|", "a enter y enter e l s e enter z", "if x\n  y\nelse\n  z|")
		typed(t, "ruby", "class A\n  def b|", "a enter", "class A\n  def b\n    |")
	end
)

test("a pattern for names that aren't locals becomes a catch-all after the others", function()
	local adapted = languages.grammars.adapt(
		'(identifier) @variable\n\n((identifier) @function.method\n (#is-not? local))\n\n"def" @keyword'
	)
	assert(
		adapted == '\n\n"def" @keyword\n(identifier) @variable\n(identifier) @function.method',
		adapted
	)
end)

test("m a T selects a test, m a e an entry", function(t)
	t:buffer("fn a() {}\n\n#[test]\nfn b() {\n    x|;\n}\n")
	greed.view():buffer():set_language("rust")
	t:keys("m a T")
	t:expect("fn a() {}\n\n#[test]\n^fn b() {\n    x;\n}|\n")
	t:buffer('{"a": 1, "b": |2}')
	greed.view():buffer():set_language("json")
	t:keys("m a e")
	t:expect('{"a": 1, ^"b": 2|}')
end)
