-- Tools for agents: list a Markdown file's runnable blocks and run one,
-- the way you would, in files you've let run (a runbook, a notes page of
-- queries). Results land under the blocks in the buffer, in front of you.

local greed = require("@greed")
local agent = require("@agent")

-- What these need from the plugin, which loads them after it's set up.
export type Blocks = {
	runnable: (buffer: greed.Buffer) -> { any },
	run: (buffer: greed.Buffer, block: any) -> boolean,
	trusted: (buffer: greed.Buffer) -> boolean,
}

local function object(properties: { [string]: any }, required: { string }?): { [string]: any }
	return { type = "object", properties = properties, required = required }
end

return function(blocks: Blocks)
	-- A block as an agent sees it: where it is, what it runs as, its code and
	-- its result.
	local function describe(buffer: greed.Buffer, block: any, n: number): { [string]: any }
		return {
			index = n,
			line = block.open + 1,
			lang = block.lang,
			id = block.opts.id,
			code = buffer:slice(block.code_from, block.code_to),
			result = block.result and block.result.text,
		}
	end

	agent.tool({
		name = "blocks_list",
		description = "The runnable code blocks in a Markdown file: each one's index, 1-based line, language, id, code and saved result",
		input = object({ path = { type = "string" } }, { "path" }),
		run = function(args)
			local buffer = greed.load(args.path)
			local out = {}
			for n, block in blocks.runnable(buffer) do
				table.insert(out, describe(buffer, block, n))
			end
			return greed.json.array(out)
		end,
	})

	agent.tool({
		name = "blocks_run",
		description = "Run a code block in a Markdown file the user has let blocks run in, by its id or its index "
			.. "from blocks_list, and return its result, which is also saved under the block",
		input = object({
			path = { type = "string" },
			id = { type = "string" },
			index = { type = "number" },
		}, { "path" }),
		run = function(args)
			local buffer = greed.load(args.path)
			if not blocks.trusted(buffer) then
				error(
					`the user hasn't let blocks in {args.path} run; they can with :blocks-trust`,
					0
				)
			end
			local list = blocks.runnable(buffer)
			local chosen, n = nil, 0
			for i, block in list do
				if (args.id and block.opts.id == args.id) or (args.index and i == args.index) then
					chosen, n = block, i
					break
				end
			end
			if chosen == nil then
				error("there's no such block; blocks_list shows them", 0)
			end
			blocks.run(buffer, chosen)
			local after = blocks.runnable(buffer)[n]
			return describe(buffer, after, n)
		end,
	})
end
