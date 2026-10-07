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
		"```sh id=names\nprintf 'b\\na\\n'\n```\n\n```sh input=names\nsort|\n```\n\n```luau input=names\n#input\n```\n"
	)
	t:run("block-run")
	-- names ran first, so both have results.
	t:wait_for(has("```sh input=names\nsort\n```\n\n```result\na\nb\n```"))
	assert(
		string.find(
			text(),
			"```sh id=names\nprintf 'b\\na\\n'\n```\n\n```result\nb\na\n```",
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
	t:buffer("```sh id=a input=b\ncat\n```\n\n```sh id=b input=a\ncat|\n```\n")
	t:run("block-run")
	t:wait_for(has("feed each other"))
end)

test("run all runs every block in order", function(t)
	t:buffer("|```sh\necho one\n```\n\n```text\nnot run\n```\n\n```sh\necho two\n```\n")
	t:run("blocks-run-all")
	t:wait_for(has("```sh\necho two\n```\n\n```result\ntwo\n```"))
	assert(string.find(text(), "```sh\necho one\n```\n\n```result\none\n```", 1, true), text())
	assert(
		not string.find(text(), "not run\n```\n\n```result", 1, true),
		"only blocks with a runner"
	)
	t:run("blocks-results-clear")
	assert(not string.find(text(), "```result", 1, true), text())
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
	for _, spec in require("@agent").tools() do
		if spec.name == name then
			return spec.run(args)
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
	t:buffer("```sh id=n\necho fresh\n```\n\n```result\nstale\n```\n\n```sh input=n\ncat|\n```\n")
	t:run("block-run")
	-- Without the flag, the saved result is used as it is.
	t:wait_for(has("```sh input=n\ncat\n```\n\n```result\nstale\n```"))
	t:buffer(
		"```sh id=n\necho fresh\n```\n\n```result\nstale\n```\n\n```sh input=n rerun=true\ncat|\n```\n"
	)
	t:run("block-run")
	t:wait_for(has("```sh input=n rerun=true\ncat\n```\n\n```result\nfresh\n```"))
	assert(
		string.find(text(), "```sh id=n\necho fresh\n```\n\n```result\nfresh\n```", 1, true),
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

test("a block changed while it waits for its input doesn't run for an agent", function(t)
	local dir = t:tempdir({
		["run.md"] = "```sh id=slow\nsleep 0.3; echo in\n```\n\n```sh id=b input=slow\ncat\n```\n",
	})
	local path = dir .. "/run.md"
	greed.open(path)
	t:run("blocks-trust")
	local buffer = greed.view():buffer()
	local result: any = nil
	greed.spawn(function()
		result = { pcall(tool, "blocks_run", { path = path, id = "b" }) }
	end)
	t:wait(50)
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
	assert(shown == "■ running" and from == 0, `{shown} at {from}`)
	buffer:edit(function(e)
		e:insert(0, "intro\n\n")
	end)
	shown, from = status()
	assert(shown == "■ running" and from == 7, `{shown} at {from}`)
	t:wait_for(has("```result"))
	assert(text() == "intro\n\n```sh\nsleep 0.3; echo done\n```\n\n```result\ndone\n```", text())
	assert(status() == nil, "nothing shows as running once it's done")
end)
