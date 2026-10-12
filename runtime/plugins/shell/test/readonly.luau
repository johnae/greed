local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")
local shell = require("@shell")
local log = require("../log")

type Shell = typeof(shell.open())
type Block = typeof(assert(shell.run(shell.open(), "true")))

-- Opens a shell in a new folder, in `style`, with blocks mode `blocks`.
local function open(t: test.TestContext, style: string, blocks: boolean): Shell
	greed.option.set("editing-style", style)
	greed.option.set("shell-blocks", blocks)
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = t:tempdir()
	return sh
end

local function finished(t: test.TestContext, block: Block): Block
	t:wait_for(function()
		return block.status ~= "running"
	end)
	return block
end

-- Runs `line` from the prompt and waits for it.
local function type_line(t: test.TestContext, sh: Shell, line: string): Block
	log.set_prompt(sh, line, { greed.view() })
	t:keys("enter")
	return finished(t, sh.blocks[#sh.blocks])
end

-- Everything above the prompt, which nothing typed may change.
local function above(sh: Shell): string
	return sh.buffer:slice(0, log.prompt_start(sh))
end

-- Presses `keys`, the last of which edits above the prompt and is refused.
local function refused(t: test.TestContext, keys: string)
	local err: unknown = nil
	local ok = xpcall(function()
		t:keys(keys)
	end, function(e)
		err = e
	end)
	assert(not ok and string.find(tostring(err), "read-only", 1, true), tostring(err))
end

-- Puts the cursor on the first character of `block`'s output.
local function into_output(sh: Shell, block: Block): number
	local from = assert((log.output_range(sh, block)))
	greed.view():set_cursor(from)
	return from
end

test("everything above the prompt is read-only, and the prompt isn't", function(t)
	local sh = open(t, "helix", false)
	type_line(t, sh, "echo out")
	assert(sh.buffer:readonly_before() == log.prompt_start(sh), "it ends at the prompt")
	assert(log.prompt_text(sh) == "", log.prompt_text(sh))
end)

test("with blocks mode off, helix d and vim x leave the output alone", function(t)
	for _, style in { "helix", "vim" } do
		local sh = open(t, style, false)
		local block = type_line(t, sh, "echo out")
		local before = above(sh)
		t:keys("esc")
		into_output(sh, block)
		refused(t, if style == "helix" then "d" else "x")
		assert(above(sh) == before, `{style}: {above(sh)}`)
		assert(block.output == "out\n", block.output)
	end
end)

test("backspace at the prompt's start deletes nothing above it", function(t)
	for _, style in { "helix", "vscode" } do
		local sh = open(t, style, false)
		type_line(t, sh, "echo out")
		local before = above(sh)
		t:keys("a backspace backspace")
		assert(log.prompt_text(sh) == "", `{style}: {log.prompt_text(sh)}`)
		assert(above(sh) == before, `{style}: {above(sh)}`)
	end
end)

test("typing in the output goes to the end of the prompt", function(t)
	local sh = open(t, "helix", false)
	local block = type_line(t, sh, "echo out")
	local before = above(sh)
	t:keys("esc")
	into_output(sh, block)
	t:keys("i a b")
	assert(above(sh) == before, above(sh))
	assert(log.prompt_text(sh) == "ab", log.prompt_text(sh))
	assert(greed.view():cursor() == sh.buffer:len())
end)

test("in the vscode style, typing over a selection in the output goes to the prompt", function(t)
	local sh = open(t, "vscode", false)
	local block = type_line(t, sh, "echo out")
	local before = above(sh)
	local from = assert((log.output_range(sh, block)))
	greed.view():set_selection({ ranges = { { anchor = from, head = from + 3 } }, primary = 1 })
	t:keys("z")
	assert(above(sh) == before, above(sh))
	assert(log.prompt_text(sh) == "z", log.prompt_text(sh))
end)

test("a paste in the output goes to the prompt", function(t)
	local sh = open(t, "helix", true)
	local block = type_line(t, sh, "echo out")
	local before = above(sh)
	into_output(sh, block)
	core.paste.paste(greed.view(), "pasted")
	assert(above(sh) == before, above(sh))
	assert(log.prompt_text(sh) == "pasted", log.prompt_text(sh))
end)

test("the prompt stays editable: typing, deleting, lines, history", function(t)
	local sh = open(t, "helix", false)
	type_line(t, sh, "echo one")
	local before = above(sh)
	-- Running it left the prompt in insert mode.
	t:keys("e c h o space t w o x backspace")
	assert(log.prompt_text(sh) == "echo two", log.prompt_text(sh))
	t:run("insert-newline")
	t:keys("e c h o space t h r e e")
	assert(log.prompt_text(sh) == "echo two\necho three", log.prompt_text(sh))
	assert(above(sh) == before, above(sh))
	-- A helix edit at the prompt's start is in the prompt too.
	t:keys("esc")
	greed.view():set_cursor(log.prompt_start(sh))
	t:keys("d")
	assert(log.prompt_text(sh) == "cho two\necho three", log.prompt_text(sh))
	log.set_prompt(sh, "", { greed.view() })
	t:keys("i up")
	assert(log.prompt_text(sh) == "echo one", log.prompt_text(sh))
	assert(sh.buffer:readonly_before() == log.prompt_start(sh))
end)

test("blocks run again in their place still redraw their output", function(t)
	local sh = open(t, "helix", true)
	local block = type_line(t, sh, "echo one")
	type_line(t, sh, "echo two")
	shell.change(sh, block, "echo three", { view = greed.view() })
	finished(t, block)
	assert(block.output == "three\n", block.output)
	assert(string.find(above(sh), "echo three\nthree\necho two\ntwo\n", 1, true), above(sh))
	assert(sh.buffer:readonly_before() == log.prompt_start(sh))
	-- Typing still goes in at the prompt.
	t:keys("esc i x")
	assert(log.prompt_text(sh) == "x", log.prompt_text(sh))
end)
