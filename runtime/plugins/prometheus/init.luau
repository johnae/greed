-- Prometheus in the shell: `prom QUERY` asks a Prometheus server (the
-- `prometheus-url` option, or `--url`) and prints what it answers as rows,
-- which the shell shows as a table and `| chart` draws.
--
--   prom 'up'                              a row a series, as it is now
--   prom 'rate(http_requests_total[5m])' | chart          bars of each
--   watch -n 5 prom 'rate(http_requests_total[5m])' | chart
--                                          a line a series, as it goes
--   prom 'node_load1' --range 1h | chart    the last hour, a line a series
--
-- A series is named by its labels' values, `api/10.0.0.1:9100`, or its
-- metric's name when it has none of its own.

local greed = require("@greed")
local core = require("@core")
local shell = require("@shell")

local M = {}

greed.option.define({
	name = "prometheus-url",
	doc = "The Prometheus server `prom` asks, unless --url says",
	default = "http://localhost:9090",
})

--- Gets `url`, a query to Prometheus's API: the body, or nil and why.
--- Tests put their own here.
function M.fetch(url: string): (string?, string?)
	if not string.match(url, "^https?://[^/]+[^?]*/api/v1/query[_%w]*%?") then
		return nil, `prom only asks for queries, not {url}`
	end
	-- As prom's own: the shell running it can't use the network.
	local response, err = greed.vouch(function()
		return greed.http.request({ url = url, timeout = 30000 })
	end)
	if response == nil then
		return nil, err
	end
	if response.status ~= 200 then
		local said = string.match(response.body, '"error"%s*:%s*"([^"]*)"')
		return nil, said or `the server answered {response.status}`
	end
	return response.body, nil
end

local encoded = core.text.percent_encode

local UNITS: { [string]: number } = { s = 1, m = 60, h = 3600, d = 86400, w = 7 * 86400 }

--- `text`, like `1h`, `30m` or `90s`, in seconds; nil when it isn't one.
function M.seconds(text: string): number?
	local n, unit = string.match(text, "^(%d+%.?%d*)([smhdw]?)$")
	local amount = tonumber(n)
	if amount == nil or unit == nil then
		return nil
	end
	return amount * (UNITS[unit] or 1)
end

--- A series' name, from its labels: their values, `/` between them, in
--- the order of their names; its metric's name when that's all it has.
function M.name(metric: { [string]: string }): string
	local keys: { string } = {}
	for key in metric do
		if key ~= "__name__" then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	local values: { string } = {}
	for _, key in keys do
		table.insert(values, metric[key])
	end
	if #values == 0 then
		return metric.__name__ or "value"
	end
	return table.concat(values, "/")
end

--- What Prometheus answered, `body`, as rows: for a query now, a row a
--- series with its name and value; over a range, a row a time with a
--- column a series. Nil and why when it's an error.
function M.rows(body: string): ({ { [string]: any } }?, string?)
	local ok, answer = pcall(greed.json.decode, body)
	if not ok or type(answer) ~= "table" then
		return nil, "Prometheus didn't answer with JSON"
	end
	if answer.status ~= "success" then
		return nil, answer.error or "Prometheus said it failed"
	end
	local data = answer.data or {}
	local result = data.result or {}
	local rows: { { [string]: any } } = {}
	if data.resultType == "scalar" or data.resultType == "string" then
		return { { name = "value", value = tonumber(result[2]) or result[2] } }, nil
	elseif data.resultType == "vector" then
		for _, series in result do
			local value = tonumber(series.value[2])
			-- NaN isn't a number to chart.
			if value and value == value then
				local row: { [string]: any } = { name = M.name(series.metric or {}), value = value }
				table.insert(rows, row)
			end
		end
		return rows, nil
	end
	-- A matrix: the times every series has a value at, in order.
	local at: { [number]: { [string]: any } } = {}
	local times: { number } = {}
	for _, series in result do
		local name = M.name(series.metric or {})
		for _, point in series.values or {} do
			local t, value = tonumber(point[1]), tonumber(point[2])
			if t and value and value == value then
				local row = at[t]
				if row == nil then
					row = { time = core.time.iso_text(t) }
					at[t] = row
					table.insert(times, t)
				end
				row[name] = value
			end
		end
	end
	table.sort(times)
	for _, t in times do
		table.insert(rows, at[t])
	end
	return rows, nil
end

--- How to ask: the server, and for a range, how long back from `now`
--- (seconds since 1970, the time by default) and the seconds between
--- points.
export type QueryOptions = { url: string?, range: number?, step: number?, now: number? }

--- What `query` gives at `url` (the `prometheus-url` option without one):
--- now, or over the last `range` seconds a `step` apart. Rows as `rows`
--- gives them, or nil and why.
function M.query(query: string, options: QueryOptions?): ({ { [string]: any } }?, string?)
	local opts: QueryOptions = options or {}
	local base = string.gsub(opts.url or greed.option.get("prometheus-url") :: string, "/+$", "")
	local url: string
	local range = opts.range
	if range then
		local finish = opts.now or os.time()
		local step = opts.step or math.max(math.floor(range / 120), 1)
		url =
			`{base}/api/v1/query_range?query={encoded(query)}&start={finish - range}&end={finish}&step={step}`
	else
		url = `{base}/api/v1/query?query={encoded(query)}`
	end
	local body, err = M.fetch(url)
	if body == nil then
		return nil, `can't ask {base}: {err}`
	end
	return M.rows(body)
end

local USAGE = "prom QUERY [--range DURATION] [--step DURATION] [--url URL]"

shell.builtin({
	name = "prom",
	usage = USAGE,
	doc = "Ask Prometheus: a row a series as it is now, or over a range a row a time, to table or chart",
}, function(args, ctx)
	local query: string? = nil
	local opts: QueryOptions = {}
	local i = 1
	while i <= #args do
		local word = args[i]
		if word == "--range" or word == "--step" then
			i += 1
			local seconds = M.seconds(args[i] or "")
			if seconds == nil then
				error(`{word} takes a duration like 30s, 5m or 1h: {USAGE}`, 0)
			end
			if word == "--range" then
				opts.range = seconds
			else
				opts.step = seconds
			end
		elseif word == "--url" then
			i += 1
			opts.url = args[i]
		elseif query == nil then
			query = word
		else
			error(`one query at a time, in quotes: {USAGE}`, 0)
		end
		i += 1
	end
	if query == nil then
		error(USAGE, 0)
	end
	local rows, err = M.query(query, opts)
	if rows == nil then
		ctx.error((err or "") .. "\n")
		return 1
	end
	if #rows == 0 then
		ctx.error(`{query} matched no series\n`)
		return 1
	end
	ctx.write(greed.json.encode(rows) .. "\n")
	return 0
end)

return M
