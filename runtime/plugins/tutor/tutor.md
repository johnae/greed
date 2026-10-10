# Greed tutor

This page is yours to edit: nothing here is saved, and `:tutor` gives you
a fresh one. Each lesson shows the keys for your editing style, then has a
few lines to practise on. When they read the way the lesson asks, the
lesson says done.

## Which style do you edit in? <!-- id=style -->

- ( ) vim: say what to do, then where (`d w` deletes a word)
- ( ) helix: select first, then act (`w d` selects a word and deletes it)
- ( ) vscode: no modes; type to insert, shift and the arrows select

Picking one switches to it, here and everywhere; `:style` does the same
later. The lessons below change with it.

<!-- if style=vim,helix -->
You start in normal mode, where keys move and act rather than type. `i`
goes to insert mode to type, and `esc` comes back.
<!-- end -->
<!-- if style=vscode -->
There are no modes: typing types, and keys with `ctrl`, `alt` or `shift`
act.
<!-- end -->

## 1. Moving around

<!-- if style=vim,helix -->
`h` `j` `k` `l` move left, down, up and right; the arrow keys work too.
`w` goes to the next word, `b` back a word, `e` to the end of one.
<!-- end -->
<!-- if style=vim -->
`0` goes to the start of the line, `$` to its end, `g g` to the top of the
file and `G` to the bottom. A number first repeats a motion: `3 w`.
<!-- end -->
<!-- if style=helix -->
In Helix, moving by words also selects the word: watch the selection
follow. `g h` goes to the start of the line, `g l` to its end, `g g` to the
top of the file and `g e` to the bottom.
<!-- end -->
<!-- if style=vscode -->
The arrow keys move, `ctrl-left` and `ctrl-right` a word at a time,
`home` and `end` to the line's start and end, and `ctrl-home` and
`ctrl-end` to the top and bottom of the file.
<!-- end -->

Try moving over these lines; nothing to change yet.

```text
The quick brown fox jumps over the lazy dog.
Pack my box with five dozen liquor jugs.
```

## 2. Deleting

<!-- if style=vim -->
`x` deletes the character under the cursor. `d` and a motion deletes as
far as it goes: `d w` a word, `d $` to the end of the line.
<!-- end -->
<!-- if style=helix -->
Select, then delete: `w` selects a word, `d` deletes the selection. `x`
selects the whole line.
<!-- end -->
<!-- if style=vscode -->
`backspace` and `delete` remove a character, `ctrl-backspace` and
`ctrl-delete` a word.
<!-- end -->

Delete the second "cat":

```practice
The cat cat sat on the mat.
```

```want vim="w d w" helix="w w d" vscode="ctrl-right ctrl-delete"
The cat sat on the mat.
```

## 3. Changing

<!-- if style=vim -->
`c` and a motion deletes and goes to insert mode: `c w` changes a word.
Type the new one and press `esc`.
<!-- end -->
<!-- if style=helix -->
`c` changes the selection: it's deleted and you're typing in its place.
Type the new text and press `esc`.
<!-- end -->
<!-- if style=vscode -->
Typing replaces what's selected, and `ctrl-shift-left` and
`ctrl-shift-right` select a word at a time, so selecting a word and typing
changes it.
<!-- end -->

Change "hat" to "mat":

```practice
The cat sat on the hat.
```

```want vim="5 w c w m a t esc" helix="g l b c m a t esc" vscode="end left ctrl-shift-left m a t"
The cat sat on the mat.
```

## 4. Lines

<!-- if style=vim -->
`d d` deletes the line, `o` opens a new line below and goes to insert
mode, `O` above.
<!-- end -->
<!-- if style=helix -->
`x` selects the line, then `d` deletes it. `o` opens a new line below and
goes to insert mode, `O` above.
<!-- end -->
<!-- if style=vscode -->
`ctrl-shift-k` deletes the line, `ctrl-enter` opens a new one below and
`ctrl-shift-enter` above. `alt-up` and `alt-down` move the line.
<!-- end -->

Delete the line that doesn't belong:

```practice
one
two
banana
three
```

```want vim="j j d d" helix="j j x d" vscode="down down ctrl-K"
one
two
three
```

## 5. Undo

<!-- if style=vim -->
`u` undoes, `ctrl-r` redoes. Undo your changes above, then redo them.
<!-- end -->
<!-- if style=helix -->
`u` undoes, `U` redoes. Undo your changes above, then redo them.
<!-- end -->
<!-- if style=vscode -->
`ctrl-z` undoes, `ctrl-y` redoes. Undo your changes above, then redo them.
<!-- end -->

## 6. Many at once

<!-- if style=vim -->
`:s/old/new/g` replaces on the line, `:%s/old/new/g` everywhere. `.`
repeats the last change, wherever the cursor is.
<!-- end -->
<!-- if style=helix -->
Selections can be many. `x` selects a line (press it again for more
lines), `s` selects every match of a pattern inside the selection, and
whatever you do then happens to each one.
<!-- end -->
<!-- if style=vscode -->
`ctrl-d` selects the word under the cursor, and again the next place it's
used, each with a cursor of its own; typing changes them all. `esc` goes
back to one cursor.
<!-- end -->

Rename every "old" to "new":

```practice
old = old + 1
print(old)
```

```want vim=": % s / o l d / n e w / g enter" helix="x x s o l d enter c n e w esc" vscode="ctrl-d ctrl-d ctrl-d n e w"
new = new + 1
print(new)
```

## 7. Getting around Greed

The rest is the same in every style. Everything that isn't editing opens
from the leader:
<!-- if style=vim,helix -->
`space`.
<!-- end -->
<!-- if style=vscode -->
`ctrl-space`. The keys below start with `space`; press `ctrl-space`
instead.
<!-- end -->

- `space f` finds a file in the project, and `space b` an open one.
- `space /` searches the whole project as you type.
- `space e` opens the file tree.
- `space ?` lists every command with its keys, and `space h h` describes
  anything: commands, options, keys and plugins. `space h k` tells what a
  key does.
<!-- if style=vim,helix -->
- `:` runs a command by name, like `:w` to save or `:theme`.
<!-- end -->
<!-- if style=vscode -->
- `ctrl-shift-p` picks a command by name, `ctrl-s` saves.
<!-- end -->

Panes and terminals use `alt`, as in zellij: `alt-n` opens a terminal in a
new pane, `alt-f` a floating one, and `alt-p` is the pane mode, with `h j k
l` to move between panes and `x` to close one. `:shell` opens Greed's own
shell, whose commands you keep and run again.

`greed ssh HOST` edits on another machine, with your config, and
`:detach` leaves a session running to come back to with `greed attach`.

That's the tour. `:tutor` brings this page back whenever you like.
