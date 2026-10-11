-- Kubernetes in the shell. The prompt shows the context and namespace
-- kubectl would use, read from its config without running it, in red
-- when the context is a production one (`shell-production-contexts`).
-- `kubectl get`'s rows are pods, deployments and other objects, in the
-- context and namespace the command ran against, to describe, read the
-- logs of, open a shell in, restart or delete; and they complete the
-- next kubectl command. `space o k` and `space o K` switch the context and
-- namespace, everywhere or in one shell (context.luau). A `kubectl get`
-- block shows another resource or namespace in its place, live if it was
-- (browse.luau).

local shell = require("@shell")
local config = require("@self/config")
require("@self/objects")
local context = require("@self/context")
local browse = require("@self/browse")

local M = {}

--- The kubeconfig files kubectl would read for a shell; see `config.files`.
M.kubeconfigs = config.files

--- The context a kubeconfig's text says is current, and its namespace;
--- see `config.read`.
M.read_kubeconfig = config.read

--- The context and namespace kubectl's config makes current for a shell.
M.current = config.current

--- Switching the context and namespace, everywhere or in one shell; see
--- context.luau.
M.context = context

--- A `kubectl get` line showing another resource or namespace; see
--- browse.luau.
M.retarget = browse.retarget

shell.segment_icon("kubernetes", { plain = "⎈", nerd = "\u{f10fe}" })

shell.segment("kubernetes", function(ctx: shell.SegmentContext): shell.Segment?
	local context, namespace = config.current(ctx.shell)
	if context == nil then
		return nil
	end
	local warn = shell.segments.production(context)
	local icon = shell.segments.icon("kubernetes")
	return {
		text = if namespace then `{icon} {context}:{namespace}` else `{icon} {context}`,
		style = if warn then "shell.segment.warning" else "shell.segment.kubernetes",
		warning = warn,
		action = "kube-context",
	}
end)

return M
