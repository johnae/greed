local test = require("@greed/test")
local greed = require("@greed")

-- A program speaking JSON-RPC a line each: it says hello, asks to double
-- 21 and writes down the answer, then answers each request with "ok" and
-- its id.
local PROGRAM = [[
echo '{"jsonrpc":"2.0","method":"hello","params":{"n":1}}'
echo '{"jsonrpc":"2.0","id":7,"method":"double","params":{"n":21}}'
read -r answer
printf '%s\n' "$answer" > answer
while read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"said\":\"ok $id\"}}"
done
]]

test("a program speaking JSON-RPC is asked, answered and heard", function(t)
	local dir = t:tempdir({})
	local heard: { string } = {}
	local conn = assert(greed.rpc.start({ "sh", "-c", PROGRAM }, {
		cwd = dir,
		framing = "lines",
		on_notify = function(method: string, params: any)
			table.insert(heard, `{method} {params.n}`)
		end,
		on_request = function(method: string, params: any): (any, string?)
			return if method == "double" then params.n * 2 else nil, nil
		end,
	}))
	t:wait_for(function()
		-- Whole: the file is there before the line is in it.
		return string.find(greed.fs.read(`{dir}/answer`) or "", "\n$") ~= nil
	end)
	assert(table.concat(heard, ",") == "hello 1", table.concat(heard, ","))
	local answer = greed.json.decode((assert(greed.fs.read(`{dir}/answer`))))
	assert(answer.id == 7 and answer.result == 42, greed.json.encode(answer))
	local result, err = conn:request("ping", { a = 1 })
	assert(result and string.match(result.said, "^ok %d+$"), tostring(err))
	assert(conn:alive())
	conn:close()
	assert(not conn:alive())
	local late, why = conn:request("ping", {})
	assert(late == nil and why ~= nil, "a closed connection says so")
end)

test("a request the program can't answer before it exits says so", function(t)
	local exited: string? = nil
	local conn = assert(greed.rpc.start({ "sh", "-c", "read -r line; echo gone >&2" }, {
		framing = "lines",
		on_exit = function(stderr: string)
			exited = stderr
		end,
	}))
	local result, err = conn:request("anything", {})
	assert(result == nil and string.find(tostring(err), "exited", 1, true), tostring(err))
	t:wait_for(function()
		return exited ~= nil
	end)
	assert(exited == "gone", tostring(exited))
	local missing, why = greed.rpc.start({ "greed-no-such-program" })
	assert(missing == nil and string.find(tostring(why), "can't run", 1, true), tostring(why))
end)
