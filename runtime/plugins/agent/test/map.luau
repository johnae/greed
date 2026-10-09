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

test("grep searches Greed's plugins and types, and says when a path is out of reach", function(t)
	local dir = project(t)
	local core = assert(greed.plugin.dirs().core)
	local runtime = assert(string.match(core, "^(.*)/[^/]+/[^/]+$"))
	local hits = assert(agent.map.grep("^export type ThemeEntry", `{runtime}/types`))
	assert(#hits == 1, tostring(#hits))
	assert(hits[1].path == `{runtime}/types/greed/init.luau`, hits[1].path)
	-- A full path inside the project works as a relative one does.
	local inside = assert(agent.map.grep("lonely", `{dir}/src`))
	assert(inside[1] and inside[1].path == "src/unused.rs", inside[1] and inside[1].path)
	local _, outside = agent.map.grep("x", "/etc")
	assert(outside and string.find(outside, "outside the project", 1, true), outside)
	local _, missing = agent.map.grep("x", "nowhere")
	assert(missing and string.find(missing, "no nowhere in the project", 1, true), missing)
	local one = assert(agent.map.grep("lonely", "src/unused.rs"))
	assert(one[1] and one[1].path == "src/unused.rs", one[1] and one[1].path)
end)

test("grep searches the plugins in your config, which agents write", function(t)
	project(t)
	local plugins = t:tempdir({ ["mine/init.luau"] = "return { answer = 42 }\n" })
	local before = agent.dirs.plugins
	agent.dirs.plugins = plugins
	local hits, err = agent.map.grep("answer", `{plugins}/mine`)
	agent.dirs.plugins = before
	assert(hits, err)
	assert(hits[1] and hits[1].path == `{plugins}/mine/init.luau`, hits[1] and hits[1].path)
end)

test("files lists a folder of the project, or your config's plugins, by path", function(t)
	local dir = project(t)
	local tool: any
	for _, each in agent.tools() do
		if each.name == "files" then
			tool = each
		end
	end
	local function list(args: { [string]: any }): { string }
		return tool.run(args, agent.caller())
	end
	local src = list({ path = "src" })
	assert(table.find(src, "src/unused.rs") and #src == 4, table.concat(src, " "))
	local full = list({ path = `{dir}/src` })
	assert(table.find(full, "src/unused.rs"), table.concat(full, " "))
	local plugins = t:tempdir({ ["mine/init.luau"] = "return {}\n" })
	local before = agent.dirs.plugins
	agent.dirs.plugins = plugins
	local mine = list({ path = `{plugins}/mine` })
	agent.dirs.plugins = before
	assert(mine[1] == `{plugins}/mine/init.luau`, mine[1])
	local ok, err = pcall(list, { path = "/etc" })
	assert(not ok and string.find(tostring(err), "files lists in it", 1, true), tostring(err))
end)

test("grep finding nothing in the project looks in Greed's own code, and says so", function(t)
	project(t)
	local tool: any
	for _, each in agent.tools() do
		if each.name == "grep" then
			tool = each
		end
	end
	local said = tool.run({ pattern = "^export type ThemeEntry" }, agent.caller())
	assert(string.find(said, "nothing in the project; these are from Greed's own", 1, true), said)
	assert(string.find(said, "types/greed/init.luau", 1, true), said)
	local none = tool.run({ pattern = "qzx" .. "jwv" .. "kq" }, agent.caller())
	assert(none == "no lines match in the project", none)
end)
