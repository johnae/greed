# Keys

Every key runs a command, and every binding can be changed from your
config. This page covers finding out what keys do, binding your own, and
how keymaps are organised.

## Finding out what a key does

| Keys | |
|---|---|
| `space h k` | Press a key and see the command it runs, its other keys and where it's defined |
| `space h c` | Pick a command and see what it does and which keys run it |
| `space h h` | Describe anything: commands, options, events, functions of the plugin API, plugins and modes, from one picker |
| `space h o` `space h e` `space h a` `space h p` `space h m` | Describe an option (its value, default and who set it), an event (what handlers get, who listens), an API function, a plugin, or a mode and its keys |
| `space ?` | Every command, with its keys; enter runs one |
| `space .` (`alt-.` in edit mode) | What you can do with what's under the cursor: a file path, a link, a symbol, a problem, a change, a button, the selection; `alt-.` in a picker does the same for the current item |
| `space`, `g`, `]`, ... | After the first key of a sequence, a hint lists what can follow |

Commands have names like `goto-end` or `select-line`, and `:` runs any of
them by name. Keys starting with `space` are the leader's: in edit mode
they start with `ctrl-space` instead.

## Binding keys

Bindings go in `~/.config/greed/init.luau`. Most commands you reach for
by name, like finding a file or searching the project, live in the
leader: a layer every editing style opens its own way, `space` in Helix
and Vim, `ctrl-space` in edit mode. Bind there and the key works in
whichever style you use:

```luau
local greed = require("@greed")

-- space w in Helix and Vim, ctrl-space w in edit mode
greed.keymap.bind({ layer = "leader" }, {
	w = "save",
	q = "quit",
	["g p"] = "pick-changed-file",
})
```

After the leader's keys, a hint lists what can follow, the same in every
style.

Other keys belong to a mode:

```luau
greed.keymap.bind("helix", { Q = "quit-all" })

-- In insert mode too
greed.keymap.bind("helix-insert", { ["ctrl-s"] = "save" })
```

The mode names depend on your editing style: `helix`, `helix-insert` and
`helix-select` are the Helix style's, the Vim style's are `vim`,
`vim-insert` and `vim-visual`, and edit mode has one, `edit`. The status
line shows them as you'd expect (NORMAL, INSERT, VISUAL). Bind for the
style you use, or for each of them (all the modes are listed under
[Modes and layers](#modes-and-layers)):

```luau
-- ctrl-s saves in every style
for _, mode in { "helix", "helix-insert", "vim", "vim-insert", "edit" } do
	greed.keymap.bind(mode, { ["ctrl-s"] = "save" })
end
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
greed.keymap.unbind("helix", { "U", "g w" })

-- Start a mode over: everything bound in it so far is hidden, and bindings
-- made afterwards apply as usual
greed.keymap.clear("helix")
```

## Panes, tabs and terminals

These follow [zellij](https://zellij.dev): `alt` keys that work
everywhere, in every editing style and while typing into a terminal, and
two modes where single keys act until `esc`.

| Keys | |
|---|---|
| `alt-h` `alt-j` `alt-k` `alt-l` (or `alt` and an arrow) | Move to the pane or panel (the file tree, an agent) on that side; left and right go on to the next tab at the edge |
| `alt-n` | A terminal in a new pane, on the pane's longer side; while floating views are shown, a floating terminal |
| `alt-f` | Hide the tab's floating views or show them again, where they were (terminals keep running); with none, open a floating terminal |
| `alt-F` | This file in a new floating view (`:float-file PATH` for another) |
| `alt-w` | Lay the tab's floating views out with the next float layout: `free`, `one`, `tiled`, `cascade` |
| `alt-{` `alt-}` | Bring the floating view before or after to the front (in `one`, the one that shows) |
| `alt-W` | Pick a floating view from the dock: its number, or the arrows and `enter` |
| `alt-=` `alt--` | Give the pane more room, or less |
| `alt-[` `alt-]`, `alt-1` to `alt-9` | The tab before or after, or tab N |
| `alt-space` | Arrange the tab with the next layout |
| `alt-m` | Swap the pane with the main one |
| `alt-p` | Pane mode: `h j k l` move, `n` / `r` / `d` a terminal (anywhere, right, below), `v` / `s` this file again (right, below), `x` close, `f` zoom in on the pane, `g` label the panes and go to the one you type, `w` (or `z`) hide or show the floats, `W` another floating terminal, `E` this file floating, `e` (or `F`) float the pane or put a float back, `T` tile the floats, `C` cascade them, `O` one at a time, `Y` pick a float layout, `{ }` the float before or after, `H J K L` move an edge, `= -` resize, `R` the resize mode, `p` place a new pane (a frame shows where; `h j k l` move it, `enter` opens it, `t` a terminal, `esc` cancels), `space` next layout, `y` pick a layout, `m` swap with main, `o` rotate, `[ ]` main smaller or bigger, `esc` done |
| `alt-t` | Tab mode: `h l` switch, `n` new, `t` new with a terminal, `x` close, `r` rename, `esc` done |
| `alt-r` | Resize mode: `h j k l` grow the pane, panel or floating view toward that side, `H J K L` shrink it from that side, arrows move a floating view, `= -` every way, `esc` done |

In normal mode (Helix and Vim), `ctrl-w` and the leader's `w` (`space w`)
start the window keys from Vim and Helix: `v` and `s` split, `h j k l`
move, `w` the next pane, `q` close, `o` close the others, `t` a terminal,
`z` zoom, `g` label the panes. In the Vim style, `g t` and `g T` change
tabs.

All of these are ordinary bindings to commands (`pane-left`,
`pane-terminal`, `tab-next`, ...), so they change like any other:

```luau
local greed = require("@greed")

-- alt-n is something else in my shell
greed.keymap.unbind({}, { "alt-n" })
greed.keymap.unbind("terminal", { "alt-n" })

-- Split with space | and space -
greed.keymap.bind({ layer = "leader" }, {
	["|"] = "pane-split-right",
	["-"] = "pane-split-down",
})

-- The pane mode on ctrl-p, in terminals too, as in zellij
greed.keymap.bind({}, { ["ctrl-p"] = "pane-mode" })
greed.keymap.bind("terminal", { ["ctrl-p"] = "pane-mode" })
```

The terminal's mode takes every key, so the `alt` keys are bound in the
`terminal` layer too; unbind a key there as well to let it through to the
program. `require("@panes").keys` holds the defaults, by layer.

In a terminal, keys go to the program except those bound in the
`terminal` layer: `ctrl-\` to stop typing into it, `ctrl-space` to stop
and open the leader (so `ctrl-space f` finds a file), and the `alt` keys
above. Bind more there the same way:

```luau
-- ctrl-o finds a file without leaving the terminal first
greed.keymap.bind("terminal", { ["ctrl-o"] = "pick-file" })
```

## Modes and layers

Bindings live in layers. Most belong to a mode:

| Mode | Used by |
|---|---|
| `helix`, `helix-insert`, `helix-select` | The Helix style |
| `edit` | Edit mode |
| `vim`, `vim-insert`, `vim-visual` | The Vim style |
| `terminal` | Typing into a terminal (takes every key) |
| `pane`, `tab`, `resize` | The pane, tab and resize modes |
| `view` | The sticky view mode (`Z` in the Helix style) |

The `leader` layer isn't a mode: each style's mode opens it with its own
keys (`space`, or `ctrl-space` in edit mode), and what's bound in it works
after them. A style can open any layer this way with
`greed.keymap.enter(mode, keys, layer)`.

A layer can also be limited to one kind of buffer, so a key does
something different in the file tree or a picker than in a file. Bound
for the kind alone, a panel's keys work in every style and every mode,
ahead of the mode's own:

```luau
-- o opens the file under the cursor, but only in the file tree
greed.keymap.bind({ kind = "tree" }, { o = "tree-open" })

-- Only in Helix's mode, in the file tree
greed.keymap.bind({ mode = "helix", kind = "tree" }, { O = "tree-open" })

-- An empty layer applies in every mode
greed.keymap.bind({}, { ["ctrl-q"] = "quit" })
```

When a key is pressed, Greed looks first in the layers for the buffer's
kind: the mode's, the leader's, those of the modes it inherits, then the
kind's for every mode. Then come the leader if the keys open it, the
mode's own layer, the layers of the modes it inherits, and the layer for
every mode. The first layer where the keys run a command, or start a
longer sequence, decides.

`greed.keymap.inherit` lets a mode use another mode's keys, all of them or
only those starting with some prefixes. The Vim style uses it to share
`:` and search with Helix's mode; see
[Editing styles](editing-styles.md#making-your-own).

## Binding your own commands

Any Luau function can become a command, and then a key:

```luau
local greed = require("@greed")

greed.command({
	name = "upcase-line",
	doc = "Upper-case the line the cursor is on",
	run = function(ctx)
		local buffer = ctx.buffer
		local line = buffer:line_of(ctx.view:cursor())
		local from, to = buffer:line_start(line), buffer:line_end(line)
		buffer:edit(function(e)
			e:replace(from, to, string.upper(buffer:slice(from, to)))
		end)
	end,
})

greed.keymap.bind("helix", { ["g u"] = "upcase-line" })
```

[Writing plugins](plugins.md) covers commands, and the rest of the API,
in more detail.
