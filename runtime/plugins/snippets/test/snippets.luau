local test = require("@greed/test")
local greed = require("@greed")
local snippets = require("@snippets")

local RUST = [[{
  "test": {
    "prefix": ["test", "tst"],
    "body": ["#[test]", "fn ${1:name}() {", "\t$0", "}"],
    "description": "A test function"
  }
}]]

local ALL = [[{ "todo": { "prefix": "todo", "body": "TODO(${1:who}): $0" } }]]

local SHARED = [[{
  "py": { "scope": "python", "prefix": "main", "body": "if __name__ == '__main__':" },
  "any": { "prefix": "hello", "body": "hello" }
}]]

-- A snippets folder of the test's own; returns it.
local function folder(t: test.TestContext): string
	local dir = t:tempdir({
		["snippets/rust.json"] = RUST,
		["snippets/all.json"] = ALL,
		["snippets/shared.code-snippets"] = SHARED,
	})
	greed.option.set("snippets-folder", `{dir}/snippets`)
	return `{dir}/snippets`
end

local function names(list: { snippets.Snippet }): string
	local out = {}
	for _, snippet in list do
		table.insert(out, snippet.name)
	end
	table.sort(out)
	return table.concat(out, ",")
end

test("a file reads as its snippets: prefixes, a body of lines, a description", function()
	local file = snippets.parse("rust.json", RUST)
	assert(file and file.language == "rust", "rust.json is Rust's")
	local snippet = file.snippets[1]
	assert(table.concat(snippet.prefixes, ",") == "test,tst")
	assert(snippet.body == "#[test]\nfn ${1:name}() {\n\t$0\n}", snippet.body)
	assert(snippet.description == "A test function")
	local all = snippets.parse("all.json", ALL)
	assert(all and all.language == nil, "all.json is for every language")
	local broken, err = snippets.parse("x.json", "{ nope")
	assert(broken == nil and err, "broken JSON says so")
end)

test("a buffer gets its language's snippets, every language's, and those scoped to it", function(t)
	folder(t)
	t:buffer("|")
	greed.view():buffer():set_language("rust")
	assert(names(snippets.for_buffer(greed.view():buffer())) == "any,test,todo")
	greed.view():buffer():set_language("python")
	assert(names(snippets.for_buffer(greed.view():buffer())) == "any,py,todo")
end)

test("typing a prefix offers the snippet, which goes in with its places", function(t)
	folder(t)
	t:buffer("|")
	greed.view():buffer():set_language("rust")
	t:keys("i t s")
	t:run("completion-ask")
	local menu = table.concat(t:floats(), "\n")
	assert(string.find(menu, "tst", 1, true) and string.find(menu, "snippet", 1, true), menu)
	t:keys("enter")
	-- Rust's indent is four spaces.
	t:expect("#[test]\nfn ^name|() {\n    \n}")
end)

test(":snippet picks one by name", function(t)
	folder(t)
	t:buffer("|")
	t:run("snippet")
	for _, key in { "t", "o", "d", "o" } do
		t:keys(key)
	end
	t:keys("enter")
	t:expect("TODO(^who|): ")
end)

test("saving a snippet file reads it again", function(t)
	local dir = folder(t)
	t:buffer("|")
	assert(not string.find(names(snippets.for_buffer(greed.view():buffer())), "fresh", 1, true))
	greed.fs.write(`{dir}/all.json`, [[{ "fresh": { "prefix": "fr", "body": "x" } }]])
	t:wait(200)
	assert(names(snippets.for_buffer(greed.view():buffer())) == "any,fresh")
end)

test(":snippets-edit opens the language's file, making it", function(t)
	local dir = folder(t)
	t:buffer("|")
	greed.view():buffer():set_language("go")
	t:run("snippets-edit")
	assert(greed.view():buffer():path() == `{dir}/go.json`, greed.view():buffer():path())
	assert(greed.fs.read(`{dir}/go.json`) == "{\n}\n")
end)
