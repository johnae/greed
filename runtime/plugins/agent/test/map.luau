local test = require("@greed/test")
local greed = require("@greed")
local agent = require("@agent")

-- A small Rust project: main uses the parser, the parser uses the lexer,
-- and nothing uses the unused file.
local PROJECT = {
	[".git/HEAD"] = "ref: refs/heads/main\n",
	["src/main.rs"] = 'fn main() {\n    let tree = parse("1 + 2");\n    show(tree);\n}\n\nfn show(tree: Tree) {}\n',
	["src/parser.rs"] = "pub struct Tree {}\n\npub fn parse(text: &str) -> Tree {\n    let tokens = lex(text);\n    Tree {}\n}\n",
	["src/lexer.rs"] = "pub fn lex(text: &str) -> Vec<Token> {\n    Vec::new()\n}\n\npub struct Token {}\n",
	["src/unused.rs"] = "pub fn lonely() {}\n",
}

-- Opens a file in the project, so the project is the shown one.
local function project(t: any, files: { [string]: string }?): string
	local dir = t:tempdir(files or PROJECT)
	greed.open(`{dir}/src/main.rs`)
	return dir
end

test("greed.syntax.tags tells what each file defines and uses", function(t)
	local dir = project(t)
	local files = greed.syntax.tags(dir)
	local by_path = {}
	for _, file in files do
		by_path[file.path] = file
	end
	local parser = by_path["src/parser.rs"]
	assert(parser and parser.language == "rust", "the parser file")
	local names: { string } = {}
	for _, d in parser.definitions do
		table.insert(names, `{d.kind} {d.name} {d.line}`)
	end
	assert(table.concat(names, ", ") == "type Tree 0, function parse 2", table.concat(names, ", "))
	assert(
		parser.definitions[2].signature == "pub fn parse(text: &str) -> Tree {",
		parser.definitions[2].signature
	)
	assert(parser.references.lex == 1, "uses lex")
	assert(by_path[".git/HEAD"] == nil, "only source files")
end)

test("the repo map ranks what the open file leads to first", function(t)
	project(t)
	local map = agent.map.map({ budget = 2048 })
	local parser = string.find(map, "src/parser.rs", 1, true)
	local unused = string.find(map, "src/unused.rs", 1, true)
	assert(parser, map)
	assert(string.find(map, "    3  pub fn parse(text: &str) -> Tree {", 1, true), map)
	assert(unused == nil or unused > parser, map)
end)

test("the repo map keeps to its budget", function(t)
	project(t)
	local map = agent.map.map({ budget = 15 })
	assert(#map <= 15 * 4, map)
	assert(#map > 0, "something fits")
end)

test("symbols finds definitions by name", function(t)
	project(t)
	local found = agent.map.symbols("pars")
	assert(found[1].name == "parse" and found[1].path == "src/parser.rs", found[1].name)
	assert(found[1].line == 2, tostring(found[1].line))
end)

test("grep sees unsaved changes in open files", function(t)
	project(t)
	local main = greed.view():buffer()
	main:edit(function(e)
		e:insert(0, "// needle\n")
	end)
	local hits = assert(agent.map.grep("needle|lonely"))
	assert(#hits == 2, tostring(#hits))
	assert(hits[1].path == "src/main.rs" and hits[1].line == 1, hits[1].path)
	assert(hits[2].path == "src/unused.rs" and hits[2].text == "pub fn lonely() {}", hits[2].path)
	local _, err = agent.map.grep("(")
	assert(err, "a bad pattern says why")
end)
