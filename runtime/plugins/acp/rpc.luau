-- JSON-RPC 2.0 over a program's input and output, one message per line, as
-- the Agent Client Protocol has it. Requests wait for their answer;
-- requests and notifications from the program go to handlers, which may
-- wait too (to ask you, say) before they answer.
local greed = require("@greed")

local M = {}

--- What answers the program's requests and notifications, by method. A
--- request's handler returns the result, or nil and an error message.
export type Handlers = { [string]: (params: any) -> (any, string?) }

export type Conn = {
	child: greed.Child,
	--- Sends a request and waits for its result, or nil and the error.
	request: (method: string, params: any) -> (any, string?),
	notify: (method: string, params: any) -> (),
	--- Whether the program is still running.
	alive: () -> boolean,
	close: () -> (),
}

--- Starts `command` in `cwd` and talks JSON-RPC with it. `on_exit` is
--- called once it exits, with what it said on its error output.
function M.start(
	command: { string },
	cwd: string?,
	handlers: Handlers,
	on_exit: ((stderr: string) -> ())?
): (Conn?, string?)
	local child, err = greed.process.spawn(command, { cwd = cwd })
	if child == nil then
		return nil, err
	end
	local running = child
	local next_id = 0
	local waiting: { [number]: greed.Signal } = {}
	local alive = true

	local function send(message: any)
		message.jsonrpc = "2.0"
		running:write(greed.json.encode(message) .. "\n")
	end

	local function answer(id: any, method: string, params: any)
		local handler = handlers[method]
		if handler == nil then
			send({ id = id, error = { code = -32601, message = `{method} isn't supported` } })
			return
		end
		local ok, result, problem = pcall(handler, params)
		if not ok then
			send({ id = id, error = { code = -32603, message = tostring(result) } })
		elseif problem then
			send({ id = id, error = { code = -32603, message = problem } })
		else
			-- `null` can't be a Luau value, so no result answers with an empty object.
			send({ id = id, result = if result == nil then {} else result })
		end
	end

	local function receive(line: string)
		local message = greed.json.decode(line)
		if type(message) ~= "table" then
			return
		end
		local method = message.method
		if method and message.id ~= nil then
			-- A request: answered on its own, so a handler that waits
			-- doesn't hold up the messages after it.
			greed.spawn(answer, message.id, method, message.params)
		elseif method then
			local handler = handlers[method]
			if handler then
				greed.spawn(handler, message.params)
			end
		elseif message.id ~= nil then
			local signal = waiting[message.id]
			waiting[message.id] = nil
			if signal then
				signal:send(message)
			end
		end
	end

	greed.spawn(function()
		local pending = ""
		while true do
			local piece = running:read()
			if piece == nil then
				break
			end
			pending ..= piece
			while true do
				local at = string.find(pending, "\n", 1, true)
				if at == nil then
					break
				end
				local line = string.sub(pending, 1, at - 1)
				pending = string.sub(pending, at + 1)
				if string.match(line, "%S") then
					receive(line)
				end
			end
		end
		alive = false
		for id, signal in waiting do
			waiting[id] = nil
			signal:send({ error = { message = "the agent exited" } })
		end
		if on_exit then
			on_exit(running:stderr())
		end
	end)

	local conn: Conn = {
		child = running,
		request = function(method, params)
			if not alive then
				return nil, "the agent isn't running"
			end
			next_id += 1
			local id = next_id
			local signal = greed.signal()
			waiting[id] = signal
			send({ id = id, method = method, params = params })
			local reply = signal:wait()
			if reply.error then
				return nil, tostring(reply.error.message or "error")
			end
			return reply.result, nil
		end,
		notify = function(method, params)
			if alive then
				send({ method = method, params = params })
			end
		end,
		alive = function()
			return alive
		end,
		close = function()
			running:close()
			running:kill()
		end,
	}
	return conn, nil
end

return M
