# Keys

Every key runs a command, and every binding can be changed from your
config. This page covers finding out what keys do, binding your own, and
how keymaps are organised.

## Finding out what a key does

| Keys | |
|---|---|
| `space h k` | Press a key and see the command it runs, its other keys and where it's defined |
| `space h c` | Pick a command and see what it does and which keys run it |
| `space ?` | Every command, with its keys; enter runs one |
| `space`, `g`, `]`, ... | After the first key of a sequence, a hint lists what can follow |

Commands have names like `goto-end` or `select-line`, and `:` runs any of
them by name.

## Binding keys

Bindings go in `~/.config/kern/init.luau`:

```luau
local kern = require("@kern")

kern.keymap.bind("normal", {
	["space w"] = "save",
	["space q"] = "quit",
	Q = "quit-all",
})

-- In insert mode too
kern.keymap.bind("insert", { ["ctrl-s"] = "save" })
```

A binding maps a key, or a sequence of keys separated by spaces, to a
command name. A newer binding replaces an older one for the same keys, so
your config wins over the default plugins.

Key names:

- Letters, digits and symbols as themselves: `x`, `X`, `5`, `%`, `/`.
  Capitals are shifted letters.
- Named keys: `space`, `enter`, `esc`, `tab`, `backspace`, `delete`,
  `insert`, `up`, `down`, `left`, `right`, `home`, `end`, `pageup`,
  `pagedown`.
- Modifiers in front, joined with `-`: `ctrl-s`, `alt-x`, `ctrl-shift-left`,
  `ctrl--` for ctrl and minus.

## Taking keys away

```luau
-- Hide some keys; whatever they did before comes back if the plugin that
-- unbound them is removed
kern.keymap.unbind("normal", { "U", "g w" })

-- Start a mode over: everything bound in it so far is hidden, and bindings
-- made afterwards apply as usual
kern.keymap.clear("normal")
```

## Modes and layers

Bindings live in layers. Most belong to a mode:

| Mode | Used by |
|---|---|
| `normal`, `insert` | The Helix style |
| `edit` | Edit mode |
| `vim`, `vim-insert`, `vim-visual` | The Vim style |

A layer can also be limited to one kind of buffer, so a key does
something different in the file tree or a picker than in a file:

```luau
-- o opens the file under the cursor, but only in the file tree
kern.keymap.bind({ mode = "normal", kind = "tree" }, { o = "tree-open" })

-- An empty layer applies in every mode
kern.keymap.bind({}, { ["ctrl-q"] = "quit" })
```

When a key is pressed, Kern looks in the mode and buffer kind's layer
first, then the mode's, then the buffer kind's, then the layer for every
mode.

`kern.keymap.inherit` lets a mode use another mode's keys, all of them or
only those starting with some prefixes. The Vim style uses it to share
`space`, `:` and search with Helix's normal mode; see
[Editing styles](editing-styles.md#making-your-own).

## Binding your own commands

Any Luau function can become a command, and then a key:

```luau
local kern = require("@kern")

kern.command({
	name = "upcase-line",
	doc = "Upper-case the line the cursor is on",
	run = function(ctx)
		local buffer = ctx.buffer
		local selection = ctx.view:selection()
		local line = buffer:line_of(selection.ranges[selection.primary].head)
		local from, to = buffer:line_start(line), buffer:line_end(line)
		buffer:edit(function(e)
			e:replace(from, to, string.upper(buffer:slice(from, to)))
		end)
	end,
})

kern.keymap.bind("normal", { ["g u"] = "upcase-line" })
```

[Writing plugins](plugins.md) covers commands, and the rest of the API,
in more detail.
