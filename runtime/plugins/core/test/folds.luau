local test = require("@kern/test")
local kern = require("@kern")

local function hidden(): string
	local out = {}
	for _, lines in kern.view():hidden_lines() do
		table.insert(out, `{lines.from}-{lines.to}`)
	end
	return table.concat(out, " ")
end

test("z a folds the lines indented under the block's first line, and unfolds them", function(t)
	t:buffer("a:\n  b|1\n  b2\n\n  b3\nc")
	t:keys("z a")
	assert(hidden() == "1-4", hidden())
	t:expect("|a:\n  b1\n  b2\n\n  b3\nc")
	t:keys("z a")
	assert(hidden() == "", hidden())
end)

test("on a block's first line, z a folds what's under it", function(t)
	t:buffer("|a:\n  b\nc:\n  d")
	t:keys("z a")
	assert(hidden() == "1-1", hidden())
	t:expect("|a:\n  b\nc:\n  d")
end)

test("z c folds, z o unfolds, and z R unfolds everything", function(t)
	t:buffer("a:\n  b:\n    |c\n  d\ne:\n  f")
	t:keys("z c")
	assert(hidden() == "2-2", "the innermost block: " .. hidden())
	t:keys("z c")
	assert(hidden() == "2-2", "folding again leaves it")
	t:keys("z o")
	assert(hidden() == "", hidden())
	t:keys("j j z c")
	assert(hidden() == "1-3", "the block around the cursor's line: " .. hidden())
	local buffer = kern.view():buffer()
	local f = buffer:line_start(5)
	kern.view():set_selection({ ranges = { { anchor = f, head = f } }, primary = 1 })
	t:keys("z c")
	assert(hidden() == "1-3 5-5", hidden())
	t:keys("z R")
	assert(hidden() == "", hidden())
end)

test("with nothing indented around it, there's nothing to fold", function(t)
	t:buffer("|one\ntwo")
	t:keys("z a")
	assert(hidden() == "", hidden())
	local messages = t:messages()
	assert(messages[#messages] == "nothing to fold here", messages[#messages])
end)

test("a plugin can fold a language its own way", function(t)
	local core = require("@core")
	core.folds.providers.klingon = function(_, line: number): (number?, number)
		return line, line + 2
	end
	t:buffer("|a\nb\nc\nd")
	kern.view():buffer():set_language("klingon")
	t:keys("z a")
	assert(hidden() == "1-2", hidden())
	core.folds.providers.klingon = nil
end)
