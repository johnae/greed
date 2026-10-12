-- `kubectl get -o json` read as the table `kubectl get` prints, its
-- columns named the same, so table stages and `| chart` read the API's own
-- fields rather than columns on screen: pods' readiness, status and
-- restarts, deployments' replicas, any object's name and age.

local core = require("@core")
local shell = require("@shell")

type Table = shell.Table

local M = {}

-- How long ago `stamp`, an ISO 8601 time, was, as kubectl writes an age:
-- in its largest whole unit, `3d`, `5h`, `12m`, `40s`.
local function age(stamp: string?, now: number): string
	local t = if stamp then core.time.iso(stamp) else nil
	return if t then core.time.age(now - t) else ""
end

-- A pod's columns: how many of its containers are ready of how many, its
-- status (a container's reason for waiting, as CrashLoopBackOff, ahead of
-- the pod's phase), and its containers' restarts.
local function pod(item: any, row: { [string]: string })
	local status = item.status or {}
	local containers = status.containerStatuses or {}
	local ready, restarts = 0, 0
	local reason: string? = nil
	for _, c in containers do
		if c.ready then
			ready += 1
		end
		restarts += c.restartCount or 0
		local waiting = c.state and c.state.waiting
		reason = reason or (waiting and waiting.reason)
	end
	row.READY = `{ready}/{#containers}`
	row.STATUS = reason or status.phase or ""
	row.RESTARTS = tostring(restarts)
end

-- A deployment's columns: ready replicas of those wanted, updated and
-- available ones.
local function deployment(item: any, row: { [string]: string })
	local status = item.status or {}
	local wanted = (item.spec and item.spec.replicas) or 0
	row.READY = `{status.readyReplicas or 0}/{wanted}`
	row["UP-TO-DATE"] = tostring(status.updatedReplicas or 0)
	row.AVAILABLE = tostring(status.availableReplicas or 0)
end

-- A node's status: Ready, NotReady, or Unknown.
local function node(item: any, row: { [string]: string })
	local state = "Unknown"
	local conditions: { any } = (item.status and item.status.conditions) or {}
	for _, condition in conditions do
		if condition.type == "Ready" then
			state = if condition.status == "True" then "Ready" else "NotReady"
		end
	end
	row.STATUS = state
end

-- The columns each kind of object has, besides NAME and AGE, as kubectl
-- prints them, and what fills them.
local KINDS: { [string]: { columns: { string }, fill: (any, { [string]: string }) -> () } } = {
	Pod = { columns = { "READY", "STATUS", "RESTARTS" }, fill = pod },
	Deployment = { columns = { "READY", "UP-TO-DATE", "AVAILABLE" }, fill = deployment },
	Node = { columns = { "STATUS" }, fill = node },
}

--- `value`, what `kubectl get -o json` printed (a list of objects or one),
--- as the table `kubectl get` prints, at `now` for the ages. NAMESPACE
--- comes first when the objects are in more than one. Nil when it isn't
--- kubernetes objects.
function M.table(value: any, now: number?): Table?
	if type(value) ~= "table" then
		return nil
	end
	local items = if value.items then value.items else { value }
	if #items == 0 or type(items[1]) ~= "table" or items[1].metadata == nil then
		return nil
	end
	local at = now or os.time()
	local namespaces: { [string]: boolean } = {}
	local count = 0
	for _, item in items do
		local namespace = item.metadata and item.metadata.namespace
		if namespace and not namespaces[namespace] then
			namespaces[namespace] = true
			count += 1
		end
	end
	local known = KINDS[items[1].kind or ""]
	local columns: { string } = if count > 1 then { "NAMESPACE", "NAME" } else { "NAME" }
	if known then
		table.move(known.columns, 1, #known.columns, #columns + 1, columns)
	end
	table.insert(columns, "AGE")
	local rows: { { [string]: string } } = {}
	for _, item in items do
		local meta = item.metadata or {}
		local row: { [string]: string } = {
			NAME = meta.name or "",
			NAMESPACE = meta.namespace or "",
			AGE = age(meta.creationTimestamp, at),
		}
		local own = KINDS[item.kind or ""]
		if own then
			own.fill(item, row)
		end
		table.insert(rows, row)
	end
	return { columns = columns, rows = rows }
end

return M
