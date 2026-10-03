# Editing styles

Kern comes with three ways to edit, and you can switch between them while
it runs:

| Style | How it works | Like |
|---|---|---|
| `helix` (the default) | Select text, then say what to do with it | Helix, Kakoune |
| `vim` | Say what to do, then where: `d w`, `c i w`, `y y` | Vim |
| `edit` | No modes: typing inserts, shift and the arrows select | VS Code, most editors |

```text
:style vim        switch now
:style            show the style in use and the others
```

To start in a style every time, set it in `~/.config/kern/init.luau`:

```luau
require("@kern").option.set("editing-style", "vim")
```

Helix and Vim share the keys that aren't about editing: `space f` finds
files, `space /` searches the project, `:` runs commands, `g d` goes to a
definition, `] d` to the next problem. Edit mode, where typing a letter
inserts it, reaches the same commands through `ctrl-P` and `alt-x`.
Prompts and pickers work the same in all three.

## Helix

Normal mode is for moving and selecting, and every movement selects: `w`
selects to the next word, `x` the line, `%` the whole file. Then a command
acts on what's selected: `d` deletes it, `c` changes it, `y` copies it.

```text
x d        select the line, delete it
x x d      select two lines, delete them
% s foo    select every "foo" in the file; typing now edits them all
```

Why it's the default: you see what a command will act on before you run
it, and many selections are part of the model rather than a separate
feature. `s`, `S`, `C` and `alt-s` make selections, and every edit then
happens at each one, which covers most of what macros and
search-and-replace are used for. [Using Kern](using.md#editing) lists
the keys.

## Vim

Vim's normal mode works the other way round: an operator first, then a
motion saying how far. `d w` deletes to the next word, `c i w` changes the
word under the cursor, `3 j` moves three lines down. The cursor sits on a
character, and `v` starts a visual mode for selecting by hand.

| Keys | |
|---|---|
| `h j k l` `w b e` `0 ^ $` `g g` `G` `%` | Move, with counts: `3 w`; `%` to the matching bracket |
| `f t F T` + a character | To the next or previous character on the line |
| `d c y` + a motion or text object | Delete, change or copy; doubled (`d d`) for whole lines |
| `i w` `a w` `i W` `i (` `a "` `i p` `i t` ... | Text objects: words, brackets (`b` `B` too), quotes, paragraphs, tags |
| `>` `<` `g c` + a motion | Indent, dedent, comment; `> >` `< <` `g c c` for the line |
| `x X D C s S` | The usual shortcuts for deleting and changing |
| `r` `~` `J` | Replace a character, switch case, join lines |
| `p P` | Paste after or before |
| `i a I A o O` | Insert |
| `u` `ctrl-r` | Undo, redo |
| `v` `V` | Visual mode, by character or by line; `i`/`a` there select a text object |
| `*` `#` | Search for the word under the cursor, forward or back |
| `ctrl-f` `ctrl-b` `ctrl-d` `ctrl-u` `z z` | Page and half page down and up, center the view |
| `ctrl-o` `ctrl-i` | Back and forward through where you jumped from |
| `.` | Repeat the last change, with what it typed |
| `q` + a letter, `q` | Record a macro into that register, stop |
| `@` + a letter, `@ @` | Play a macro, play the last one again |
| `"` + a letter | Use that register for the next yank, delete or paste; an uppercase letter appends |

Why it's here: Vim's keys are in a lot of people's hands, and switching
editors shouldn't mean relearning them. It also shows how far a plugin can
go: the Vim style is plain Luau against the same API any plugin uses, with
its own modes (`vim`, `vim-insert`, `vim-visual`, `vim-visual-line`)
beside Helix's.

The unnamed register is the system clipboard, so `p` pastes what you
copied in another program too; `"+` is the same and `"_` keeps nothing.
Panels like the file tree and help keep their own keys.

It isn't all of Vim yet. Marks, ex ranges, visual block mode and the
numbered registers are missing.

## Edit

No modes. Typing inserts text, replacing a selection if there is one, and
the keys are the ones most editors use.

| Keys | |
|---|---|
| arrows, `home` `end`, `ctrl-left` `ctrl-right` | Move |
| `pageup` `pagedown` | A screen up or down |
| `shift` + any of those | Select |
| `ctrl-a` | Select all |
| `ctrl-c` `ctrl-x` `ctrl-v` | Copy, cut, paste |
| `ctrl-z` `ctrl-y` | Undo, redo |
| `ctrl-p` `ctrl-b` | Find a file, switch to an open file |
| `ctrl-P` or `alt-x` | Run a command |
| `ctrl-s` | Save |

Why it's here: for people who don't want modes, or don't want them yet,
and for the odd edit where modes get in the way. Everything else in Kern
still works, through `ctrl-P` and the command line (`alt-x`).

## Making your own

A style is a mode with keys bound in it, registered with the `core`
plugin. Its keys can borrow from Helix's normal mode, so `space`, `:` and
the rest keep working:

```luau
local kern = require("@kern")

kern.keymap.bind("mine", { j = "move-down", k = "move-up", i = "insert-mode" })
kern.keymap.inherit("mine", "normal", { "space", ":" })
-- The file tree, help and other panels keep their keys.
kern.keymap.inherit_kinds("mine", "normal")

require("@core").style.define({
	name = "mine",
	doc = "My own keys",
	mode = "mine",
	plugin = "mine",
})
```

`esc` in insert mode comes back to the style's mode, and `:style mine`
switches to it. `.` works in any style: it types the keys of the last
change again; `require("@core").again.ignore({ "my-undo" })` leaves out
commands that shouldn't count as one. The Vim plugin in `runtime/plugins/vim` is a full example.
