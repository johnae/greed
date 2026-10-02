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

## Panes, tabs and terminals

These follow [zellij](https://zellij.dev): `alt` keys that work
everywhere, in every editing style and while typing into a terminal, and
two modes where single keys act until `esc`.

| Keys | |
|---|---|
| `alt-h` `alt-j` `alt-k` `alt-l` (or `alt` and an arrow) | Move to the pane on that side; left and right go on to the next tab at the edge |
| `alt-n` | A terminal in a new pane, on the pane's longer side |
| `alt-f` | Show the floating terminal, or hide it (it keeps running) |
| `alt-=` `alt--` | Give the pane more room, or less |
| `alt-[` `alt-]`, `alt-1` to `alt-9` | The tab before or after, or tab N |
| `alt-space` | Arrange the tab with the next layout |
| `alt-m` | Swap the pane with the main one |
| `alt-p` | Pane mode: `h j k l` move, `n` / `r` / `d` a terminal (anywhere, right, below), `v` / `s` this file again (right, below), `x` close, `f` zoom in on the pane, `w` float, `H J K L` move an edge, `= -` resize, `space` next layout, `y` pick a layout, `m` swap with main, `o` rotate, `[ ]` main smaller or bigger, `esc` done |
| `alt-t` | Tab mode: `h l` switch, `n` new, `t` new with a terminal, `x` close, `r` rename, `esc` done |

In normal mode (Helix and Vim), `ctrl-w` and `space w` start the window
keys from Vim and Helix: `v` and `s` split, `h j k l` move, `w` the next
pane, `q` close, `o` close the others, `t` a terminal, `z` zoom. In the Vim
style, `g t` and `g T` change tabs.

All of these are ordinary bindings to commands (`pane-left`,
`pane-terminal`, `tab-next`, ...), so they change like any other:

```luau
local kern = require("@kern")

-- alt-n is something else in my shell
kern.keymap.unbind({}, { "alt-n" })
kern.keymap.unbind("terminal", { "alt-n" })

-- Split with space | and space -
kern.keymap.bind("normal", {
	["space |"] = "pane-split-right",
	["space -"] = "pane-split-down",
})

-- The pane mode on ctrl-p, in terminals too, as in zellij
kern.keymap.bind({}, { ["ctrl-p"] = "pane-mode" })
kern.keymap.bind("terminal", { ["ctrl-p"] = "pane-mode" })
```

The terminal's mode takes every key, so the `alt` keys are bound in the
`terminal` layer too; unbind a key there as well to let it through to the
program. `require("@panes").keys` holds the defaults, by layer.

In a terminal, keys go to the program except those bound in the
`terminal` layer: `ctrl-\` to stop typing into it, `ctrl-space` to stop
and press `space` (so `ctrl-space f` finds a file), and the `alt` keys
above. Bind more there the same way:

```luau
-- ctrl-o finds a file without leaving the terminal first
kern.keymap.bind("terminal", { ["ctrl-o"] = "pick-file" })
```

## Modes and layers

Bindings live in layers. Most belong to a mode:

| Mode | Used by |
|---|---|
| `normal`, `insert` | The Helix style |
| `edit` | Edit mode |
| `vim`, `vim-insert`, `vim-visual` | The Vim style |
| `terminal` | Typing into a terminal (takes every key) |
| `pane`, `tab` | The pane and tab modes |

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
