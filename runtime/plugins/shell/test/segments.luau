local test = require("@greed/test")
local greed = require("@greed")
local shell = require("@shell")

type Shell = typeof(shell.open())

local segments = shell.segments

local function open(t: test.TestContext, dir: string): Shell
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = dir
	return sh
end

-- What the prompt shows before what's typed: each piece's text and style.
local function prompt(sh: Shell): { { text: string, style: string } }
	local pieces: { { text: string, style: string } } = {}
	for _, mark in sh.buffer:decorations("shell.prompt") do
		if mark.text and mark.lines == nil then
			table.insert(pieces, { text = mark.text, style = mark.style or "" })
		end
	end
	return pieces
end

local function prompt_text(sh: Shell): string
	local parts: { string } = {}
	for _, piece in prompt(sh) do
		table.insert(parts, piece.text)
	end
	return table.concat(parts)
end

-- Works out `sh`'s segments again and waits until its prompt has `text`.
local function shows(t: test.TestContext, sh: Shell, text: string)
	segments.refresh(sh)
	t:wait_for(function()
		return string.find(prompt_text(sh), text, 1, true) ~= nil
	end, 20000)
end

test("the prompt shows the git branch, and leaves it out outside a repository", function(t)
	local dir, git = t:repo("git", { ["a.txt"] = "a\n" })
	git("checkout", "-q", "-b", "feature/x")
	assert(segments.head_branch(dir) == "feature/x", tostring(segments.head_branch(dir)))
	local sh = open(t, dir)
	shows(t, sh, "⎇ feature/x")
	local elsewhere = t:tempdir()
	local block = assert(shell.run(sh, `cd {elsewhere}`))
	t:wait_for(function()
		return block.status ~= "running" and not string.find(prompt_text(sh), "⎇", 1, true)
	end, 20000)
	assert(segments.head_branch(elsewhere) == nil)
end)

test("a plugin's segment shows before the folder, after the shell's own", function(t)
	local dir = t:tempdir()
	local sh = open(t, dir)
	shell.segment("test-cloud", function(ctx)
		return { text = `☁ {ctx.env.GREED_TEST_PROFILE or "none"}`, style = "shell.segment" }
	end)
	shell.segment("test-empty", function()
		return nil
	end)
	sh.env.GREED_TEST_PROFILE = "staging"
	shows(t, sh, "☁ staging")
	local pieces = prompt(sh)
	assert(pieces[#pieces - 2].text == "☁ staging ", pieces[#pieces - 2].text)
	assert(string.find(pieces[#pieces - 1].text, "/", 1, true), "the folder after it")
	local help = assert(shell.run(sh, "help prompt"))
	t:wait_for(function()
		return help.status ~= "running"
	end)
	-- Other plugins' segments, like kubernetes, may come before them.
	assert(string.find(help.output, "From plugins: ", 1, true), help.output)
	assert(string.find(help.output, "test-cloud, test-empty.", 1, true), help.output)
end)

test("starship's prompt is read as runs of colors, without its character", function()
	local read = shell.starship.read
	local two = read(
		"\n\27[1;34m☸ ctx\27[0m in \27[1;38;5;208m~/src\27[0m via \27[38;2;1;2;3mx\27[0m \n\27[1;32m❯\27[0m "
	)
	local texts: { string } = {}
	for _, segment in two do
		table.insert(texts, `{segment.text}|{segment.style or ""}`)
	end
	local all = table.concat(texts, ",")
	assert(all == "☸ ctx|=fg:blue bold, in |=,~/src|=fg:#ff8700 bold, via |=,x|=fg:#010203", all)
	-- A prompt of one line ends with its character, which goes too.
	local one = read("\27[36m~/src\27[0m on main \27[32m➜\27[0m ")
	assert(#one == 2 and one[1].text == "~/src" and one[2].text == " on main", tostring(#one))
	-- Window titles and links aren't text.
	local titled = read("\27]0;title\7\27]8;;http://x\27\\here\27]8;;\27\\\n❯ ")
	assert(#titled == 1 and titled[1].text == "here", titled[1] and titled[1].text)
end)

test("with shell-prompt starship, starship draws the prompt before ❯", function(t)
	local dir = t:tempdir({
		["bin/starship"] = '#!/bin/sh\necho "$*" > "$(dirname "$0")/args"\nprintf "\\n\\033[1;35mfrom starship\\033[0m \\n\\033[32m❯\\033[0m "\n',
	})
	assert(greed.process.run({ "chmod", "+x", `{dir}/bin/starship` }))
	local sh = open(t, dir)
	local path = assert(greed.process.run({ "printenv", "PATH" })).stdout
	sh.env.PATH = `{dir}/bin:{string.gsub(path, "\n$", "")}`
	local ran = assert(shell.run(sh, "false", { view = greed.view() }))
	t:wait_for(function()
		return ran.status ~= "running"
	end)
	greed.option.set("shell-prompt", "starship")
	shows(t, sh, "from starship")
	local text = prompt_text(sh)
	assert(
		not string.find(text, shell.log.short_folder(dir), 1, true),
		"starship shows the folder: " .. text
	)
	assert(string.find(text, "❯ $"), text)
	local args = greed.fs.read(`{dir}/bin/args`) or ""
	assert(
		string.find(args, "--status 1", 1, true) and string.find(args, "--jobs 0", 1, true),
		args
	)
	greed.option.set("shell-prompt", "greed")
	shows(t, sh, shell.log.short_folder(dir))
end)

test("shell-icons picks the icons of the shell's own segments", function(t)
	assert(segments.icon("git") == "⎇")
	greed.option.set("shell-icons", "nerd")
	assert(segments.icon("git") == "\u{e0a0}" and segments.icon("nope") == "")
	greed.option.set("shell-icons", "plain")
end)

test("a plugin gives its segment icons, and shell-icons picks between them", function()
	assert(segments.icon("test-cloud") == "")
	shell.segment_icon("test-cloud", { plain = "☁", nerd = "\u{f0c2}" })
	assert(segments.icon("test-cloud") == "☁")
	greed.option.set("shell-icons", "nerd")
	assert(segments.icon("test-cloud") == "\u{f0c2}")
	greed.option.set("shell-icons", "plain")
end)

test("a context matching shell-production-contexts is a production one", function()
	assert(segments.production("prod-eu") and not segments.production("dev"))
	greed.option.set("shell-production-contexts", "^live dev")
	assert(segments.production("live-1") and segments.production("my-dev"))
	assert(not segments.production("prod-eu"))
	greed.option.set("shell-production-contexts", "prod")
end)
