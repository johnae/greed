-- Going back and forth through every state the text has been in, across
-- undo branches, in the order they were made: Helix's alt-u and alt-U,
-- Vim's g- and g+. Plain undo and redo stay on one branch; these reach the
-- states an undo followed by an edit left behind.

local greed = require("@greed")

-- earlier and later: `count` states back or on, by when they were made.
for _, later in { false, true } do
	greed.command({
		name = if later then "later" else "earlier",
		doc = if later
			then "Go on to the state of the text made after this one, on any undo branch"
			else "Go back to the state of the text made before this one, on any undo branch",
		run = function(ctx)
			local tree = ctx.buffer:undo_tree()
			local step = (ctx.count or 1) * (if later then 1 else -1)
			local target = math.clamp(tree.current + step, 0, #tree.nodes - 1)
			if not ctx.view:undo_to(target) then
				greed.echo(
					if later then "already at the latest change" else "already at the oldest change"
				)
			end
		end,
	})
end

return {}
