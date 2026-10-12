-- Times and durations as Greed writes and reads them, the same everywhere:
-- ages as kubectl writes them, how long ago in words, how long something
-- took, and ISO 8601.

local M = {}

-- Units an age is written in, largest first.
local UNITS: { { seconds: number, name: string } } = {
	{ seconds = 86400, name = "d" },
	{ seconds = 3600, name = "h" },
	{ seconds = 60, name = "m" },
}

--- How old something `seconds` old is, in its largest whole unit, as
--- kubectl writes an age: `3d`, `5h`, `12m`, `40s`.
function M.age(seconds: number): string
	local whole = math.max(math.floor(seconds), 0)
	for _, unit in UNITS do
		if whole >= unit.seconds then
			return `{whole // unit.seconds}{unit.name}`
		end
	end
	return `{whole}s`
end

--- How long ago something `seconds` back was, roughly, in words: "just
--- now", "4 min ago", "3 h ago", "2 days ago".
function M.ago(seconds: number): string
	if seconds < 60 then
		return "just now"
	elseif seconds < 3600 then
		return `{seconds // 60} min ago`
	elseif seconds < 2 * 86400 then
		return `{seconds // 3600} h ago`
	end
	return `{seconds // 86400} days ago`
end

--- How long `ms` milliseconds is, shortly: "0.04s", "3.2s", "2m 05s".
--- With `whole`, in whole seconds ("9s"), for a count that ticks each
--- second.
function M.duration(ms: number, whole: boolean?): string
	local seconds = math.max(ms, 0) / 1000
	if seconds < 60 and whole then
		return `{math.floor(seconds)}s`
	elseif seconds < 10 then
		return string.format("%.2fs", seconds)
	elseif seconds < 60 then
		return string.format("%.1fs", seconds)
	end
	local s = math.floor(seconds)
	return string.format("%dm %02ds", s // 60, s % 60)
end

--- `text` read as a date and time in ISO 8601 ("2026-10-10T10:55:08.68+02:00"),
--- in seconds since 1970, and whether it named its zone (one without is
--- taken as UTC); nil when it isn't one.
function M.iso(text: string): (number?, boolean)
	local y, mo, d, h, mi, s, rest =
		string.match(text, "^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)[%.%d]*(.*)$")
	if y == nil or mo == nil or d == nil or h == nil or mi == nil or s == nil or rest == nil then
		return nil, false
	end
	local offset = 0
	if rest ~= "Z" and rest ~= "" then
		local sign, oh, om = string.match(rest, "^([+-])(%d%d):?(%d%d)$")
		if sign == nil or oh == nil or om == nil then
			return nil, false
		end
		offset = ((tonumber(oh) :: number) * 3600 + (tonumber(om) :: number) * 60)
			* (if sign == "-" then -1 else 1)
	end
	-- Days since 1970 of the date, as the proleptic Gregorian calendar
	-- counts them.
	local year, month, day = tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number
	year -= if month <= 2 then 1 else 0
	local era = year // 400
	local yoe = year - era * 400
	local doy = (153 * (month + (if month > 2 then -3 else 9)) + 2) // 5 + day - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	local days = era * 146097 + doe - 719468
	local seconds = days * 86400
		+ (tonumber(h) :: number) * 3600
		+ (tonumber(mi) :: number) * 60
		+ tonumber(s) :: number
	return seconds - offset, rest ~= ""
end

--- `seconds` since 1970 in ISO 8601, in UTC: "2026-10-10T08:55:08Z".
function M.iso_text(seconds: number): string
	return os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(seconds)) :: string
end

return M
