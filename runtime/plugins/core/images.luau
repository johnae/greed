-- Pasting an image: the buffer you're in takes it as its kind says, like
-- an agent's box attaching it to your next message. The image comes from
-- the system clipboard of the client you're at, read on its own machine, so
-- with `greed ssh` it's your laptop's. A window's paste keys run
-- `paste-image` when the clipboard holds an image and no text; in a
-- terminal, whose paste only carries text, a key for it does.

local greed = require("@greed")
local registry = require("./registry")

local M = {}

--- What takes a pasted image, as PNG bytes, in a buffer of some kind.
export type Taker = (png: string, ctx: greed.Context) -> ()

local takers: { [string]: Taker } = {}

--- Makes buffers of `kind` take a pasted image with `take`. It goes when the
--- plugin that called this does.
function M.taker(kind: string, take: Taker)
	greed.plugin.tie(registry.set(takers, kind, take))
end

--- Whether buffers of `kind` take a pasted image.
function M.takes(kind: string): boolean
	return takers[kind] ~= nil
end

greed.command({
	name = "paste-image",
	doc = "Paste the image on your clipboard into what you're in, like an agent's box",
	run = function(ctx)
		local take = takers[ctx.buffer:kind()]
		if take == nil then
			greed.echo("nothing here takes an image")
			return
		end
		local png = greed.clipboard.image()
		if png == nil then
			greed.echo("there's no image on the clipboard")
			return
		end
		take(png, ctx)
	end,
})

return M
