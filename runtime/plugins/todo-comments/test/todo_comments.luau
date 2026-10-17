local test = require("@greed/test")
local greed = require("@greed")

-- The words picked out in the current buffer, with their styles.
local function picked(): string
	local buffer = greed.view():buffer()
	local out = {}
	for _, mark in buffer:decorations("todo-comments") do
		table.insert(out, `{buffer:slice(mark.from, mark.to)}={mark.style}`)
	end
	table.sort(out)
	return table.concat(out, " ")
end

test("TODO and its kind stand out in comments, not in strings", function(t)
	local dir = t:tempdir({
		["a.rs"] = '// TODO: this\nlet s = "TODO not this";\n/* FIXME and NOTE */\nlet TODOS = 1;\n',
	})
	greed.open(dir .. "/a.rs")
	t:wait(50)
	local got = picked()
	assert(got == "FIXME=comment.fixme NOTE=comment.note TODO=comment.todo", got)
end)

test("without a syntax tree, the language's comment marker says where comments are", function(t)
	t:buffer("|x = 1 # TODO later\nTODO = 2")
	greed.view():buffer():set_language("toml")
	t:wait(50)
	assert(picked() == "TODO=comment.todo", picked())
end)

test(":todo-comments lists them across the project", function(t)
	-- .git makes the folder the project's root.
	local dir = t:tempdir({
		[".git/HEAD"] = "",
		["src/a.rs"] = "fn a() {}\n// TODO: one\n",
		["b.py"] = "# FIXME two\n",
	})
	greed.open(dir .. "/src/a.rs")
	t:run("todo-comments")
	local shown = table.concat(t:floats(), "\n")
	assert(string.find(shown, "src/a.rs:2", 1, true), shown)
	assert(string.find(shown, "b.py:1", 1, true), shown)
end)

test("todo-comments off stops picking them out", function(t)
	greed.option.set("todo-comments", false)
	t:buffer("|# TODO")
	greed.view():buffer():set_language("toml")
	assert(picked() == "", picked())
	greed.option.set("todo-comments", true)
end)
