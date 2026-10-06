-- Tools for agents: list a Markdown file's runnable blocks and run one,
-- the way you would, in files you've let run (a runbook, a notes page of
-- queries), and only blocks as you last ran them or trusted the file.
-- Results land under the blocks in the buffer, in front of you.

local greed = require("@greed")
local agent = require("@agent")
agent.group("blocks", "Runnable code blocks in Markdown files: listing and running them")

-- What these need from the plugin, which loads them after it's set up.
export type Blocks = {
	runnable: (buffer: greed.Buffer) -> { any },
	run_for_agent: (buffer: greed.Buffer, block: any) -> boolean,
	refused: (buffer: greed.Buffer, block: any) -> string?,
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
		group = "blocks",
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
		kind = "execute",
		group = "blocks",
		description = "Run a code block in a Markdown file the user has let blocks run in, by its id or its index "
			.. "from blocks_list, and return its result, which is also saved under the block",
		input = object({
			path = { type = "string" },
			id = { type = "string" },
			index = { type = "number" },
		}, { "path" }),
		run = function(args)
			local buffer = greed.load(args.path)
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
			local refused = blocks.refused(buffer, chosen)
			if refused then
				error(`{args.path}: {refused}`, 0)
			end
			blocks.run_for_agent(buffer, chosen)
			local after = blocks.runnable(buffer)[n]
			return describe(buffer, after, n)
		end,
	})
end
