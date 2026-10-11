-- Charts drawn as scenes: lines, areas and dots over an x and y axis, and
-- bars across, with labels, values and a legend when there's more than
-- one series. Everything is placed in cells, so the scene reads the same
-- drawn in characters or as an image.

local scene = require("@scene")
local scale = require("./scale")

local M = {}

--- A series: its name, its points (x then y), and what its numbers are
--- (see `scale.unit`) when that's its own.
export type Series = { name: string, points: { { number } }, unit: string? }

--- What to draw: the kind, the series, the category of each bar, what the
--- x values are ("index", "time" in seconds since 1970, or "number"),
--- and how.
export type Chart = {
	kind: string,
	series: { Series },
	labels: { string }?,
	x: string,
	log: boolean?,
	stacked: boolean?,
	--- What the y axis's numbers are: "bytes", "cores" or "percent".
	unit: string?,
	--- What the chart shows, in words, for its `alt`.
	about: string,
}

-- The style of series `i`, from 1: eight, then round again.
local function style(i: number): string
	return `chart.series.{(i - 1) % 8 + 1}`
end

-- Puts a legend on row 0, naming each series in its style, as many as fit
-- in `cols`. Returns whether there was one.
local function legend(items: { scene.Item }, series: { Series }, cols: number): boolean
	if #series < 2 then
		return false
	end
	local x = 0
	for i, s in series do
		local text = `━ {s.name}`
		local width = utf8.len(text) or #text
		if x + width > cols then
			table.insert(
				items,
				{ kind = "text", at = { x, 0 }, text = `+{#series - i + 1}`, style = "chart.label" }
			)
			break
		end
		table.insert(items, { kind = "text", at = { x, 0 }, text = text, style = style(i) })
		x += width + 2
	end
	return true
end

-- An x value written for the axis.
local function x_label(x: number, kind: string, step: number): string
	if kind == "time" then
		return os.date("%H:%M:%S", math.floor(x)) :: string
	end
	return scale.format(x, step)
end

-- `y` as the axis has it: its log with `log`, of what's above zero.
local function on_axis(y: number, log: boolean?): number?
	if not log then
		return y
	end
	return if y > 0 then math.log10(y) else nil
end

-- Lines, areas or dots over x and y axes.
local function plot(chart: Chart, cols: number, rows: number): { scene.Item }
	local items: { scene.Item } = {}
	local top = if legend(items, chart.series, cols) then 1 else 0
	local xlo: number, xhi: number, ylo: number, yhi: number =
		math.huge, -math.huge, math.huge, -math.huge
	for _, s in chart.series do
		for _, p in s.points do
			local x: number = p[1] :: number
			local y: number? = on_axis(p[2] :: number, chart.log)
			if y ~= nil then
				local v: number = y
				xlo, xhi = math.min(xlo, x), math.max(xhi, x)
				ylo, yhi = math.min(ylo, v), math.max(yhi, v)
			end
		end
	end
	if xlo > xhi then
		table.insert(
			items,
			{ kind = "text", at = { 0, top }, text = "nothing to chart yet", style = "chart.label" }
		)
		return items
	end
	-- Areas stand on zero, which shows how much rather than how it moved.
	if chart.kind == "area" and not chart.log then
		if ylo > 0 then
			ylo = 0
		end
		if yhi < 0 then
			yhi = 0
		end
	end
	local bottom = rows - 1
	local count = math.max(math.floor((bottom - top) / 3), 2)
	local ticks = scale.ticks_in(ylo, yhi, count, if chart.log then nil else chart.unit)
	local labels: { string } = {}
	local width = 0
	for _, v in ticks.values do
		local text = scale.format(
			if chart.log then 10 ^ v else v,
			if chart.log then nil else ticks.step,
			chart.unit
		)
		table.insert(labels, text)
		width = math.max(width, utf8.len(text) or #text)
	end
	local left, right = width + 1, cols - 0.5
	local high, low = top + 0.125, bottom - 0.25
	local function sy(v: number): number
		return low - (v - ticks.lo) / (ticks.hi - ticks.lo) * (low - high)
	end
	local xspan = if xhi > xlo then xhi - xlo else 1
	local function sx(x: number): number
		return if xhi > xlo then left + (x - xlo) / xspan * (right - left) else (left + right) / 2
	end
	-- A label a row: on a short chart, ticks closer than that would run
	-- together.
	local labelled: { [number]: boolean } = {}
	for i, v in ticks.values do
		local row = math.floor(sy(v))
		if not labelled[row] then
			labelled[row] = true
			table.insert(items, {
				kind = "text",
				at = { width, sy(v) },
				text = labels[i],
				align = "end",
				style = "chart.label",
			})
		end
	end
	table.insert(items, {
		kind = "line",
		points = { { left - 0.75, high }, { left - 0.75, low } },
		style = "chart.axis",
	})
	local plotted: { scene.Item } = {}
	for i, s in chart.series do
		local points: { scene.Point } = {}
		for _, p in s.points do
			local y = on_axis(p[2] :: number, chart.log)
			if y then
				table.insert(points, { sx(p[1] :: number), sy(y) })
			end
		end
		if chart.kind == "area" then
			table.insert(plotted, {
				kind = "area",
				points = points,
				base = sy(math.max(ticks.lo, 0)),
				fill = style(i),
				opacity = 0.3,
			})
			table.insert(plotted, { kind = "line", points = points, style = style(i) })
		elseif chart.kind == "scatter" then
			table.insert(plotted, { kind = "dots", points = points, style = style(i) })
		else
			table.insert(plotted, { kind = "line", points = points, style = style(i) })
		end
	end
	table.insert(
		items,
		{ kind = "group", clip = { left - 0.5, top, cols, bottom }, items = plotted }
	)
	local step = if chart.x == "index" then 1 else xspan / 4
	local first, last = x_label(xlo, chart.x, step), x_label(xhi, chart.x, step)
	table.insert(
		items,
		{ kind = "text", at = { left, bottom }, text = first, style = "chart.label" }
	)
	if xhi > xlo then
		table.insert(items, {
			kind = "text",
			at = { cols, bottom },
			text = last,
			align = "end",
			style = "chart.label",
		})
	end
	return items
end

-- Bars across: a row each, the label on the left, the value after the bar.
-- With several series each label gets a row a series, or one row of them
-- end to end with `stacked`. Series in another unit than the first are
-- each as long as their own greatest, as CPU and bytes share no scale.
local function bars(chart: Chart, cols: number, rows: number): { scene.Item }
	local items: { scene.Item } = {}
	local top = if legend(items, chart.series, cols) then 1 else 0
	local labels: { string } = chart.labels or {}
	local shared = true
	if not chart.stacked then
		for _, s in chart.series do
			if s.unit ~= chart.series[1].unit then
				shared = false
			end
		end
	end
	local own: { number } = {}
	local most = 0
	local values: { { number } } = {}
	local totals: { number } = {}
	for i = 1, #labels do
		values[i] = {}
		local total = 0
		for k, s in chart.series do
			local p = s.points[i]
			local v = if p then math.max(p[2] :: number, 0) else 0
			values[i][k] = v
			total += v
			most = math.max(most, v)
			own[k] = math.max(own[k] or 0, v)
		end
		totals[i] = total
		if chart.stacked then
			most = math.max(most, total)
		end
	end
	local label_width = 0
	for _, label in labels do
		label_width = math.max(label_width, utf8.len(label) or #label)
	end
	label_width = math.min(label_width, math.floor(cols * 0.35))
	local value_width = 1
	for k, s in chart.series do
		value_width =
			math.max(value_width, #scale.format(own[k] or 0, nil, s.unit or chart.unit) + 1)
	end
	-- A stacked bar is labelled with its total.
	if chart.stacked then
		value_width = math.max(value_width, #scale.format(most, nil, chart.unit) + 1)
	end
	local left = label_width + 1
	local room = math.max(cols - left - value_width, 1)
	local per = if chart.stacked then 1 else #chart.series
	local fits = math.max((rows - top) // per, 1)
	local shown = if #labels > fits then fits - 1 else #labels
	for i = 1, shown do
		local row = top + (i - 1) * per
		local label = labels[i]
		if (utf8.len(label) or #label) > label_width then
			label = string.sub(label, 1, (utf8.offset(label, label_width) or label_width + 1) - 1)
				.. "…"
		end
		table.insert(items, { kind = "text", at = { 0, row }, text = label, style = "chart.label" })
		local x = left
		for k = 1, #chart.series do
			local v = values[i][k]
			local greatest = if shared then most else own[k] or 0
			local long = if greatest > 0 then v / greatest * room else 0
			local y = if chart.stacked then row else row + k - 1
			if not chart.stacked then
				x = left
			end
			-- A little less than a row tall, so bars drawn as an image
			-- don't touch; in characters it's a row of blocks.
			table.insert(
				items,
				{ kind = "rect", at = { x, y + 0.15 }, size = { long, 0.7 }, fill = style(k) }
			)
			x += long
			if not chart.stacked then
				table.insert(items, {
					kind = "text",
					at = { math.ceil(x) + 1, y },
					text = scale.format(v, nil, chart.series[k].unit or chart.unit),
					style = "chart.label",
				})
			end
		end
		if chart.stacked then
			table.insert(items, {
				kind = "text",
				at = { math.ceil(x) + 1, row },
				text = scale.format(totals[i], nil, chart.unit),
				style = "chart.label",
			})
		end
	end
	if shown < #labels then
		table.insert(items, {
			kind = "text",
			at = { 0, top + shown * per },
			text = `… {#labels - shown} more`,
			style = "chart.label",
		})
	end
	return items
end

--- `chart` as a scene `cols` by `rows` cells.
function M.scene(chart: Chart, cols: number, rows: number): scene.Spec
	local items = if chart.kind == "bar" then bars(chart, cols, rows) else plot(chart, cols, rows)
	return { alt = chart.about, items = items }
end

return M
