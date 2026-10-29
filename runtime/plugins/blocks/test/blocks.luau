local test = require("@greed/test")
local greed = require("@greed")
local blocks = require("@blocks")

local function text(): string
	return greed.view():buffer():text()
end

local function has(wanted: string): () -> boolean
	return function()
		return string.find(text(), wanted, 1, true) ~= nil
	end
end

test("blocks are found with their language, options, code and result", function(t)
	t:buffer(
		'intro\n\n```sh id=files dir="a b"\nls\n```\n\n```result\na\nb\n```\n\n~~~luau\n1 + 1\n~~~\n\n```\nplain\n```\n|'
	)
	local found = blocks.parse.blocks(greed.view():buffer())
	assert(#found == 3, `{#found} blocks`)
	local sh = found[1]
	assert(sh.lang == "sh" and sh.opts.id == "files" and sh.opts.dir == "a b", sh.info)
	local buffer = greed.view():buffer()
	assert(buffer:slice(sh.code_from, sh.code_to) == "ls", buffer:slice(sh.code_from, sh.code_to))
	assert(sh.result and sh.result.text == "a\nb", "the result under it")
	assert(found[2].lang == "luau" and found[2].result == nil, "tildes fence too")
	assert(found[3].lang == "", "a block without a language")
end)

test("front matter says whether a file shows its blocks as runnable", function(t)
	t:buffer("---\ntitle: x\ngreed: run\n---\n\n```sh\necho hi\n```|")
	local buffer = greed.view():buffer()
	assert(blocks.parse.front_matter(buffer) == "run")
	buffer:set_language("markdown")
	assert(blocks.on(buffer), "on with greed: run")
	t:buffer("# not front matter\ngreed: run\n|")
	assert(blocks.parse.front_matter(greed.view():buffer()) == nil)
	t:buffer("---\ntitle: x\n---\ngreed: run\n|")
	assert(blocks.parse.front_matter(greed.view():buffer()) == nil, "after the front matter")
	t:buffer("---\ntitle: x\ngreed: run\n|")
	assert(blocks.parse.front_matter(greed.view():buffer()) == nil, "never closed")
end)

test("a shell block runs and its output goes in a result under it", function(t)
	t:buffer("```sh\necho hello\necho oops >&2\n```|\n\nafter\n")
	t:run("block-run")
	t:wait_for(has("```result"))
	t:expect("```sh\necho hello\necho oops >&2\n```|\n\n```result\nhello\noops\n```\n\nafter\n")
	-- Running it again replaces the result rather than adding another.
	t:run("block-run")
	t:wait_for(function()
		local _, count = string.gsub(text(), "```result", "")
		return count == 1 and string.find(text(), "hello", 1, true) ~= nil
	end)
	local _, results = string.gsub(text(), "```result", "")
	assert(results == 1, text())
end)

test("a failing program's result says how it exited", function(t)
	t:buffer("```sh\necho no; exit 3\n```|")
	t:run("block-run")
	t:wait_for(has("```result exit=3\nno\n```"))
end)

test("a luau block shows what it printed and what it returned", function(t)
	t:buffer("```luau\nprint('a', 1)\nreturn { 1, 2 }\n```|\n\n```luau\n6 * 7\n```\n")
	t:run("block-run")
	t:wait_for(has("```result\na\t1\n[1,2]\n```"))
	t:keys("G k")
	t:run("block-run")
	t:wait_for(has("```result\n42\n```"))
	t:buffer("```luau\nerror('broken')\n```|")
	t:run("block-run")
	t:wait_for(has("```result error\nerror: line 1: broken\n```"))
end)

test("input= feeds a named block's result to another, running it first", function(t)
	t:buffer(
		"```sh id=names safe=true\nprintf 'b\\na\\n'\n```\n\n```sh input=names\nsort|\n```\n\n```luau input=names\n#input\n```\n"
	)
	t:run("block-run")
	-- names ran first, so both have results.
	t:wait_for(has("```sh input=names\nsort\n```\n\n```result\na\nb\n```"))
	assert(
		string.find(
			text(),
			"```sh id=names safe=true\nprintf 'b\\na\\n'\n```\n\n```result\nb\na\n```",
			1,
			true
		),
		text()
	)
	t:keys("G k")
	t:run("block-run")
	t:wait_for(has("```result\n3\n```"))
end)

test("an input naming no block, or blocks feeding each other, says so", function(t)
	t:buffer("```sh input=nothing\necho x|\n```\n")
	t:run("block-run")
	t:wait_for(has("error: there's no block with id=nothing"))
	t:buffer("```sh id=a input=b safe=true\ncat\n```\n\n```sh id=b input=a\ncat|\n```\n")
	t:run("block-run")
	t:wait_for(has("feed each other"))
end)

-- Waits until the editor says something with `wanted` in it.
local function asked(t: any, wanted: string)
	t:wait_for(function()
		return string.find(table.concat(t:messages(), "\n"), wanted, 1, true) ~= nil
	end)
end

test("run all runs every safe block in order", function(t)
	t:buffer(
		"|```sh safe=true\necho one\n```\n\n```text\nnot run\n```\n\n```sh safe=true\necho two\n```\n"
	)
	t:run("blocks-run-all")
	t:wait_for(has("```sh safe=true\necho two\n```\n\n```result\ntwo\n```"))
	assert(
		string.find(text(), "```sh safe=true\necho one\n```\n\n```result\none\n```", 1, true),
		text()
	)
	assert(
		not string.find(text(), "not run\n```\n\n```result", 1, true),
		"only blocks with a runner"
	)
	t:run("blocks-results-clear")
	assert(not string.find(text(), "```result", 1, true), text())
end)

test("run all asks before each block not marked safe", function(t)
	local page =
		"|```sh safe=true\necho one\n```\n\n```sh\necho two\n```\n\n```sh\necho three\n```\n"
	t:buffer(page)
	t:keys("space m R")
	-- The safe one runs; the next asks, showing its first line and where
	-- it is now, under the first one's result.
	asked(t, "run line 9, `echo two`")
	assert(has("```result\none\n```")(), text())
	t:keys("n")
	asked(t, "run line 13, `echo three`")
	t:keys("y")
	t:wait_for(has("echo three\n```\n\n```result\nthree\n```"))
	assert(not has("echo two\n```\n\n```result")(), "n skips it")
	-- a runs the rest without asking.
	t:buffer(page)
	t:keys("space m R")
	asked(t, "run line 9")
	t:keys("a")
	t:wait_for(has("echo three\n```\n\n```result\nthree\n```"))
	assert(has("echo two\n```\n\n```result\ntwo\n```")(), text())
	-- Anything else stops there.
	t:buffer(page)
	t:keys("space m R")
	asked(t, "run line 9")
	t:keys("esc")
	asked(t, "stopped at line 9")
	assert(not has("echo three\n```\n\n```result")(), text())
end)

test("an input not marked safe runs only once you say so", function(t)
	local page = "```sh id=src\necho src\n```\n\n```sh input=src\ncat|\n```\n"
	t:buffer(page)
	t:keys("space m r")
	asked(t, "run block src first, `echo src`")
	t:keys("n")
	t:wait_for(has("error: block src isn't marked safe=true"))
	t:buffer(page)
	t:keys("space m r")
	asked(t, "run block src first")
	t:keys("y")
	t:wait_for(has("cat\n```\n\n```result\nsrc\n```"))
	-- With a result, rerun=true asks to run it again, and n uses the result.
	t:buffer(
		"```sh id=src\necho fresh\n```\n\n```result\nstale\n```\n\n```sh input=src rerun=true\ncat|\n```\n"
	)
	t:keys("space m r")
	asked(t, "run block src again, `echo fresh`")
	t:keys("n")
	t:wait_for(has("cat\n```\n\n```result\nstale\n```"))
	assert(not has("fresh\n```\n\n```result\nfresh")(), "it didn't run")
end)

test("clearing a result takes it away; a block without a runner says which do", function(t)
	t:buffer("```sh\necho hi\n```\n\n```result\nhi\n```|\n")
	t:run("block-result-clear")
	t:expect("```sh\necho hi\n```|\n")
	t:buffer("```cobol\nDISPLAY 'HI'\n```|")
	t:run("block-run")
	local said = table.concat(t:messages(), "\n")
	assert(string.find(said, "blocks in cobol don't run", 1, true), said)
end)

test("an http block's request is read from its lines", function()
	local request = blocks.runners.request(
		'\nPOST https://example.com/x\nAccept: text/plain\nX-Y: z\n\n{"a": 1}\n'
	)
	assert(request and request.method == "POST" and request.url == "https://example.com/x")
	assert(
		request.headers and request.headers.Accept == "text/plain" and request.headers["X-Y"] == "z"
	)
	assert(request.body == '{"a": 1}\n', request.body)
	local get = blocks.runners.request("https://example.com")
	assert(get and get.method == "GET" and get.body == nil)
end)

test("a file's blocks run only once you allow them, and always remembers it", function(t)
	local dir = t:tempdir({ ["notes.md"] = "```sh\necho trusted\n```\n" })
	greed.open(dir .. "/notes.md")
	local buffer = greed.view():buffer()
	assert(not blocks.on(buffer), "not shown as runnable before it's trusted")
	t:keys("space m r n")
	assert(not string.find(text(), "```result", 1, true), "n runs nothing")
	t:keys("space m r a")
	t:wait_for(has("```result\ntrusted\n```"))
	assert(blocks.trusted(buffer) and blocks.on(buffer), "trusted from now on")
	-- A run button on its fence, which enter presses.
	local button = false
	for _, mark in buffer:decorations("blocks") do
		button = button or mark.action == "block-run"
	end
	assert(button, "a run button")
	t:run("blocks-untrust")
	assert(not blocks.trusted(buffer), "asked again after untrusting")
end)

test("a long block can be stopped, and timeout= stops one on its own", function(t)
	t:buffer("```sh timeout=1\necho started; sleep 30\n```|")
	t:run("block-run")
	t:wait(1100)
	t:wait_for(has("(stopped)"))
	assert(string.find(text(), "started", 1, true), text())
end)

test("stopping a block stops what it started too, like a server", function(t)
	-- Whether the program the block starts in the background runs, once
	-- it's had a moment to start or to end.
	local function running(wanted: boolean): boolean
		local found = false
		for _ = 1, 50 do
			local listed = greed.process.run({ "pgrep", "-f", "^sleep 3137$" })
			found = listed ~= nil and listed.code == 0
			if found == wanted then
				break
			end
			greed.sleep(100)
		end
		return found
	end
	t:buffer("```sh\nsleep 3137 &\necho started; wait\n```|")
	t:run("block-run")
	assert(running(true), "it started")
	t:run("block-stop")
	t:wait_for(has("(stopped)"))
	assert(not running(false), "the program the block started in the background ended with it")
end)

test("runners from a plugin go when it does", function(t)
	local remove = blocks.runner("shout", function(run)
		return { output = string.upper(run.code) }
	end)
	t:buffer("```shout\nhey\n```|")
	t:run("block-run")
	t:wait_for(has("```result\nHEY\n```"))
	remove()
	assert(blocks.runners.get("shout") == nil)
end)

-- Calls the agent tool `name` with `args`.
local function tool(name: string, args: { [string]: any }): any
	local agent = require("@agent")
	for _, spec in agent.tools() do
		if spec.name == name then
			return spec.run(args, agent.caller())
		end
	end
	error(`no tool {name}`)
end

test("agents list a file's blocks and run one, in files the user let run", function(t)
	local dir = t:tempdir({
		["run.md"] = "```sh id=hello\necho hi\n```\n\n```text\nnot a block to run\n```\n",
	})
	local path = dir .. "/run.md"
	local listed = tool("blocks_list", { path = path })
	assert(#listed == 1 and listed[1].id == "hello" and listed[1].line == 1, "only runnable blocks")
	local ok, err = pcall(tool, "blocks_run", { path = path, id = "hello" })
	assert(not ok and string.find(tostring(err), "hasn't let blocks", 1, true), tostring(err))
	greed.open(path)
	t:run("blocks-trust")
	local ran = tool("blocks_run", { path = path, id = "hello" })
	assert(ran.result == "hi", tostring(ran.result))
	assert(has("```result\nhi\n```")(), "saved in the buffer too")
end)

test("rerun=true runs the input again even when it has a result", function(t)
	t:buffer(
		"```sh id=n safe=true\necho fresh\n```\n\n```result\nstale\n```\n\n```sh input=n\ncat|\n```\n"
	)
	t:run("block-run")
	-- Without the flag, the saved result is used as it is.
	t:wait_for(has("```sh input=n\ncat\n```\n\n```result\nstale\n```"))
	t:buffer(
		"```sh id=n safe=true\necho fresh\n```\n\n```result\nstale\n```\n\n```sh input=n rerun=true\ncat|\n```\n"
	)
	t:run("block-run")
	t:wait_for(has("```sh input=n rerun=true\ncat\n```\n\n```result\nfresh\n```"))
	assert(
		string.find(
			text(),
			"```sh id=n safe=true\necho fresh\n```\n\n```result\nfresh\n```",
			1,
			true
		),
		text()
	)
end)

test("an agent can't run a trusted file's block once it's changed, until you run it", function(t)
	local dir = t:tempdir({
		["run.md"] = "```sh id=a\necho one\n```\n\n```sh id=b input=a\ncat\n```\n",
	})
	local path = dir .. "/run.md"
	greed.open(path)
	t:run("blocks-trust")
	local buffer = greed.view():buffer()
	-- An agent (or its sandboxed eval) rewrites the block in the buffer.
	buffer:edit(function(e)
		local at = assert((string.find(buffer:text(), "echo one", 1, true)))
		e:replace(at - 1, at - 1 + #"echo one", "echo pwned")
	end)
	local ok, err = pcall(tool, "blocks_run", { path = path, id = "a" })
	assert(not ok and string.find(tostring(err), "changed since", 1, true), tostring(err))
	-- A block taking its input from a changed one is refused too.
	ok, err = pcall(tool, "blocks_run", { path = path, id = "b" })
	assert(not ok and string.find(tostring(err), "line 1 changed", 1, true), tostring(err))
	assert(not has("result\npwned")(), "nothing ran")
	-- Once you run it yourself, it's the block you know, and the agent may.
	greed.view():set_selection({ ranges = { { anchor = 2, head = 2 } }, primary = 1 })
	t:run("block-run")
	t:wait_for(has("```result\npwned\n```"))
	local ran = tool("blocks_run", { path = path, id = "b" })
	assert(ran.result == "pwned", tostring(ran.result))
	-- Untrusting forgets the blocks too.
	t:run("blocks-untrust")
	t:run("blocks-trust")
	assert(tool("blocks_run", { path = path, id = "a" }).result == "pwned", "trusted as it is")
end)

test("an agent's run never runs an input not marked safe, and lists which are", function(t)
	local dir = t:tempdir({
		["run.md"] = "```sh id=wipe\necho wiped\n```\n\n```sh id=count input=wipe\nwc -l\n```\n",
	})
	local path = dir .. "/run.md"
	greed.open(path)
	t:run("blocks-trust")
	local listed = tool("blocks_list", { path = path })
	assert(listed[1].safe == false, "not marked safe")
	local ran = tool("blocks_run", { path = path, id = "count" })
	assert(string.find(ran.result, "isn't marked safe=true", 1, true), tostring(ran.result))
	assert(not has("echo wiped\n```\n\n```result")(), "the input didn't run")
end)

test("a block changed while it waits for its input doesn't run for an agent", function(t)
	local dir = t:tempdir({
		["run.md"] = "```sh id=slow safe=true\nsleep 0.3; echo in\n```\n\n```sh id=b input=slow\ncat\n```\n",
	})
	local path = dir .. "/run.md"
	greed.open(path)
	t:run("blocks-trust")
	local buffer = greed.view():buffer()
	local result: any = nil
	greed.spawn(function()
		result = { pcall(tool, "blocks_run", { path = path, id = "b" }) }
	end)
	-- The run waits on the slow block now: changed meanwhile, it mustn't run.
	buffer:edit(function(e)
		local at = assert((string.find(buffer:text(), "cat", 1, true)))
		e:replace(at - 1, at + 2, "echo pwned")
	end)
	t:wait_for(function()
		return result ~= nil
	end)
	assert(string.find(buffer:text(), "error: the block on line 9 changed", 1, true), buffer:text())
	assert(not string.find(buffer:text(), "result\npwned", 1, true), "it didn't run")
end)

test("a running block shows so on its fence, and its result follows it as text moves", function(t)
	t:buffer("```sh\nsleep 0.3; echo done\n```|")
	local buffer = greed.view():buffer()
	local function status(): (string?, number?)
		for _, mark in buffer:decorations("blocks") do
			if mark.style == "blocks.running" then
				return mark.text, mark.from
			end
		end
		return nil, nil
	end
	t:run("block-run")
	local shown, from = status()
	-- It may have printed a line already, on a busy machine.
	local function running(): boolean
		return string.find(shown or "", "■ running", 1, true) == 1
	end
	assert(running() and from == 0, `{shown} at {from}`)
	buffer:edit(function(e)
		e:insert(0, "intro\n\n")
	end)
	shown, from = status()
	assert(running() and from == 7, `{shown} at {from}`)
	t:wait_for(has("```result"))
	assert(text() == "intro\n\n```sh\nsleep 0.3; echo done\n```\n\n```result\ndone\n```", text())
	assert(status() == nil, "nothing shows as running once it's done")
end)

test("output=choices writes its list as choices, keeping the pick when it runs again", function(t)
	t:buffer(
		'Pick one <!-- id=fruit -->\n\n```luau output=choices\nreturn { "apple", "(x) pear" }\n```|\n\nafter'
	)
	greed.view():buffer():set_language("markdown")
	blocks.refresh_choices(greed.view():buffer())
	t:wait_for(has("- (x) pear"))
	assert(string.find(text(), "```\n\n- ( ) apple\n- (x) pear\n\nafter", 1, true), text())
	local buffer = greed.view():buffer()
	require("@markdown").choices.pick(
		buffer,
		buffer:line_of(select(1, string.find(text(), "- ( ) apple", 1, true)) :: number)
	)
	blocks.refresh_choices(buffer)
	t:wait(20)
	assert(
		string.find(text(), "- (x) apple\n- ( ) pear\n\nafter", 1, true),
		"the pick stays: " .. text()
	)
	assert(require("@markdown").questions.answers(buffer).fruit == "apple")
end)

test(
	"a pick runs the blocks listening to it, with the answer; a button runs with every answer",
	function(t)
		t:buffer(table.concat({
			"Which? <!-- id=which -->",
			"",
			"- ( ) one",
			"- ( ) two",
			"",
			"```luau when=which",
			'require("@greed").echo("picked " .. answer)',
			"```",
			"",
			'```luau button="Show answers"',
			'require("@greed").echo("all: " .. answers.which)',
			"```",
			"|",
		}, "\n"))
		local buffer = greed.view():buffer()
		buffer:set_language("markdown")
		require("@markdown").choices.pick(buffer, 3)
		t:wait_for(function()
			return string.find(table.concat(t:messages(), "\n"), "picked two", 1, true) ~= nil
		end)
		assert(not string.find(text(), "```result", 1, true), "no result block")
		-- The button shows as one, on its fence, and runs the block.
		local fence = buffer:line_start(9)
		local button = nil
		for _, mark in buffer:decorations("blocks") do
			if mark.from == fence and mark.text then
				button = mark
			end
		end
		assert(
			button and button.text == "[ Show answers ]" and button.action == "block-run",
			"a button"
		)
		greed.view():set_cursor(fence)
		t:run("block-run")
		t:wait_for(function()
			return string.find(table.concat(t:messages(), "\n"), "all: two", 1, true) ~= nil
		end)
	end
)

test("a trusted file's blocks run by themselves only as you last let them run", function(t)
	local dir = t:tempdir({})
	local path = `{dir}/pick.md`
	local function file(fruit: string): string
		return `Pick <!-- id=fruit -->\n\n\`\`\`luau output=choices\nreturn \{ "{fruit}" }\n\`\`\`\n`
	end
	greed.fs.write(path, file("apple"))
	blocks.trust(path)
	-- Trusted before blocks were let run one by one: what it holds runs.
	greed.open(path)
	t:wait_for(has("- ( ) apple"))
	local opened = greed.view():buffer()
	greed.view():show(greed.create_buffer("text", ""))
	opened:close()
	-- Changed outside (a pull, an agent): it waits for you to run it.
	greed.fs.write(path, file("pear"))
	greed.open(path)
	t:wait(100)
	assert(not string.find(text(), "pear\n-", 1, true) and not has("- ( ) pear")(), text())
	local buffer = greed.view():buffer()
	local block = blocks.runnable(buffer)[1]
	assert(blocks.refused(buffer, block), "an agent may not run it either")
	-- Running it yourself lets it run as it is.
	greed.view():set_cursor(block.code_from)
	t:run("block-run")
	t:wait_for(has("- ( ) pear"))
	assert(blocks.refused(buffer, blocks.runnable(buffer)[1]) == nil, "let run")
	-- What you change and save yourself is let run as it is.
	local code = blocks.runnable(buffer)[1]
	buffer:edit(function(e)
		e:replace(code.code_from, code.code_to, 'return { "plum" }')
	end)
	buffer:save()
	assert(blocks.refused(buffer, blocks.runnable(buffer)[1]) == nil, "your own edit")
end)

test("blocks get the page's values: fields, lets and tables", function(t)
	local page = table.concat({
		"Bill: [840](field:bill)",
		"<!-- let each = bill / 3 -->",
		"",
		"<!-- id=costs -->",
		"| Item | Amount |",
		"|------|--------|",
		"| Rent | 900    |",
		"",
		"```luau",
		"return values.bill + values.costs[1].amount + values.each",
		"```",
		"",
		"```sh",
		'echo "$bill $each" && echo "$VALUES"',
		"```",
		"",
	}, "\n")
	local dir = t:tempdir({ ["page.md"] = page })
	blocks.trust(`{dir}/page.md`)
	greed.open(`{dir}/page.md`)
	local function run(code: string)
		greed.view():set_cursor((string.find(text(), code, 1, true) :: number) - 1)
		t:run("block-run")
	end
	-- A program gets each as a variable of its own, and all of them as JSON.
	run('echo "$bill')
	t:wait_for(has("```result\n840 280\n"))
	assert(string.find(text(), '"bill":840', 1, true), text())
	-- Luau gets them as `values`, tables as lists of their rows.
	run("return values")
	t:wait_for(has("```result\n2020\n```"))
end)
