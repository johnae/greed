local test = require("@greed/test")
local greed = require("@greed")
local shell = require("@shell")
local kubernetes = require("@kubernetes")

type Shell = typeof(shell.open())

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
	shell.refresh_prompt(sh)
	t:wait_for(function()
		return string.find(prompt_text(sh), text, 1, true) ~= nil
	end, 20000)
end

local KUBECONFIG = [[
apiVersion: v1
clusters:
- cluster:
    server: https://example.invalid
  name: eu
contexts:
- context:
    cluster: eu
    user: me
  name: dev
- context:
    cluster: eu
    namespace: payments
    user: me
  name: "prod-eu"
current-context: prod-eu
kind: Config
users:
- name: me
  user:
    token: not-a-real-one
]]

test("a kubeconfig says the context in use and its namespace", function()
	local context, namespace = kubernetes.read_kubeconfig(KUBECONFIG)
	assert(context == "prod-eu" and namespace == "payments", `{context} {namespace}`)
	local dev, none = kubernetes.read_kubeconfig(
		(string.gsub(KUBECONFIG, "current%-context: prod%-eu", "current-context: dev"))
	)
	assert(dev == "dev" and none == nil, `{dev} {none}`)
	assert(kubernetes.read_kubeconfig("apiVersion: v1\nkind: Config\n") == nil, "no context")
	assert(shell.production("prod-eu") and not shell.production("dev"))
end)

test(
	"the prompt shows the kube context, red when it's production, and follows a change",
	function(t)
		local dir = t:tempdir({ ["kube/config"] = KUBECONFIG })
		local sh = open(t, dir)
		sh.env.KUBECONFIG = `{dir}/kube/config`
		shows(t, sh, "⎈ prod-eu:payments")
		local pieces = prompt(sh)
		local kube = pieces[#pieces - 2]
		assert(
			kube.text == "⎈ prod-eu:payments " and kube.style == "shell.segment.warning",
			kube.text
		)
		assert(
			pieces[#pieces].text == "❯ " and pieces[#pieces].style == "shell.prompt.warning",
			pieces[#pieces].style
		)
		-- Patterns of your own.
		greed.option.set("shell-production-contexts", "^live")
		shell.refresh_prompt(sh)
		t:wait_for(function()
			local all = prompt(sh)
			return all[#all].style == "shell.prompt"
		end, 20000)
		greed.option.set("shell-production-contexts", "prod")
		-- `kubectl config use-context dev`, as the file says after it.
		assert(
			greed.fs.write(
				`{dir}/kube/config`,
				(string.gsub(KUBECONFIG, "current%-context: prod%-eu", "current-context: dev"))
			)
		)
		local block = assert(shell.run(sh, "true"))
		t:wait_for(function()
			return block.status ~= "running"
				and string.find(prompt_text(sh), "⎈ dev ", 1, true) ~= nil
		end, 20000)
		local after = prompt(sh)
		assert(after[#after].style == "shell.prompt", "not production now")
	end
)

test("KUBECONFIG can name several files, the first with a context counting", function(t)
	local dir = t:tempdir({ ["a"] = "apiVersion: v1\nkind: Config\n", ["b"] = KUBECONFIG })
	local sh = open(t, dir)
	sh.env.KUBECONFIG = `{dir}/a:{dir}/b`
	shows(t, sh, "⎈ prod-eu:payments")
end)

test("without KUBECONFIG of its own, a shell reads the kubeconfig in Greed's home", function(t)
	local sh = open(t, t:tempdir())
	local home = assert(greed.fs.dirs().home)
	local files = kubernetes.kubeconfigs(sh)
	-- Under test, Greed's home is a folder of the test's own, not yours.
	assert(#files == 1 and files[1] == `{home}/.kube/config`, table.concat(files, " "))
end)
