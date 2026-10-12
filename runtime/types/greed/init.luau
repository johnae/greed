--- The Greed API, as seen by plugins through `require("@greed")`.
---
--- This file only describes types, for `luau-analyze` and `luau-lsp`; the
--- editor provides the real module. Positions are 0-based byte offsets and
--- lines are 0-based, like LSP.
---
--- Conventions, which new API follows and older API moves to as it's
--- touched:
---
--- - What fails for reasons outside the plugin (a file, a program, the
---   network, a pattern someone typed) returns nil, or false, and a
---   message. Misuse raises: a wrong argument, a closed handle, a
---   capability the plugin doesn't have, a write that's refused.
--- - What lives on and is acted on (buffers, views, terminals, programs,
---   connections) is a handle with methods; what a module keeps for you
---   (images, scenes, tabs, projects) is a number its functions take.
--- - A range is `from, to` with `to` exclusive. Spans of whole lines, given
---   as a first and last line, include both and say so. Indexes into a
---   Luau list, and what mirrors `string.find`, are 1-based.

--- A range of text. `anchor` is where it started and `head` is where the
--- cursor is; a cursor is a range where the two are equal.
export type Range = {
	anchor: number,
	head: number,
}

--- One or more ranges, sorted and never overlapping. `primary` is the
--- 1-based index of the main range.
export type Selection = {
	ranges: { Range },
	primary: number,
}

--- Collects the edits made inside `Buffer:edit`. They are applied together,
--- as one undoable change, when the callback returns.
export type Edits = {
	insert: (self: Edits, pos: number, text: string) -> (),
	delete: (self: Edits, from: number, to: number) -> (),
	replace: (self: Edits, from: number, to: number, text: string) -> (),
	--- Sets the selection after the edit (of every view showing the buffer,
	--- when the buffer didn't come from a view). Without this, the current
	--- selection is moved along with the text: a cursor ends up after text
	--- inserted where it is, and after the new text of a replace or delete
	--- that covers it; a range doesn't grow to take in text inserted at its
	--- edges.
	select: (self: Edits, selection: Selection) -> (),
}

--- Open text, backed by a file or not. Two handles to the same buffer are
--- equal (`==`).
export type Buffer = {
	--- Its id, even after it was closed.
	id: (self: Buffer) -> number,
	--- Whether it is still open. Other methods fail once it was closed.
	valid: (self: Buffer) -> boolean,
	--- Length in bytes.
	len: (self: Buffer) -> number,
	text: (self: Buffer) -> string,
	slice: (self: Buffer, from: number, to: number) -> string,
	line_count: (self: Buffer) -> number,
	--- The line `pos` is on.
	line_of: (self: Buffer, pos: number) -> number,
	line_start: (self: Buffer, line: number) -> number,
	--- The end of `line`, before its line break.
	line_end: (self: Buffer, line: number) -> number,
	--- The text of `line`, without its line break.
	line_text: (self: Buffer, line: number) -> string,
	--- The screen column `pos` is drawn at in its line: wide characters take two columns and tabs reach the next tab stop, every `tab_width` columns (the buffer's own if not given).
	display_column: (self: Buffer, pos: number, tab_width: number?) -> number,
	--- The position in `line` drawn at screen column `col`: the start of the character covering it, or the line's end if the line is shorter.
	at_display_column: (self: Buffer, line: number, col: number, tab_width: number?) -> number,
	--- The character at `pos`, or nil at the end of the buffer.
	char_at: (self: Buffer, pos: number) -> string?,
	next_char: (self: Buffer, pos: number) -> number,
	prev_char: (self: Buffer, pos: number) -> number,
	--- The start and end of the sentence around `pos`, without the spaces
	--- after it. Sentences end at blank lines.
	sentence: (self: Buffer, pos: number) -> (number, number),
	--- What the buffer is: "file", "terminal", ...
	kind: (self: Buffer) -> string,
	path: (self: Buffer) -> string?,
	--- The id of the project it was opened in.
	project: (self: Buffer) -> number?,
	--- True if only plugins can change the text: edits from keys and undo
	--- are refused.
	readonly: (self: Buffer) -> boolean,
	set_readonly: (self: Buffer, readonly: boolean) -> (),
	--- Where the read-only start of the text ends, when only its start is (`set_readonly_before`).
	readonly_before: (self: Buffer) -> number?,
	--- Makes the text before `pos` read-only, like `set_readonly`, and the rest writable, as a transcript above the box you write in; nil makes it all writable. The place moves with edits: what plugins insert there joins the read-only part, what you type there doesn't. Typing and pasting with a cursor in the read-only part go to the end (`core.writable`).
	set_readonly_before: (self: Buffer, pos: number?) -> (),
	--- The name it was given, for a buffer without a file, like a terminal's "nu ~/src".
	name: (self: Buffer) -> string?,
	--- Names it where it shows (the tab line, float titles, the status line); nil or "" leaves it unnamed.
	set_name: (self: Buffer, name: string?) -> (),
	--- What it's called where it shows: its file's name, the name it was given, "untitled" for a file not saved yet, or its kind.
	title: (self: Buffer) -> string,
	--- Whether the main view shows line numbers beside it (the default).
	line_numbers: (self: Buffer) -> boolean,
	set_line_numbers: (self: Buffer, on: boolean) -> (),
	--- How many columns apart its tab stops are, as it's drawn; 4 until set. Core sets it from the language or the "tab-width" option.
	tab_width: (self: Buffer) -> number,
	--- Sets how many columns apart its tab stops are, at least 1.
	set_tab_width: (self: Buffer, width: number) -> (),
	--- The views showing it.
	views: (self: Buffer) -> { View },
	--- Whether it stays open while nothing shows it, though it has no file.
	kept: (self: Buffer) -> boolean,
	--- Keeps it open while nothing shows it, like a terminal to come back
	--- to; with false it goes once nothing shows it (right away if nothing
	--- does now).
	set_kept: (self: Buffer, kept: boolean) -> (),
	--- Lays the text out at `rows` by `cols` in every view, whatever room a view has, like a terminal whose program has one screen size for one client: the screen is the buffer's last `rows` lines. A client whose view is another size crops it (a terminal), keeping row `cursor_row` (0-based, where the program's cursor is) in sight, or scales it (a window), and shows `note` (default "COLSxROWS") in the room left over. nil lays it out at each view's own size again.
	set_screen_size: (self: Buffer, size: { rows: number, cols: number, note: string?, cursor_row: number? }?) -> (),
	--- The size `set_screen_size` set, if any.
	screen_size: (self: Buffer) -> { rows: number, cols: number, note: string?, cursor_row: number? }?,
	--- Binds single keys for this buffer alone, e.g. `{ y = "answer-yes" }`, in every mode and ahead of every other binding, while it has focus. Replaces what was bound for it before; nil drops them.
	set_keys: (self: Buffer, keys: { [string]: string }?) -> (),
	--- Stops keeping undo history, for buffers whose edits nobody undoes,
	--- like a terminal's: what's kept goes, and later edits aren't kept.
	forget_history: (self: Buffer) -> (),
	--- Lets go of the undo history so far and keeps later edits: undo can't
	--- go back past now, as at a shell's prompt after a command runs.
	clear_history: (self: Buffer) -> (),
	--- The language the text is highlighted as, e.g. "rust".
	language: (self: Buffer) -> string?,
	--- Sets the language, or with nil goes back to the one the file's
	--- extension implies.
	set_language: (self: Buffer, language: string?) -> (),
	--- The root of the syntax tree, or nil if the language has no grammar
	--- or the buffer is too big to parse. Just after an edit, when parsing
	--- again would hold the editor up, it's the tree before with the edit
	--- applied (nodes moved with the text) until the new one is in.
	tree: (self: Buffer) -> Node?,
	--- The smallest named node covering `from`..`to` (default: just `from`).
	node_at: (self: Buffer, from: number, to: number?) -> Node?,
	--- Runs a tree-sitter query over the buffer, or only for matches
	--- overlapping `from`..`to`, e.g.
	--- `"(function_item name: (identifier) @name) @fn"`. One table per
	--- match, from capture name to node. Errors on a query the language's
	--- grammar can't compile; a buffer without a grammar has no matches, so
	--- any query gives an empty list there.
	query: (self: Buffer, source: string, range: { from: number?, to: number? }?) -> { { [string]: Node } },
	--- Edits the buffer: `f` records edits on `e`, and they are applied
	--- together, as one undoable change, when it returns. With `undo = false`
	--- the change isn't kept to undo, like output streaming in above where
	--- someone types: undo skips it and still takes back only what the
	--- steps before it did (redo branches are dropped).
	edit: (self: Buffer, f: (e: Edits) -> (), opts: { undo: boolean? }?) -> (),
	--- Writes the buffer to its file, or to `path`, which becomes its file.
	save: (self: Buffer, path: string?) -> (),
	--- True if the text changed since it was opened or last saved.
	modified: (self: Buffer) -> boolean,
	--- A number that grows with every edit, for caches that follow the text.
	version: (self: Buffer) -> number,
	--- Reads its file again, as an edit by "external" that undo can take back, and counts
	--- it as saved. Returns whether the text changed.
	reload: (self: Buffer) -> boolean,
	--- Closes the buffer, unsaved changes and all. Errors while a view shows it:
	--- show something else there first. Plugins hear "buffer.closed".
	close: (self: Buffer) -> (),
	--- Replaces the marks in namespace `ns` (pick one per plugin feature,
	--- e.g. "search"). Marks move with edits; `{}` clears them. With
	--- `within`, only those starting from `from` up to (not at) `to` (default:
	--- the end) are replaced, e.g. on the lines an edit changed.
	decorate: (self: Buffer, ns: string, marks: { Mark }, within: { from: number, to: number? }?) -> (),
	--- The marks in namespace `ns`, where they are now.
	decorations: (self: Buffer, ns: string) -> { Mark },
	--- The marks over `pos` in every namespace, each with its `ns`: those
	--- whose range holds it, and empty ones that start there.
	marks_at: (self: Buffer, pos: number) -> { Mark & { ns: string } },
	--- Follows `pos` through edits. Text inserted exactly there goes before it with `gravity = "right"` (the default) and after it with "left". Deleting text around it moves it to where the deletion was.
	track: (self: Buffer, pos: number, opts: { gravity: ("left" | "right")? }?) -> Anchor,
	--- Follows `from`..`to` through edits. `from` and `to` in `opts` are each end's gravity, as for `track`; by default text inserted at either end stays outside. It's deleted once all of its text is.
	track_range: (self: Buffer, from: number, to: number, opts: { from: ("left" | "right")?, to: ("left" | "right")? }?) -> Tracked,
	--- The first match of the regex `pattern` starting at or after `from`
	--- (default 0), or with `backward` the last one starting before it; `wrap`
	--- goes round the other end. Returns its start and end, nil when nothing
	--- matches, or nil, nil and the error for a bad pattern.
	find: (self: Buffer, pattern: string, from: number?, opts: { backward: boolean?, wrap: boolean? }?) -> (number?, number?, string?),
	--- Every match of the regex `pattern` between `from` and `to` (default:
	--- the whole buffer), or nil and the error for a bad pattern.
	find_all: (self: Buffer, pattern: string, from: number?, to: number?) -> ({ { from: number, to: number } }?, string?),
	--- The lines (0-based) a view's filter of `filter` keeps of the buffer, as `View.set_filter` reads it: words, `key=value` fields and `.a.b` sections, or with `regex` a regex; of lines `from` to `to` (inclusive) only, with them.
	kept_lines: (self: Buffer, filter: string, opts: { regex: boolean?, from: number?, to: number? }?) -> { number },
	--- Like `find_all`, but each match is the whole match's range followed by
	--- each group's, false for a group that took no part.
	find_groups: (self: Buffer, pattern: string, from: number?, to: number?) -> ({ { { from: number, to: number } | false } }?, string?),
	--- The transactions applied to it, newest first: by `author` ("user", "plugin",
	--- "agent" or "external"), `plugin`, `cause` (the command that made them, "undo",
	--- ...), `group`, made at or after `since` (seconds, like `time`), at most `limit`.
	history: (self: Buffer, filter: HistoryFilter?) -> { HistoryEntry },
	--- The text as it was before transaction `id`, or nil if the buffer has none by
	--- that id.
	text_before: (self: Buffer, id: number) -> string?,
	--- The undo tree: every state the text has been in, from node 0 (as it was loaded) on, each with the step before it as `parent`; undo goes to the parent and redo to the last child. `current` is the node the text is at.
	undo_tree: (self: Buffer) -> { nodes: { UndoNode }, current: number },
}

--- A node in a buffer's syntax tree, from `buffer:tree()`, `buffer:node_at()` or
--- `buffer:query()`. It describes the buffer as it was when found; after an edit,
--- find it again. `tostring(node)` shows its subtree, handy for writing queries.
export type Node = {
	--- The grammar's name for it, e.g. "function_item" or "(".
	kind: string,
	from: number,
	to: number,
	--- False for punctuation and keywords the grammar doesn't name.
	named: boolean,
	--- True for text the grammar couldn't parse, or a missing piece it assumed.
	error: boolean,
	--- Its field name in its parent, e.g. "name" or "body", if it has one.
	field: string?,
	parent: (self: Node) -> Node?,
	children: (self: Node) -> { Node },
	--- Its children without the unnamed ones (punctuation, keywords).
	named_children: (self: Node) -> { Node },
	--- The child in field `field`, e.g. `fn:child("body")`.
	child: (self: Node, field: string) -> Node?,
	--- The next named sibling.
	next: (self: Node) -> Node?,
	--- The previous named sibling.
	prev: (self: Node) -> Node?,
	--- Its text. Errors if the buffer changed since the node was found.
	text: (self: Node) -> string,
}

--- A position that moves with edits, from `buffer:track`. It goes when forgotten, when its buffer closes, or when the plugin that made it is unloaded.
export type Anchor = {
	--- Where it is now, or nil once it's gone.
	pos: (self: Anchor) -> number?,
	--- Stops following it.
	forget: (self: Anchor) -> (),
}

--- A range that moves with edits, from `buffer:track_range`. It goes as an `Anchor` does.
export type Tracked = {
	--- Where it is now, or nil once its text was deleted or it's gone.
	range: (self: Tracked) -> (number?, number?),
	--- Whether all of its text was deleted, or it's gone. Undo bringing the text back doesn't change that.
	deleted: (self: Tracked) -> boolean,
	--- Stops following it.
	forget: (self: Tracked) -> (),
}

--- A line a mark shows under its range: text, or pieces with styles of their own. On a float's border (`label`, `footer`), a piece's `action` is a command that a click on it runs, with any arguments after its name ("float-go 3").
export type MarkLine = string | { { text: string, style: string?, action: string? } }

--- Text drawn with a style name, e.g. `{ from = 6, to = 11, style = "match" }`.
--- Text typed at either edge stays outside it.
export type Mark = {
	from: number,
	to: number,
	style: string,
	--- Style every whole line the mark touches, not just its text.
	line: boolean?,
	--- Text to show that isn't in the buffer, like an inlay hint, before the
	--- character at `from`. The cursor skips over it.
	text: string?,
	--- Show `text` after the end of the line instead, cut off at the edge.
	eol: boolean?,
	--- A symbol for the sign column next to the line numbers, e.g. "E".
	sign: string?,
	--- A style for the line number of each line the mark touches, e.g. "ui.gutter.diagnostic.error".
	gutter: string?,
	--- Draw over selections and cursors rather than under them.
	above: boolean?,
	--- Draw `text` over the characters from `from` instead of inserting it,
	--- like a jump label. The text doesn't move.
	overlay: boolean?,
	--- Hide the text, showing `text` (if any) in its place, e.g. the
	--- brackets of a `[[link]]`, except where `reveal` says.
	conceal: boolean?,
	--- When concealed text shows: "line" (the default) when a cursor is on its line, "cursor" when a cursor is inside it past its start (a click leaves it hidden), "never", or "auto" as `greed.reveal` last said, so the marks needn't be drawn again when that changes.
	reveal: ("line" | "cursor" | "never" | "auto")?,
	--- Hide the lines after the first one, up to the last, unless a cursor is
	--- in them, like a section folded under its heading.
	fold: boolean?,
	--- Don't wrap the lines it touches: what's past the right edge is out of sight, and the view scrolls sideways to the cursor (`view:side_scroll()`), as for a wide table.
	nowrap: boolean?,
	--- Draw the text without syntax highlighting, like a tool's output in a
	--- Markdown buffer.
	plain: boolean?,
	--- Lines shown under the last line that aren't in the buffer, like
	--- backlinks. The cursor never goes on them. Each is a string, or pieces
	--- with styles of their own on top of the mark's, e.g.
	--- `{ { text = "x = " }, { text = "2", style = "diff.plus.change" } }`.
	lines: { MarkLine }?,
	--- An image (from `greed.image`) drawn over `cols` by `rows` cells right
	--- of and below `from`, whatever text is there. `col` and `row` say
	--- which of its cells is at `from`, for an image cut off at the top or
	--- left. Shown in terminals that can show images.
	image: { id: number, cols: number, rows: number, col: number?, row: number? }?,
	--- A scene (from `greed.scene`) drawn over `cols` by `rows` cells right of and below `from` by the clients that can draw one, as an image is; the text there is what the others show, so put the scene in characters there. `col` and `row` are as for an image.
	scene: { id: number, cols: number, rows: number, col: number?, row: number? }?,
	--- A command that clicking `text` runs, with the cursor put at `from`
	--- first, so the text works as a button, e.g. "proposal-accept".
	action: string?,
	--- How many times bigger the range's text (and `text`) is, 1 to 4, e.g. 2 for a heading: each character takes that many cells across, and its row that many rows down. The window draws it big, and so does kitty (its text sizing); other terminals show it at the normal size.
	scale: number?,
	--- Anything to keep with the mark, given back where it is read: plain data (tables, strings, numbers, booleans), never drawn.
	data: any?,
}

--- A buffer shown on screen, with its own selection. Two handles to the
--- same view are equal (`==`).
export type View = {
	--- Its id, even after it was closed.
	id: (self: View) -> number,
	--- Whether it is still open. Other methods fail once it was closed.
	valid: (self: View) -> boolean,
	selection: (self: View) -> Selection,
	set_selection: (self: View, selection: Selection) -> (),
	--- The head of the primary selection.
	cursor: (self: View) -> number,
	--- Makes the selection a single cursor at `pos`.
	set_cursor: (self: View, pos: number) -> (),
	--- The start and end of the text on screen when the view was last
	--- drawn, or of the whole buffer before that.
	visible: (self: View) -> (number, number),
	--- The rows and columns of text it had room for when last drawn; nil
	--- before it's drawn. "view.resized" says when they change.
	size: (self: View) -> (number?, number?),
	--- Where it was last drawn on the screen, in cells, its gutter included;
	--- nil before it's drawn.
	area: (self: View) -> { x: number, y: number, width: number, height: number }?,
	--- The lines folds hide, and those outside the lines it is narrowed to, 0-based and inclusive.
	hidden_lines: (self: View) -> { { from: number, to: number } },
	--- Shows only lines `from` to `to` (0-based, inclusive) of its buffer, as a float showing one part of it; no arguments shows all of it again. Showing another buffer does too.
	narrow: (self: View, from: number?, to: number?) -> (),
	--- The first and last line it's narrowed to, or nil when it shows all of its buffer.
	narrowed: (self: View) -> (number?, number?),
	--- Shows only the lines with every word of `text` in them, without minding case, or with `regex` those it matches, among those it shows past the first `skip`; the others stay in the buffer, hidden in this view alone. A word `key=value` looks in a line of JSON or logfmt for `value` in field `key` (a dotted path, through arrays), and for the word itself in other lines; `key>=value`, `>`, `<`, `<=` compare (log levels in their order, numbers as numbers) and `key!=value` keeps lines without it. A word `.a.b` keeps the section of indented text (YAML, indented JSON) under keys a and b, with the keys above what shows. A line with a cursor on it shows anyway. Nil or empty shows every line again, and so does showing another buffer.
	set_filter: (self: View, text: string?, opts: { regex: boolean?, skip: number? }?) -> (),
	--- What `set_filter` was given, while it filters.
	filter: (self: View) -> string?,
	--- How many columns the lines that don't wrap (a mark's `nowrap`) are scrolled to the left.
	side_scroll: (self: View) -> number,
	--- Scrolls the lines that don't wrap `columns` to the left. Drawing scrolls again if the primary cursor is on such a line and would be out of sight, so move it first.
	set_side_scroll: (self: View, columns: number) -> (),
	--- The 0-based line at the top of the view.
	scroll: (self: View) -> number,
	--- Scrolls so `line` is at the top. Drawing scrolls again if the primary
	--- cursor would be off screen, so move it first.
	set_scroll: (self: View, line: number) -> (),
	buffer: (self: View) -> Buffer,
	--- Shows another buffer in this view.
	show: (self: View, buffer: Buffer) -> (),
	--- Focuses this view, so keys go to it, showing its tab and project if it's a pane or panel.
	focus: (self: View) -> (),
	--- Closes the view. Closing a tab's last pane closes the tab; the
	--- project's last pane can't be closed, and returns false.
	close: (self: View) -> boolean,
	--- Changes how a floating view is shown; fields left out stay as they
	--- are. False, changing nothing, if it isn't floating; fails if it was closed.
	configure: (self: View, spec: FloatSpec) -> boolean,
	--- Brings a floating view in front of the other floats; false if it isn't floating.
	raise: (self: View) -> boolean,
	--- How a floating view is shown, as `greed.float` takes it; nil if it isn't floating.
	float_spec: (self: View) -> FloatSpec?,
	--- Whether it's a pane of a tab, rather than a panel or a floating view.
	is_pane: (self: View) -> boolean,
	--- Opens a pane beside this one on its `dir` side, showing `buffer`, or
	--- this view's buffer as it shows it, and focuses it. Fails if this
	--- view isn't a pane.
	split: (self: View, dir: "left" | "right" | "up" | "down", buffer: Buffer?) -> View,
	--- The pane next to this one on its `dir` side, as last drawn: of
	--- several, the one active most recently.
	neighbor: (self: View, dir: "left" | "right" | "up" | "down") -> View?,
	--- Moves this pane's edge on its `dir` side by `cells` (negative to
	--- shrink). False when no pane is on that side. A panel moves the edge by the main view, and only that.
	resize: (self: View, dir: "left" | "right" | "up" | "down", cells: number) -> boolean,
	--- Undoes the last change. Returns false if there was nothing to undo.
	undo: (self: View) -> boolean,
	--- Takes the buffer to node `id` of its undo tree, undoing and redoing on the way, as one move; redo follows that branch from then on. False if there's no such node or the text is there already.
	undo_to: (self: View, id: number) -> boolean,
	redo: (self: View) -> boolean,
}

--- What a command gets when it runs.
export type Context = {
	view: View,
	buffer: Buffer,
	--- The keys that ran the command, e.g. "g g".
	keys: string?,
	--- The character typed, when a single printable key ran the command.
	char: string?,
	--- Arguments, e.g. from the command line; empty when a key ran it.
	args: { string },
	--- The arguments by name: for a typed command, parsed (a number, a boolean, a full path, the `core.Object`), nil for an optional one left out; otherwise the words as given.
	values: { [string]: any },
	--- Go ahead even if the command would normally refuse, like `:q!`
	--- quitting with unsaved changes.
	force: boolean,
	--- The number typed before the keys, in modes with counts on.
	count: number?,
	--- The id of the client it runs for, whose view and selections these are.
	client: number,
}

--- An argument a command takes, for completion, help and checking. Giving any of a command's arguments a `type` has them all checked before it runs, and parsed into `ctx.values`.
export type ArgSpec = {
	name: string,
	doc: string?,
	--- What completes it, e.g. "file", "command", "option" or "buffer". Without it, the command line completes from `type`.
	complete: string?,
	--- What it is: "string" (the default), "number", "boolean" (true/false, yes/no, on/off), "file" or "folder" (one that exists, from the project's root), "choice" (one of `choices`), "object" (an object of `kind`, as `core.objects` has them), or "rest" (the rest of the words, joined by spaces; last only).
	type: string?,
	--- It can be left out; every argument after it must be optional too.
	optional: boolean?,
	--- The words a "choice" can be.
	choices: { string }?,
	--- The kind of object an "object" is, e.g. "note" or "pod".
	kind: string?,
}

export type CommandSpec = {
	--- Plain words with dashes, e.g. "select-line".
	name: string,
	doc: string?,
	args: { ArgSpec }?,
	run: (ctx: Context) -> (),
}

--- A command for the command line, run as `greed NAME ARGS` in an editor
--- with no screen. `run` can wait like a command; what it echoes and
--- returns is printed, and an error makes `greed` fail.
export type CliSpec = {
	--- Plain words with dashes, e.g. "bring".
	name: string,
	doc: string?,
	--- What follows the name, e.g. "HOST [PLUGIN]".
	usage: string?,
	run: (args: { string }) -> string?,
}

--- A keymap layer. Leave `mode` or `kind` out to match any. In place of a
--- mode: `layer` names a layer that isn't a mode, like the "leader", which
--- every editing style enters its own way (`space`, or `ctrl-space`
--- without modes); `role` is an editing role ("command", "typing",
--- "selecting") in every style, and with `style` in that style only.
export type Layer = {
	mode: string?,
	layer: string?,
	role: string?,
	style: string?,
	kind: string?,
}

export type Keymap = {
	--- Binds key sequences to command names, e.g. `{ ["g g"] = "goto-start" }`.
	--- `layer` is a mode name or a `Layer`.
	bind: (layer: string | Layer, bindings: { [string]: string }) -> (),
	--- Hides what each key sequence runs in `layer`, e.g. `{ "w", "g g" }`.
	--- Removing (or reloading) the plugin that unbound them brings them back.
	unbind: (layer: string | Layer, keys: { string }) -> (),
	--- Hides everything bound in `layer` so far, to start it over. Bindings
	--- made afterwards, by any plugin, apply as usual.
	clear: (layer: string | Layer) -> (),
	--- Makes digits typed before a key sequence in `mode` a count, which the
	--- command gets as `ctx.count`. A leading 0 stays a key.
	counts: (mode: string) -> (),
	--- Makes `mode` use only keys bound in it (and its fallback), skipping
	--- inherited ones and those bound for every mode or for a buffer kind,
	--- e.g. for a terminal that takes every key.
	isolate: (mode: string) -> (),
	--- Makes `mode` fall back to `parent`'s keys for sequences starting with
	--- one of `prefixes` (e.g. `{ "space", ":" }`), or for every key without
	--- them. Keys bound in `mode` itself come first; what `parent` inherits
	--- applies in turn. `parent` can be a layer like `{ role = "typing" }`.
	inherit: (mode: string, parent: string | Layer, prefixes: { string }?) -> (),
	--- Makes `mode` use `parent`'s keys ahead of its own, e.g. `{ style = "vim", role = "command" }` for the Vim style's command mode. `core.style.define` does this for each style's roles.
	inherit_first: (mode: string, parent: string | Layer) -> (),
	--- Makes `keys` typed in `mode` lead into `layer`, so what's bound there works after them, e.g. `enter("helix", "space", "leader")`. It comes ahead of the mode's own keys. `core.style.define` does this for each style's leader.
	enter: (mode: string, keys: string, layer: string) -> (),
	--- The command that handles a single unbound key in `mode`. A mode without one uses that of a mode it inherits every key from.
	fallback: (mode: string, command: string) -> (),
	--- The keys that can follow `keys` (e.g. "space") in the current mode, and
	--- the command each runs. Keys without a command start longer sequences.
	next: (keys: string?) -> { { key: string, command: string? } },
	--- Every key sequence that runs `command` (every binding, without one),
	--- the layer it's bound in (a mode name, a named layer like "leader",
	--- "role:typing" or "vim:command", or "global") and its command.
	find: (command: string?) -> { { layer: string, keys: string, command: string } },
	--- Every key sequence that runs a command in the current mode and buffer, through the layers it enters and inherits (the leader's as "space f"), less those a more specific layer hides.
	active: () -> { { keys: string, command: string } },
	--- Binds single keys for the next key press only, over every layer, e.g. `{ ["1"] = "hint-1" }`; any other key drops them and does what it always does. Nil drops them now.
	overlay: (bindings: { [string]: string }?) -> (),
	--- What `keys` runs in the current mode: the command, or nil and whether
	--- more keys could still finish a sequence.
	resolve: (keys: string) -> (string?, boolean),
	--- What `keys` runs in the current mode and buffer and what that hides: the binding in each layer they're bound in, most specific first, each followed by those it hides in its own layer, with the plugin that bound it. The first runs.
	describe: (keys: string) -> { { layer: string, command: string, plugin: string } },
}

export type Mode = {
	get: () -> string,
	--- Switches mode, emitting "mode.changed" if it changed. A mode exists once keys are bound in it or it has a fallback, a parent, counts or a cursor shape; switching to one that doesn't is an error listing those that do.
	set: (name: string) -> (),
	--- Sets how the cursor looks in `mode`; modes without a shape get a block.
	set_cursor: (mode: string, shape: "block" | "bar" | "underline") -> (),
	--- The cursor shape of `mode`, or of the current mode. A block or underline sits on a character, the last of a selection going forward; a bar sits between characters.
	cursor_of: (mode: string?) -> "block" | "bar" | "underline",
}

export type OptionValue = boolean | number | string

export type Options = {
	--- Defines an option. With `choices`, it takes only those values (the default among them), and `:set` completes them. With `needs`, a capability like "proc", only code that has it, or you yourself (`:set`, your config), may set it: for an option whose value is run, like a command line. A plugin can't define an option another plugin defined.
	define: (spec: { name: string, doc: string?, default: OptionValue, choices: { OptionValue }?, needs: string? }) -> (),
	--- The option's value for the acting client: its own, if it has one, else everyone's.
	get: (name: string) -> OptionValue?,
	--- Sets an option for every client; fails on an unknown name, the wrong type or a value that isn't one of its choices. With `client`, sets a value of the acting client's own instead, like a window's font size, which nil takes away again; setting it for every client takes away each client's own.
	set: (name: string, value: OptionValue?, opts: { client: boolean? }?) -> (),
	--- Every option, sorted by name.
	list: () -> { OptionInfo },
}

export type OptionInfo = {
	name: string,
	doc: string,
	value: OptionValue,
	default: OptionValue,
	--- The values it can take; empty when any value of its type will do.
	choices: { OptionValue },
	--- The plugin that defined it.
	owner: string,
	--- The plugin that last set it (your config is a plugin too), if anything has.
	set_by: string?,
	--- Where it was defined, e.g. "core/edit.luau:12", and the file and line
	--- when that file is on disk.
	source: string?,
	path: string?,
	line: number?,
}

--- An event handler, as `greed.handlers()` lists it.
export type HandlerInfo = {
	event: string,
	--- The plugin that added it.
	owner: string,
	source: string?,
	path: string?,
	line: number?,
}

--- Recording what's typed and feeding keys back, for macros and repeating
--- changes. Recordings have names (macros use the default, ""), so several
--- can run at once.
export type Keys = {
	--- Starts keeping every key typed in the recording `name`, until `stop`; with `fed`, keys `feed` presses too.
	record: (name: string?, opts: { fed: boolean? }?) -> (),
	--- Stops the recording `name` and returns the keys typed, e.g. `{ "i", "x", "esc" }`, or nil if it wasn't recording.
	stop: (name: string?) -> { string }?,
	recording: (name: string?) -> boolean,
	--- Presses the keys of a space-separated sequence as if they were
	--- typed. Only recordings started with `fed` keep them. What they run
	--- can do only what this plugin may (unless it has "commands"), and they
	--- don't answer a command waiting for you to press a key. A command
	--- that works long enough to give the editor a turn finishes before
	--- the next key; one waiting on a timer or a job doesn't hold them up.
	feed: (keys: string) -> (),
}

--- A request for `greed.http`. `method` defaults to POST with a body and GET
--- without; `timeout` is in milliseconds, for the whole request, and
--- `head_timeout` for the status and headers alone, which limits a stream's
--- wait without limiting its body. With `save`,
--- `request` writes a successful (2xx) response's body to that file as it
--- arrives, creating its folders, and returns an empty body; the file appears
--- only once it's whole. Other responses come back as usual and nothing is
--- written. Saving needs "fs.write".
export type HttpRequest = {
	url: string,
	method: string?,
	headers: { [string]: string }?,
	body: string?,
	timeout: number?,
	head_timeout: number?,
	save: string?,
}

--- A whole response. Header names are lowercase.
export type HttpResponse = {
	status: number,
	headers: { [string]: string },
	body: string,
}

--- A response whose body arrives in pieces. `read` waits for the next piece
--- and returns it, nil at the end, or nil and why it failed; given
--- `timeout` milliseconds, it gives up after them with nil and "timed out",
--- and the stream stays open for the next read. `close` stops reading, and
--- a read waiting in another task returns nil.
export type HttpStream = {
	status: number,
	headers: { [string]: string },
	read: (self: HttpStream, timeout: number?) -> (string?, string?),
	close: (self: HttpStream) -> (),
}

--- Requests over the network, each on a thread of its own so the editor
--- never waits. Both wait like greed.sleep, so they work in commands and event
--- handlers. A plugin needs the "net" capability, or "net:HOST" for one host.
export type Http = {
	--- Sends a request and returns the whole response, or nil and why.
	request: (request: HttpRequest) -> (HttpResponse?, string?),
	--- Sends a request and returns once the status and headers are in; read
	--- the body as it arrives, e.g. tokens from a model.
	stream: (request: HttpRequest) -> (HttpStream?, string?),
}

--- Secrets like API keys, kept out of config and plugin source: from the
--- environment (GREED_SECRET_NAME, or the usual variable, e.g. ANTHROPIC_API_KEY),
--- the system keyring, or Greed's own secrets file. Both wait like greed.sleep. A
--- plugin needs "secrets:NAME" for each secret it reads, or "secrets" for all.
export type Secrets = {
	--- The secret `name`, or nil if it isn't set anywhere; then also why when the system keyring couldn't be reached (e.g. secret-tool isn't installed), since it may be kept there.
	get: (name: string) -> (string?, string?),
	--- Keeps `value` as the secret `name`: in the keyring if it can be reached, otherwise in Greed's secrets file. Returns where it went (with why not the keyring, when it couldn't be reached), or nil and why not.
	set: (name: string, value: string) -> (string?, string?),
	--- The environment variable that sets the secret `name`, to tell someone: the usual one, like ANTHROPIC_API_KEY, or GREED_SECRET_NAME. Reads nothing, so it needs no capability.
	variable: (name: string) -> string,
}

--- How `greed.process.run` runs a program: `stdin` is its input, `cwd` its folder; in `env`, `false` leaves a variable out of what it inherits. With `timeout` (milliseconds) it's killed if it runs longer; with `group`, it gets a process group of its own, which that reaches too. `on_start(child)` gets it as it starts, to stop it from elsewhere.
export type RunOptions = { stdin: string?, cwd: string?, env: { [string]: string | false }?, timeout: number?, group: boolean?, on_start: ((child: Child) -> ())? }

--- How a program `greed.process.run` ran went: its exit `code`, or the `signal` that ended it, what it printed, and whether its timeout ended it.
export type Ran = { code: number?, signal: string?, stdout: string, stderr: string, timed_out: boolean }

--- Running other programs.
export type Process = {
	--- Runs `command` (the program, then its arguments) to its end as `opts` say and returns how it went; nil and the error if it couldn't start. Like a spawned program it's the plugin's, and goes with it. It waits like greed.sleep, so only in commands, event handlers and greed.spawn.
	run: (command: { string }, opts: RunOptions?) -> (Ran?, string?),
	--- Starts `command` to talk to over its input and output, like an agent speaking JSON-RPC, and returns at once; nil and the error if it couldn't start. It runs until it exits, is killed, or the plugin that started it unloads. In `env`, `false` leaves a variable out of what it inherits. With `stderr = "stream"`, what it prints as errors arrives from `read` too, in the order it comes; by default it's only kept for `child:stderr()`. With `group`, it starts a process group of its own, which `kill` and `signal` reach, so the programs it starts end with it.
	spawn: (command: { string }, opts: { cwd: string?, env: { [string]: string | false }?, stderr: ("keep" | "stream")?, group: boolean? }?) -> (Child?, string?),
}

--- How `greed.rpc.start` talks to a program. `framing` is how its messages are told apart: "headers" (`Content-Length`, as language servers and debug adapters write them; the default) or "lines" (one a line, as agents over ACP). `on_request(method, params)` answers its requests, returning the result or nil and an error; `on_notify(method, params)` hears its notifications; each runs in a coroutine of its own, so it may wait. `on_exit(stderr)` is called once it exits, with the last lines of its error output.
export type RpcOptions = { cwd: string?, env: { [string]: string | false }?, framing: ("headers" | "lines")?, on_request: ((method: string, params: any) -> (any, string?))?, on_notify: ((method: string, params: any) -> ())?, on_exit: ((stderr: string) -> ())? }

--- A JSON-RPC connection to a program, from `greed.rpc.start`.
export type RpcConnection = {
	--- Sends a request and waits for its result, or nil and the error. Waits like greed.sleep, so only in commands, event handlers and greed.spawn.
	request: (self: RpcConnection, method: string, params: any) -> (any, string?),
	--- Sends a notification; false if it couldn't go.
	notify: (self: RpcConnection, method: string, params: any) -> boolean,
	--- Whether the program is still running.
	alive: (self: RpcConnection) -> boolean,
	--- The last lines of its error output.
	stderr: (self: RpcConnection) -> string,
	--- Ends the connection; the program's input closes and it's killed if it doesn't exit soon after.
	close: (self: RpcConnection) -> (),
}

--- JSON-RPC 2.0 with a program, on the transport language servers use.
export type Rpc = {
	--- Starts `command` and talks JSON-RPC with it; nil and the error if it couldn't start. Needs "proc". The connection is the plugin's, and goes with it.
	start: (command: { string }, opts: RpcOptions?) -> (RpcConnection?, string?),
}

--- A program started with `greed.process.spawn`.
export type Child = {
	pid: number,
	--- Sends `text` to its input; false once that's closed.
	write: (self: Child, text: string) -> boolean,
	--- Waits for the next piece of what it prints, and returns it with the output it came from, "stdout" or "stderr" (only with `stderr = "stream"`); nil once it exited and everything was read. Only in commands, event handlers and greed.spawn.
	read: (self: Child) -> (string?, ("stdout" | "stderr")?),
	--- Closes its input, which tells most programs to finish.
	close: (self: Child) -> (),
	--- Ends it (and with `group`, its process group) with KILL.
	kill: (self: Child) -> (),
	--- Sends it a signal by name, like "INT", "TERM", "HUP" or "QUIT"; with `group`, to its process group, even after it exited, as a shell signals a job. Returns whether it went.
	signal: (self: Child, name: string) -> boolean,
	--- Waits for it to exit and returns its exit code, or nil and the name of the signal that ended it, like "INT".
	wait: (self: Child) -> (number?, string?),
	--- The end of what it printed as errors so far.
	stderr: (self: Child) -> string,
}

--- A line of a terminal: its text, and the parts with a style of their own
--- (byte offsets, 0-based, `to` exclusive), styled with inline names like
--- "=fg:red bold".
export type TerminalRow = {
	text: string,
	spans: { { from: number, to: number, style: string } },
	--- Images on the row, as runs of cells from byte `from`: from the image's
	--- cell (`col`, `row`) on, of an image `cols` by `rows` cells. `id` is a
	--- `greed.image` id, for a mark's `image`.
	images: { { from: number, id: number, col: number, row: number, cols: number, rows: number } },
	--- Links the program printed (OSC 8), as byte ranges and where they go.
	links: { TerminalLink },
	--- Whether the line carries on on the next row: the program printed past the last column and the terminal wrapped it.
	wrapped: boolean,
}

--- The modes a terminal's program set, from `terminal:modes()`.
export type TerminalModes = {
	--- A full screen program, like an editor or a pager, is showing.
	alternate: boolean,
	--- Input goes to the program a line at a time; off in raw mode, which editors and prompts set.
	canonical: boolean,
	--- Typed text is echoed; off while a program reads a password.
	echo: boolean,
	--- The program asked for mouse events.
	mouse: boolean,
	--- Arrow keys are sent in application mode.
	app_cursor: boolean,
	--- Pastes are marked as pastes.
	bracketed_paste: boolean,
}

export type TerminalLink = { from: number, to: number, uri: string }

--- What a terminal shows.
export type TerminalScreen = {
	rows: { TerminalRow },
	--- The cursor's row (0-based) and byte offset in it, unless the program
	--- hid it.
	cursor: { row: number, col: number }?,
	--- Whether a full screen program, like an editor or a pager, is showing.
	alternate: boolean,
}

--- A program running in a terminal. Two handles to the same terminal are
--- equal (`==`).
export type Terminal = {
	--- Its id, even after it was closed.
	id: (self: Terminal) -> number,
	--- Whether it is still open. Other methods fail once it was closed.
	valid: (self: Terminal) -> boolean,
	screen: (self: Terminal) -> TerminalScreen,
	--- The lines that scrolled off the top, from line `from` (counting from
	--- the terminal's first line) on, or from the oldest one kept. `first` is
	--- the number of the first line returned.
	scrollback: (self: Terminal, from: number?) -> { first: number, rows: { TerminalRow } },
	--- The places the shell marked (OSC 133) on line `from` (counting as
	--- `scrollback` does) and after, oldest first: where a prompt starts,
	--- where the typed command starts, where its output starts, and where it
	--- was done, with its exit code if the shell said. `col` is a byte in the
	--- line's text.
	marks: (self: Terminal, from: number?) -> { TerminalMark },
	--- How many marks the shell has made so far, to tell when there are new
	--- ones without asking for them all.
	marks_made: (self: Terminal) -> number,
	--- The folder the shell last said it's in (OSC 7), or the one it started
	--- in.
	cwd: (self: Terminal) -> string?,
	--- Sends text to the program as if typed. This and the other methods
	--- that send input need "proc": the plugin that started the terminal
	--- has it through the handle it got; others with one from an event need
	--- their own.
	write: (self: Terminal, text: string) -> (),
	--- Sends a key, e.g. "ctrl-c" or "up", as a terminal encodes it.
	key: (self: Terminal, name: string) -> (),
	--- Sends pasted text, marked as a paste if the program asked for that.
	paste: (self: Terminal, text: string) -> (),
	--- Changes its size, kept to between 1 by 1 and 1024 rows by 2048 columns.
	resize: (self: Terminal, rows: number, cols: number) -> (),
	--- Whether the program asked for mouse events, as editors and htop do.
	wants_mouse: (self: Terminal) -> boolean,
	--- The modes the program set: the alternate screen, line input and echo (from the terminal's settings), mouse, application cursor keys and bracketed paste.
	modes: (self: Terminal) -> TerminalModes,
	--- Sends a mouse event at the program's screen cell (`col`, `row`),
	--- 0-based, if it asked for that kind: `kind` as in a MouseEvent, with
	--- a button or a scroll direction. Returns whether it was sent.
	mouse: (self: Terminal, kind: string, col: number, row: number, which: string?, mods: { ctrl: boolean?, alt: boolean?, shift: boolean? }?) -> boolean,
	--- What the program called its window, if it did.
	title: (self: Terminal) -> string?,
	--- The name of the program it started, like "nu" or "cargo": its file name, or the shell's for a terminal started without a command.
	program: (self: Terminal) -> string,
	--- The program's exit code, once it has ended.
	exit_code: (self: Terminal) -> number?,
	--- Whether a program other than the one it started is in the foreground, like a command its shell runs. False once it has ended.
	busy: (self: Terminal) -> boolean,
	--- Asks the program to end.
	kill: (self: Terminal) -> (),
	--- Interrupts what runs in the foreground, as ctrl-c does, even in the moment after it starts, before a typed ctrl-c would reach it. Returns whether it went.
	interrupt: (self: Terminal) -> boolean,
	--- Ends the program and lets the terminal go; its handle stops working.
	close: (self: Terminal) -> (),
}

--- Programs in terminals. A terminal belongs to the plugin that started it.
export type Terminals = {
	--- Starts `command` (the program, then its arguments; the user's shell
	--- without) in a terminal of `rows` by `cols`. Its output arrives as
	--- "terminal.output" events and its end as "terminal.exited".
	--- `scrollback` lines are kept above the screen (default 10000). The
	--- size is kept to between 1 by 1 and 1024 rows by 2048 columns. In
	--- `env`, `false` leaves a variable out of what the program inherits.
	spawn: (spec: { command: { string }?, cwd: string?, env: { [string]: string | false }?, rows: number, cols: number, scrollback: number? }) -> Terminal,
}

--- A place a shell marked in a terminal, from `terminal:marks()`.
export type TerminalMark = {
	line: number,
	col: number,
	kind: "prompt" | "command" | "output" | "done",
	--- The exit code, for "done", if the shell said.
	code: number?,
}

--- A terminal printed something; read it with `terminal:screen()`.
export type TerminalOutput = {
	terminal: Terminal,
}

--- The program in a terminal ended.
export type TerminalExited = {
	terminal: Terminal,
	code: number,
	--- Whether a signal ended the program, rather than its own exit.
	signaled: boolean,
}

--- A state of a buffer's text in its undo tree, from `buffer:undo_tree()`.
export type UndoNode = {
	--- 0 is the text as loaded; later states have higher ids.
	id: number,
	parent: number?,
	--- Oldest first; redo follows the last.
	children: { number },
	--- When the step was last added to, in seconds like `os.time()`; nil for node 0.
	time: number?,
}

--- A transaction applied to a buffer, from `buffer:history()`.
export type HistoryEntry = {
	id: number,
	author: "user" | "plugin" | "agent" | "external",
	--- The plugin, for edits a plugin made.
	plugin: string?,
	--- Why: the command it was made for, "undo", "redo", ...
	cause: string?,
	--- The undo group it was made in.
	group: number?,
	--- When, in seconds since 1970.
	time: number,
	--- What it replaced, in the text before it, in order.
	changes: { { from: number, to: number, text: string } },
}

export type HistoryFilter = {
	author: string?,
	plugin: string?,
	cause: string?,
	group: number?,
	since: number?,
	limit: number?,
}

export type History = {
	--- Edits until `end_group` become one undo step.
	start_group: () -> (),
	end_group: () -> (),
	--- A group id nothing has used yet, for `set_group`.
	new_group: () -> number,
	--- The group edits go into now, if any.
	group: () -> number?,
	--- Puts the edits that follow, in every buffer, into `group` (one used before
	--- carries on), or with nil into none. Edits in a group undo as one step.
	set_group: (group: number?) -> (),
	--- Why edits are being made: by default the command running.
	cause: () -> string?,
	--- Sets why the edits that follow are made, for the rest of this command.
	set_cause: (cause: string?) -> (),
	--- Undoes `group` in every buffer it changed, as one step. Returns how many
	--- buffers changed (0 if it was undone already), or nil and why not, when
	--- something was done on top of it since.
	undo_group: (group: number) -> (number?, string?),
}

--- How a floating view looks. Sizes are cells, or a share of the screen as
--- a string like "60%" or "37.5%", which keeps the float in proportion on
--- clients with screens of other sizes; both default to "60%".
export type FloatSpec = {
	title: string?,
	width: (number | string)?,
	height: (number | string)?,
	--- Where it goes when `x` or `y` is left out: in the middle, at an edge
	--- or in a corner. "cursor" opens it just below the cursor (or above,
	--- near the bottom), like a completion menu; "above-cursor" prefers
	--- above, like signature help.
	anchor: ("center" | "top" | "bottom" | "left" | "right" | "top-left" | "top-right" | "bottom-left" | "bottom-right" | "cursor" | "above-cursor")?,
	--- Whether the view takes focus. Defaults to true.
	focus: boolean?,
	--- Where the outside of the border goes, from the screen's left and top
	--- edges, in cells or like "37.5%". Left out, the float goes where
	--- `anchor` says on that axis. It's always kept on screen.
	x: (number | string)?,
	y: (number | string)?,
	--- Whether it belongs to the tab it opens in: shown only with that tab,
	--- and closed with it, like a floating terminal. Otherwise it floats over
	--- every tab, like a picker. Defaults to false.
	tab: boolean?,
	--- Whether every client is shown it, like a review meant for everyone.
	--- Otherwise only the client it opened for is (the one acting then),
	--- as with a picker or a prompt, unless it belongs to a tab, which every
	--- client showing the tab sees. Defaults to false.
	shared: boolean?,
	--- Text at the right end of the top border, e.g. "‹ 2/5 ›", or pieces
	--- with styles of their own. "" takes it off.
	label: MarkLine?,
	--- Text in the middle of the bottom border, as `label` takes it.
	footer: MarkLine?,
	--- Whether it has a border; defaults to true. Without one its text
	--- fills its whole box, like a one-line strip.
	border: boolean?,
	--- Hides it: its view and buffer stay (a terminal keeps running), but
	--- it isn't drawn, `greed.floats()` leaves it out and focus moves on.
	--- Focusing it shows it again.
	hidden: boolean?,
}

export type CommandInfo = {
	name: string,
	doc: string,
	args: { ArgSpec },
	--- How it's typed, e.g. "kube-namespace [NAME]".
	usage: string,
	--- The plugin that defined it.
	owner: string,
	--- Where it was defined, e.g. "core/motions.luau:120".
	source: string?,
	--- The file and line it was defined on, when that file is on disk.
	path: string?,
	line: number?,
}

--- A buffer was closed. Only its id is left.
export type BufferClosed = {
	id: number,
}

export type BufferChanged = {
	buffer: Buffer,
	--- On "buffer.changed": the first and last line (0-based, as the text is
	--- now) of what changed since the last "buffer.changed" for the buffer.
	from_line: number?,
	to_line: number?,
}

--- A request from the session socket, e.g. from `greed ctl` or an agent.
--- Answer it with `greed.control.reply`.
export type ControlRequest = {
	id: number,
	--- "socket" for the session socket (greed ctl, greed mcp), "ide" for Claude
	--- Code's IDE connection.
	client: string,
	--- The session socket connection it came on, for `greed.control.send`;
	--- nil for Claude Code's IDE connection.
	connection: number?,
	method: string,
	params: any,
}

--- A session socket connection closed, after its last request came.
export type ControlClosed = {
	--- The connection, as `ControlRequest.connection` gave it.
	connection: number,
}

export type Signal = {
	--- Waits until a value is sent, and returns it.
	wait: (self: Signal) -> any,
	--- Sends `value` to whoever waits. Only the first send counts.
	send: (self: Signal, value: any) -> (),
}

--- A project: a folder with its own main view and panels.
export type ProjectInfo = {
	id: number,
	root: string,
	--- Whether it's the one shown.
	current: boolean,
}

export type Projects = {
	--- Every open project, in the order they were opened.
	list: () -> { ProjectInfo },
	current: () -> ProjectInfo,
	--- Opens a project rooted at `root`, with an empty main view, and shows
	--- it. Returns its id.
	open: (root: string) -> number,
	--- Shows project `id`. False if there is none.
	switch: (id: number) -> boolean,
	--- Closes project `id` with its views and the buffers opened in it. The
	--- last project can't be closed; false then.
	close: (id: number) -> boolean,
}

--- Images for marks to show. Each is kept until forgotten.
export type Images = {
	--- Reads a PNG, JPEG or GIF file. Returns the image's id, or nil and why
	--- not.
	load: (path: string) -> (number?, string?),
	--- The same, from the file's bytes.
	decode: (bytes: string) -> (number?, string?),
	--- Its width and height in pixels.
	size: (id: number) -> (number?, number?),
	--- How many cells it covers at its own size on the attached screen.
	cells: (id: number) -> (number?, number?),
	--- A cell's width and height in pixels on the attached screen.
	cell_size: () -> (number, number),
	forget: (id: number) -> (),
}

--- Small vector drawings, as charts are, for a mark's `scene`: each client draws one as well as it can (an image in a terminal with kitty graphics), and the text under it is what the others show. A spec is `{ alt, items }`: `alt` says what it shows, and items are `line` (points, style, weight), `area` (points, base, fill, opacity), `rect` (at, size, fill, style, opacity), `dots` (points, style, weight), `text` (at, text, style, align) and `group` (items, clip), in cells from the top left. `require("@scene")` draws a spec in characters.
export type Scenes = {
	--- Keeps a scene and returns its id.
	new: (spec: { alt: string, items: { any } }) -> number,
	--- Makes `spec` what scene `id` shows, at its next version; false when there's no such scene.
	set: (id: number, spec: { alt: string, items: { any } }) -> boolean,
	forget: (id: number) -> (),
}

--- PDF documents.
export type Pdfs = {
	--- Reads the PDF at `path`. Returns the document, or nil and why not. It waits like greed.sleep, so only in commands, event handlers and greed.spawn.
	open: (path: string) -> (PdfDocument?, string?),
}

--- A PDF read with `greed.pdf.open`. Pages count from 1.
export type PdfDocument = {
	pages: number,
	--- A page's width and height in points (1/72 inch).
	size: (self: PdfDocument, page: number) -> (number?, number?),
	--- Draws a page at `scale` pixels per point (1 if not given) and returns it as a `greed.image` id, or nil and why not. Forget the image when done with it. Waits like greed.sleep.
	render: (self: PdfDocument, page: number, scale: number?) -> (number?, string?),
	--- The text on a page, line by line from the top, or nil and why not. Waits like greed.sleep.
	text: (self: PdfDocument, page: number) -> (string?, string?),
}

--- A tab of the shown project: panes laid out side by side and one above
--- another.
export type TabInfo = {
	id: number,
	--- The name it was given, if any.
	name: string?,
	--- Whether it's the one shown.
	current: boolean,
	--- Whether only its active pane is shown.
	zoomed: boolean,
	--- Its panes, left to right and top to bottom.
	panes: { View },
	--- The pane keys go to while it's shown.
	active: View,
}

export type Tabs = {
	--- The shown project's tabs, in order.
	list: () -> { TabInfo },
	current: () -> TabInfo,
	--- Opens a tab after the shown one, with a pane showing `buffer` (or an
	--- empty buffer), and shows it. Returns its id.
	new: (buffer: Buffer?) -> number,
	--- Shows tab `id`, of whichever project, and its project. False if there's no such tab.
	switch: (id: number) -> boolean,
	--- Closes tab `id` and its panes. The last tab can't be closed; false
	--- then.
	close: (id: number) -> boolean,
	--- Names tab `id`; nil or "" names it after what it shows again.
	rename: (id: number, name: string?) -> boolean,
	--- Shows only the active pane of the shown tab, or all of them again.
	set_zoomed: (zoomed: boolean) -> (),
	--- How tab `id` (the shown one by default) lays out its panes, as a
	--- `PaneLayout`, with sizes adding up to 1 in each split.
	layout: (id: number?) -> any,
	--- Lays tab `id`'s panes out as `layout` (a `PaneLayout`) instead. It
	--- arranges the panes the tab has, so it has to hold each of them once;
	--- opening and closing panes is `view:split` and `view:close`. A split
	--- of one pane is that pane; splits nest at most 64 deep.
	set_layout: (layout: any, id: number?) -> (),
}

--- A tab's panes: a pane is its view, a split lays out its children side by
--- side ("row") or one above another ("column"), sharing the room by
--- `sizes`, which are relative to each other (equal when left out).
export type PaneLayout = View | { split: "row" | "column", children: { PaneLayout }, sizes: { number }? }

--- A pane was opened, beside `from`.
export type PaneOpened = {
	view: View,
	from: View,
}

--- A session running on this machine: an editor process of its own.
export type SessionInfo = {
	name: string,
	--- The project it was started for.
	root: string?,
	--- The build of greed it runs, as `greed --version` says it, if it said.
	build: string?,
	--- Whether it's this session.
	current: boolean,
}

export type Sessions = {
	--- The sessions running on this machine, by name.
	list: () -> { SessionInfo },
	--- This session's name, when the editor runs as one.
	current: () -> string?,
	--- Which build of greed this is, as `greed --version` says it.
	build: () -> string,
	--- Whether the session was started with `greed --fresh`, to begin without what it had open before.
	fresh: () -> boolean,
	--- Whether the attached client (or the last one) came over `greed ssh`; before any attached, whether `greed ssh` started the session.
	remote: () -> boolean,
	--- Whether a terminal or window is attached to the session.
	attached: () -> boolean,
	--- Where the greed program running this editor is, to start `greed mcp` or `greed ctl` for this session.
	program: () -> string?,
	--- Sends the attached client to the session `name`, or to the session for
	--- the project `path` is in (opening it there), starting it if it isn't
	--- running. This session goes on without the client. With `new`, a new
	--- session for `path`'s project, even when one is running for it. With
	--- `host`, the session is on that machine, reached as `greed ssh` does.
	switch: (to: { name: string?, path: string?, new: boolean?, host: string? }) -> (),
}

--- JSON. Tables with keys 1..n become arrays, other tables objects; an
--- empty table is an object unless it came from `array`.
export type Json = {
	--- `value` as JSON. Text that isn't UTF-8, like a program's binary
	--- output, has its broken bytes written as U+FFFD.
	encode: (value: any) -> string,
	--- The value, or nil and why the text isn't JSON. `null` becomes nil.
	decode: (text: string) -> (any, string?),
	--- Marks `items` (or a new table) to encode as an array even when empty.
	array: <T>(items: { T }?) -> { T },
}

--- Needs the "control" capability (and `serve_ide` "net" too).
export type Control = {
	--- Answers request `id` with `result`, or with an error `message`. Every
	--- request needs exactly one answer.
	reply: (id: number, result: any, message: string?) -> (),
	--- Sends a notification of `method` with `params` to the session socket
	--- connection a request came on (its `connection`), e.g. MCP's
	--- "notifications/tools/list_changed". False if that connection has closed.
	send: (connection: number?, method: string, params: any) -> boolean,
	--- Lets Claude Code find this editor with /ide: listens on a localhost
	--- WebSocket and writes a lock file naming `folders` as open, in `lock_dir`
	--- (default ~/.claude/ide). Its requests come with client "ide". Returns
	--- the port; calling it again replaces the connection.
	serve_ide: (folders: { string }, lock_dir: string?) -> number,
	--- Sends a notification, e.g. "selection_changed", to Claude Code.
	notify: (method: string, params: any) -> (),
}

--- A program in a session `greed ssh` started asks to sign with one of your ssh keys, through the client relaying your agent. Answer with `greed.ssh_agent.answer`; with no answer, or no handler, it may not.
export type SshAgentUse = {
	--- The request, for `greed.ssh_agent.answer`.
	id: number,
	--- The client relaying your agent, which handlers run as.
	client: number,
	--- The machine that client is on, if known.
	host: string?,
}

--- Needs the "ssh-agent" capability.
export type SshAgent = {
	--- Answers "ssh_agent.use" request `id`: whether the program may sign with your key. False if it no longer waits (answered already, or it gave up).
	answer: (id: number, allowed: boolean) -> boolean,
}

--- One row of `greed.profile.stop()`: what a plugin (nil for the editor itself) spent doing one thing, in all and at most once, in milliseconds.
export type ProfileRow = { plugin: string?, what: string, ms: number, longest: number, runs: number }

--- One line `greed.debug.lines()` returns: `id` counts up, `at` is milliseconds since the editor started, `plugin` is set for a plugin's own lines.
export type DebugLine = { id: number, at: number, topic: string, plugin: string?, text: string }

--- Debug lines: what the editor, its clients and plugins say they're doing, kept while their topic is on. Topics: keys, runs, frames, rpc, jobs, client, plugins (or `plugin:NAME` for one). Off, a topic costs next to nothing.
export type Debug = {
	--- Keeps a line from this plugin, its parts joined by spaces, when `plugins` or `plugin:NAME` is on; otherwise does nothing. Check `on()` first when making the parts costs something.
	log: (...any) -> (),
	--- Whether this plugin's lines are kept, or with `name`, whether that topic (or `plugin:NAME`) is on.
	on: (name: string?) -> boolean,
	--- Turns a topic, `plugin:NAME`, or `all` on or off.
	set: (name: string, on: boolean) -> (),
	--- Switches topics as `words` say, with spaces between: a name turns it on, `-name` off, `off` everything, as `:debug` takes them.
	switch: (words: string) -> (),
	--- Turns every topic off.
	off: () -> (),
	--- What's on.
	enabled: () -> { string },
	--- Every topic's name.
	topics: () -> { string },
	--- The lines kept, oldest first: those after the id `after`, of one `topic` or `plugin`, at most the last `limit` (1000).
	lines: (opts: { after: number?, limit: number?, topic: string?, plugin: string? }?) -> { DebugLine },
	--- Forgets the lines kept so far.
	clear: () -> (),
}

--- A client attached, e.g. `greed FILE` in a session that was running. Handlers run as that client.
export type ClientAttached = {
	--- The client's id.
	client: number,
	--- The file or folder it asked to open, if any.
	path: string?,
	--- Whether it asked for a terminal, e.g. `greed ssh HOST --terminal`.
	terminal: boolean,
	--- Whether it asked for the project's greed shell, e.g. `greed --shell`.
	shell: boolean,
	--- Whether it came over `greed ssh`.
	remote: boolean,
}

--- A client went; the session goes on. Handlers run as that client, just before it's gone.
export type ClientDetached = {
	client: number,
}

--- Text pasted into the client from the system clipboard: a terminal's paste, or a window's paste keys (ctrl-shift-v, shift-insert, cmd-v). The core plugin puts it at the cursors.
export type ClientPaste = {
	--- The client it was pasted into, which handlers run as.
	client: number,
	text: string,
}

--- A view was closed. Its handle no longer works, but its id can be
--- compared with `view:id()`.
export type ViewClosed = {
	view: number,
}

--- What the mouse did, and what was under it.
export type MouseEvent = {
	--- The client whose mouse it was, which handlers run as.
	client: number,
	kind: "press" | "release" | "drag" | "move" | "scroll",
	--- For a press, release or drag.
	button: ("left" | "middle" | "right")?,
	--- For a scroll.
	dir: ("up" | "down" | "left" | "right")?,
	--- The screen cell, from the top left.
	col: number,
	row: number,
	ctrl: boolean,
	alt: boolean,
	shift: boolean,
	--- The view under it, if any.
	view: View?,
	--- The place in the view's buffer under it: the character there, or the
	--- end of the line past it. Over a mark's text, where the mark starts.
	pos: number?,
	--- The action of the mark whose text it's over, or of the status line segment (with no `view`), if that has one.
	action: string?,
	--- The cell in the view's text, from its top left, right of the gutter.
	x: number?,
	y: number?,
	--- The tab whose name it's over, in the tab line.
	tab: number?,
	--- On a floating view's border (with `view` set), which part: "top" (the title's), "bottom", "left", "right", or a corner like "bottom-right".
	border: ("top" | "bottom" | "left" | "right" | "top-left" | "top-right" | "bottom-left" | "bottom-right")?,
	--- On the line between a pane or panel (`view`) and its neighbor, the side of `view` it's on: "right" or "down" for panes, the side by the main view for panels. Dragging it resizes `view` with `resize`.
	edge: ("left" | "right" | "down")?,
}

--- A view was drawn for a client with room for a different number of rows
--- or columns of text than before. Handlers run as that client.
export type ViewResized = {
	client: number,
	view: View,
	rows: number,
	cols: number,
}

--- A view was drawn for a client starting at a different line than before.
--- What a handler changes shows in the same frame, so a view can scroll
--- another along with it. Handlers run as that client.
export type ViewScrolled = {
	client: number,
	view: View,
	--- The 0-based line now at the top.
	line: number,
}

--- A view's selection changed for a client, or it shows another buffer,
--- since the last frame: told once a frame however many changes there were,
--- whatever made them (keys, the mouse, undo, a plugin or an agent).
--- Handlers run as that client.
export type SelectionChanged = {
	client: number,
	view: View,
}

--- Another view has a client's focus. `from` had it before; nil when it was
--- closed. Handlers run as that client.
export type ViewFocused = {
	client: number,
	view: View,
	from: View?,
	--- The focus was moved under the client rather than by it: what it had focused went out of sight by another client's doing (another tab or project shown, a pane closed), or it followed the others again. Its half-typed keys were dropped.
	moved: boolean,
}

--- An option was set, with `greed.option.set` or `:set`.
export type OptionChanged = {
	name: string,
	--- Its value now, as the client it was set for has it.
	value: OptionValue,
	--- The client it was set for, when one got a value of its own.
	client: number?,
}

--- A file watched with `greed.fs.watch` was written, created or removed.
export type FileChanged = {
	path: string,
}

--- A plugin was loaded (or reloaded) and its entry file ran.
export type PluginLoaded = {
	name: string,
	--- Its folder, for plugins loaded from one.
	dir: string?,
}

--- A plugin was unloaded, and everything it registered removed.
export type PluginUnloaded = {
	name: string,
}

export type CommandRun = {
	--- The client it runs for, which handlers run as.
	client: number,
	--- The command about to run.
	name: string,
	--- The keys that ran it, when keys did, e.g. "g g".
	keys: string?,
	--- The number typed before the keys.
	count: number?,
}

export type KeysPending = {
	--- The client typing them, which handlers run as.
	client: number,
	--- The unfinished key sequence, e.g. "space"; "" once it's finished.
	keys: string,
}

--- A piece of the status line: plain text, or text with a style.
export type StatusSegment = string | {
	text: string,
	--- A style name, e.g. "ui.statusline.mode", drawn over "ui.statusline".
	style: string?,
	--- A command a click on it runs.
	action: string?,
}

--- What a status line function gets, for the main view.
export type StatusContext = {
	view: View,
	buffer: Buffer,
	mode: string,
	--- The latest message or error, if there is one to show.
	message: string?,
	--- The width of the screen in cells.
	width: number,
}

--- Segments for each side. The space between is padded; if the line is too
--- long, the last segment on the left keeps only its end.
export type StatusParts = {
	left: { StatusSegment }?,
	right: { StatusSegment }?,
}

--- Copied text. Each copy holds one piece per selection it came from, so
--- pasting into the same number of selections puts each piece back.
export type Clipboard = {
	set: (pieces: string | { string }) -> (),
	--- The latest copy.
	get: () -> { string }?,
	--- Recent copies, newest first.
	history: () -> { { string } },
	--- The image on the system clipboard of the client acting now, as PNG bytes, read on that client's own machine (so with `greed ssh`, your laptop's); nil when there's none or the client can't read it. Waits like greed.sleep.
	image: () -> string?,
}

--- A client attached to the editor: a terminal or window, on this machine or over `greed ssh`.
export type ClientInfo = {
	id: number,
	--- Its kind and machine, like "tui@laptop"; a client coming back with the same name gets its cursors, focus and mode back.
	name: string,
	--- "tui", "gui", "headless" (the editor's own, with nothing attached) or "test".
	kind: string,
	--- Whether it came over `greed ssh`.
	remote: boolean,
	--- Its screen in cells, once it has said.
	size: { width: number, height: number }?,
	--- "follow": it shows the project, tab and panes the other followers do, with its own focus and zoom. "independent": a layout of its own.
	layout: "follow" | "independent",
	--- Which of the peer colors (1 to 6) its cursors show in for the other clients, as `ui.cursor.peer.N`.
	color: number,
	--- Who it belongs to: "owner", the session's owner, for now.
	person: string,
}

--- The clients you see the editor through. Commands, keys and event handlers act for one client at a time: the one that typed, clicked or ran them, or the one an event is about.
export type Client = {
	--- The client the running code acts for.
	current: () -> ClientInfo,
	--- The id of the client the running code acts for: `current().id`, without building the rest. For keeping what each client has open apart, like a picker of its own.
	id: () -> number,
	--- Every client, in the order they attached.
	list: () -> { ClientInfo },
	--- Sends a notification to your desktop through the acting client: a terminal shows it with its notification escape (OSC 9, or OSC 777 in foot and urxvt) and a bell, while it isn't focused. Without a client attached it goes nowhere.
	notify: (title: string, body: string?) -> (),
	--- Lays a client (the acting one by default) out on its own, "independent", starting from a copy of the tabs, panes and panels it had, with views of its own; or has it "follow" the others again, closing those views (their buffers stay). Returns whether it changed.
	set_layout: (layout: "follow" | "independent", client: number?) -> boolean,
}

--- A problem a language server found.
export type Diagnostic = {
	from: number,
	to: number,
	--- 1 error, 2 warning, 3 information, 4 hint.
	severity: number,
	message: string,
	source: string?,
}

--- The error a language server answered a request with.
export type LspError = {
	code: number,
	message: string,
	data: any?,
}

--- A position as language servers count it.
export type LspPosition = {
	line: number,
	character: number,
}

--- Language servers. A server runs per language and project root, started
--- the first time a file that needs it is open, and started again if it
--- stops.
export type Lsp = {
	--- Sets the server for a language, e.g.
	--- `{ language = "rust", command = { "rust-analyzer" }, root_markers = { "Cargo.toml" } }`.
	--- With `commands`, the first one whose program is installed runs, when
	--- a file of the language first opens; with none installed, nothing does.
	--- A server runs in the topmost folder with one of `root_markers` inside
	--- the file's project, or the project's root without one.
	server: (spec: { language: string, command: { string }?, commands: { { string } }?, root_markers: { string }? }) -> (),
	--- Stops starting a server for a language; one running keeps running.
	remove: (language: string) -> (),
	--- Stops the servers running for `language` (every language without one) and starts them again, as after they got stuck. Returns how many were running. Needs "proc".
	restart: (language: string?) -> number,
	--- The commands set for each language's server, by language.
	servers: () -> { [string]: { { string } } },
	--- The servers running now, by language and then root.
	running: () -> { LspServer },
	--- The folder the buffer's server runs in, or would: nil without a file or a server set for its language.
	root: (buffer: Buffer) -> string?,
	--- Sends a request to the buffer's server and waits for the answer.
	--- Returns the result, or nil and the error; a server that stops before
	--- answering gives the error "the language server stopped". Works in
	--- commands and event handlers. "workspace/executeCommand" needs "proc",
	--- since a server's commands can do anything.
	request: (buffer: Buffer, method: string, params: any) -> (any, LspError?),
	--- The buffer's file as a URI, for request parameters.
	uri: (buffer: Buffer) -> string,
	--- The file path in a `file://` URI.
	path: (uri: string) -> string?,
	--- Byte offset `pos` as the buffer's server counts positions.
	position: (buffer: Buffer, pos: number) -> LspPosition,
	--- The byte offset of a server position.
	offset: (buffer: Buffer, position: LspPosition) -> number,
	--- The buffer's latest diagnostics, where they are now: they move with
	--- edits. They are marks in the buffer's "diagnostics" namespace, with
	--- `{ severity, message, source }` as their data.
	diagnostics: (buffer: Buffer) -> { Diagnostic },
	--- Every file's latest problems, including files that aren't open, with
	--- ranges as the server counts positions. Those in open files are where
	--- they are now.
	problems: () -> { LspProblem },
	--- What the buffer's server said it can do (its `ServerCapabilities`),
	--- or nil without a running server.
	capabilities: (buffer: Buffer) -> any,
	--- Answers requests of `method` from servers, e.g. "workspace/applyEdit",
	--- with what `handler` returns. It can wait, e.g. to ask you; the server gets the answer when it returns.
	on_request: (method: string, handler: (params: any) -> any) -> (),
	--- Hears notifications of `method` from servers that the editor doesn't deal with itself, e.g. "$/progress", with the language and root of the server that sent it.
	on_notification: (method: string, handler: (params: any, language: string, root: string) -> ()) -> (),
}

--- A language server that's running.
export type LspServer = {
	language: string,
	--- The folder it runs in.
	root: string,
	command: { string },
	--- Whether it has answered `initialize`.
	ready: boolean,
	--- The last lines it wrote to stderr.
	stderr: { string },
}

export type LspProblem = {
	uri: string,
	range: { start: LspPosition, ["end"]: LspPosition },
	severity: number,
	message: string,
	source: string?,
}

export type DiagnosticsChanged = {
	buffer: Buffer,
}

--- A client's mode changed. Handlers run as that client.
export type ModeChanged = {
	client: number,
	from: string,
	to: string,
}

export type DirEntry = {
	name: string,
	dir: boolean,
}

export type FileInfo = {
	kind: "file" | "dir" | "other",
	--- Size in bytes; 0 for a directory.
	size: number,
	--- Its permission bits, like 420 (644 in octal, as `string.format("%o", mode)` shows).
	mode: number,
	--- When it last changed, in seconds since 1970, where the system says.
	modified: number?,
}

--- SHA-256 digests as lowercase hex, for checking a download or telling
--- whether some text changed, and random bytes for one-time codes.
export type Hash = {
	--- The digest of `data`.
	sha256: (data: string) -> string,
	--- `count` (1 to 1024) bytes from the system's random source, as lowercase hex: for a one-time code or a sign-in's PKCE verifier.
	random: (count: number) -> string,
	--- The digest of the file at `path`, read in pieces, or nil and why. Needs "fs.read".
	sha256_file: (path: string) -> (string?, string?),
}

--- Comparing values the way filters do, the same in a view's filter (`level>=warn`) and a table's `where` (`RESTARTS>0`): numbers as numbers, with sizes (`512Mi`, `1.5G`, `250m`), `%` and durations (`3d16h`, `500ms`); log levels in their order; anything else as text without minding case.
export type Compare = {
	--- `text` as a number: its first word, with a size suffix, a `%` or a duration in seconds; with `durations`, a lone `m` is minutes (an AGE column) rather than thousandths (kubectl's CPU). Nil when it isn't one.
	number: (text: string, durations: boolean?) -> number?,
	--- Whether `have` passes `op` (`=`, `!=`, `~` has it in it, `!~`, `<`, `<=`, `>`, `>=`) against `want`. `durations` defaults to whether `want` is one.
	test: (have: string, op: string, want: string, durations: boolean?) -> boolean,
	--- -1, 0 or 1 as `a` comes before, with or after `b`: numbers first, then log levels, then text.
	order: (a: string, b: string, durations: boolean?) -> number,
	--- Whether `text` is a duration with a unit only durations have (`45s`, `2h`, `3d`), so a column of them takes `12m` as minutes.
	is_duration: (text: string) -> boolean,
	--- The first operator in `text`: where it starts and ends (as `string.find` gives) and the operator. At one place, the longest (`<=`, not `<`).
	find: (text: string) -> (number?, number?, string?),
}

--- Reading lines of text as Greed does, so plugins read them the same way.
export type Text = {
	--- How far `line` is indented and the key it starts with (`name:` or `"name":`), as YAML, indented JSON and `kubectl describe` nest; nil for a blank line. With `items`, a list item's `- ` counts as indent, so `- name: x` is a key `name` two further in.
	shape: (line: string, items: boolean?) -> (number?, string?),
	--- How many cells `text` takes on screen from a line's start, as Greed draws it: wide characters (CJK, most emoji) take two, a tab reaches the next stop, `tab_width` (default 4) apart.
	width: (text: string, tab_width: number?) -> number,
}

--- Reading and writing the file system. Failures return nil and a message.
export type Fs = {
	--- The entries directly in `dir`, folders first, then by name. Hidden
	--- entries and ones `.gitignore` excludes are left out unless asked for.
	list: (dir: string, opts: { hidden: boolean?, ignored: boolean? }?) -> ({ DirEntry }?, string?),
	--- The file's text, or its first `limit` bytes.
	read: (path: string, limit: number?) -> (string?, string?),
	--- The file's bytes as they are, for a file that isn't text, like an image.
	read_bytes: (path: string) -> (string?, string?),
	--- What's at `path`; nil if nothing is, and nil and why when it can't tell, as when a folder above it can't be read.
	stat: (path: string) -> (FileInfo?, string?),
	--- Replaces the file's contents with `text`, creating it and its folders
	--- if needed. It's written whole or not at all. With `private`, only you
	--- can read it (mode 0600), and folders made for it are only yours.
	write: (path: string, text: string, opts: { private: boolean? }?) -> (boolean?, string?),
	--- Makes the folder at `path` and any missing folders above it. Needs "fs.write".
	mkdir: (path: string) -> (boolean?, string?),
	--- Removes the file, link or empty folder at `path`; with `recursive`, a folder and everything in it. Nothing being there counts as removed. It refuses (an error) the root, your home folder, a path with `..` and a folder holding Greed's approvals or secrets. Needs "fs.write".
	remove: (path: string, opts: { recursive: boolean? }?) -> (boolean?, string?),
	--- Moves or renames `from` to `to`, replacing a file there. It refuses what `remove` does. Needs "fs.write".
	rename: (from: string, to: string) -> (boolean?, string?),
	--- Copies the file `from` to `to`, creating its folders. Needs "fs.read" and "fs.write".
	copy: (from: string, to: string) -> (boolean?, string?),
	--- Watches the file at `path`: whenever it changes, from inside the
	--- editor or out, plugins hear "file.changed". It needn't exist yet.
	watch: (path: string) -> (),
	--- The directory Greed was started in.
	cwd: () -> string,
	--- Your home folder, Greed's config folder (where init.luau and plugins/
	--- were read from), its cache folder, its data folder (where plugins made in
	--- the editor go when the config can't be written) and, on the far end of
	--- greed ssh, the copy of your config it brought.
	dirs: () -> { home: string?, config: string?, cache: string?, data: string?, brought: string? },
	--- The lines matching the regex `pattern` in the text files under `dir`
	--- (default: the current directory), sorted by path and line. It searches
	--- in the background and waits like greed.sleep (commands, handlers, greed.spawn).
	--- Hidden and ignored files are skipped unless asked for; `limit`
	--- (default 10000) caps the lines returned. A bad pattern gives nil and
	--- why.
	grep: (
		pattern: string,
		dir: string?,
		opts: { hidden: boolean?, ignored: boolean?, limit: number? }?
	) -> ({ GrepLine }?, string?),
}

--- A line `greed.fs.grep` found.
export type GrepLine = {
	--- Relative to the directory searched.
	path: string,
	--- 0-based.
	line: number,
	--- The line, without its line break.
	text: string,
	--- Byte offsets of the matches in `text`.
	matches: { { from: number, to: number } },
}

--- What `greed.plugin.check` found. `types.skipped` says why types weren't
--- checked; `tests.error` why the tests couldn't run.
export type PluginCheck = {
	types: { ok: boolean?, output: string?, skipped: string? },
	tests: { passed: number?, failed: { { file: string, name: string, message: string } }?, error: string? },
	--- What looks wrong once it's loaded with the others: a command it replaces from another plugin, keys bound to commands that don't exist.
	warnings: { string },
}

export type Plugins = {
	--- The names of the loaded plugins, sorted.
	list: () -> { string },
	--- Removes a plugin and everything it registered: commands, keys,
	--- options and event handlers. Fails while another loaded plugin
	--- requires it. To turn off a default plugin, call this from your config.
	unload: (name: string) -> (),
	--- Loads (or reloads) the plugin in `dir` and returns its name. With
	--- `name`, a folder without a plugin.toml loads too, with init.luau as
	--- its entry.
	load: (dir: string, name: string?) -> string,
	--- The folder of each plugin loaded from one, by name.
	dirs: () -> { [string]: string },
	--- Checks the plugin in `dir` without loading it: strict types against
	--- Greed's API (if luau-analyze is installed), then its tests with the
	--- loaded plugins. Waits, like greed.sleep, while it runs. A plugin that
	--- needs approving is tested with only what you approved for it, so what
	--- needs more fails with "needs approval", through the plugins it
	--- calls and the commands it runs too.
	check: (dir: string) -> PluginCheck,
	--- What the plugin in `dir` is and asks for, from its plugin.toml.
	describe: (dir: string) -> PluginInfo,
	--- The plugins waiting until what they use is approved.
	pending: () -> { PluginInfo },
	--- Approves what the plugin in `dir` declares, loads it, and loads the plugins that waited for it. Returns its name. Fails when a plugin without "plugins" started what runs: approving is yours to do.
	approve: (dir: string) -> string,
	--- The plugin whose code called yours: the innermost other plugin on the stack, or the one whose command, handler or task is running; nil if none but yours.
	caller: () -> string?,
	--- Whether everything that started the code running now may use `capability`: you (keys, the command line, your config), or plugins that have it. A vouch doesn't hide what started it. For actions only you should take, like accepting a review.
	started_within: (capability: string) -> boolean,
	--- Runs `f` with `...` within the limit of the plugin `name` too, as if it had started it: for running what a plugin registered (a formatter, a runner, a source) later, from your plugin, so it can do no more than its plugin may. Config and unknown names add nothing. It can wait.
	within: <A..., R...>(name: string?, f: (A...) -> R..., A...) -> R...,
	--- For registries: runs `remove` when the plugin whose code called yours (see `caller`) is unloaded or reloaded, so what it added goes with it. Returns that plugin's name, or nil (and does nothing) if none but yours called.
	tie: (remove: () -> ()) -> string?,
}

--- A plugin, as `greed.plugin.describe` tells it, for a review.
export type PluginInfo = {
	name: string,
	dir: string,
	requires: { string },
	--- What it declares, each with what it lets the plugin do in words.
	capabilities: { { name: string, what: string } },
	--- The capabilities not approved yet; empty when it may load.
	missing: { string },
}

--- How text looks. Colors are "red", "bright-blue" and the other 16
--- terminal colors, "default", or "#rrggbb". Fields left out leave whatever
--- is underneath, so styles layer.
export type Style = {
	fg: string?,
	bg: string?,
	--- true, or "line", "curl", "dotted", "dashed" or "double".
	underline: (boolean | string)?,
	underline_color: string?,
	bold: boolean?,
	italic: boolean?,
	dim: boolean?,
	reverse: boolean?,
	strikethrough: boolean?,
	--- For floats in the window (`ui.float`, in its `gui` part): rounded corners and an outline instead of box lines, and a soft shadow.
	rounded: boolean?,
	shadow: boolean?,
	--- For text in the window: its background as a badge, a box with rounded corners a little inside its cells, as motion hints have.
	badge: boolean?,
	--- In the window, drawn as a control over the cells of its text: a checkbox ("empty" or "checked", for todos) or a choice ("choice" or "chosen"). Terminals show the text.
	checkbox: ("empty" | "checked" | "choice" | "chosen")?,
	--- The window's font for the text: "mono", the grid's (`gui-font`), or "prose", a proportional one (`gui-font-prose`) fitted into the same cells. Terminals have only the one.
	font: ("mono" | "prose")?,
}

--- A theme entry: a style for every client, with changes for the terminal
--- (`tui`) or a graphical client (`gui`).
export type ThemeEntry = Style & {
	tui: Style?,
	gui: Style?,
}

--- The tree-sitter queries each language uses: "highlights" for highlighting,
--- "injections" for languages inside others (code blocks in Markdown), and
--- others ("textobjects", ...) that plugins read. The languages plugin sets them
--- from the `queries/<language>/<kind>.scm` files in plugins and your config.
export type Syntax = {
	--- Sets the `kind` query for `language`, or with nil takes this plugin's away.
	--- Errors if the language's grammar can't compile it. The newest one set is
	--- used, and unloading a plugin takes its queries away.
	set_query: (language: string, kind: string, source: string?) -> (),
	--- The `kind` query in use for `language`: the one set, or for "highlights"
	--- and "injections" the one that comes with the grammar.
	query: (language: string, kind: string) -> string?,
	--- Loads the grammar for `language` from a WebAssembly file, like one built
	--- with `tree-sitter build --wasm`, so buffers in it get a syntax tree. `symbol`
	--- is the grammar's own name when it differs, e.g. "c_sharp" for "c-sharp";
	--- by default the language with "-" as "_". Queries come separately.
	--- Needs "fs.read".
	load_grammar: (language: string, path: string, symbol: string?) -> (),
	--- What the source files under `dir` (default: the current directory) define and use, from their syntax trees: the functions and types their "textobjects" query finds and how often each name appears, sorted by path. Hidden and ignored files are skipped; `limit` (default 10000) caps the files. It parses in the background and waits like greed.sleep. Needs "fs.read".
	tags: (dir: string?, opts: { limit: number? }?) -> { FileTags },
}

--- What one file defines and uses, from `greed.syntax.tags`.
export type FileTags = {
	--- Relative to the directory searched.
	path: string,
	language: string,
	--- Each with its 0-based line and its first line as `signature`.
	definitions: { { name: string, kind: "function" | "type", line: number, signature: string } },
	--- How often each name appears in the file.
	references: { [string]: number },
}

--- What style names look like. Everything on screen has one: "ui.text",
--- "ui.selection", "ui.statusline.mode", "ui.float.border", "keyword",
--- "diagnostic.error", or a name a plugin made up. Names fall back to their
--- parent, so "markup.heading.1" uses "markup.heading" if it has no entry.
export type Theme = {
	--- Sets entries by name. Each changes only the fields it gives of the
	--- theme's entry underneath, and replaces what was set for that name before.
	set: (entries: { [string]: ThemeEntry }) -> (),
	--- Replaces the base theme, the entries under those set with `set`: a
	--- theme plugin calls it to switch themes without touching what your
	--- config or other plugins set.
	base: (entries: { [string]: ThemeEntry }) -> (),
	--- The entry for exactly `name`, if there is one.
	get: (name: string) -> ThemeEntry?,
}

--- The events `greed.on` and `greed.off` take; any other name is an error.
export type EventName =
	| "mode.changed"
	| "buffer.changed"
	| "keys.pending"
	| "command.run"
	| "lsp.diagnostics"
	| "control.request"
	| "control.closed"
	| "client.attached"
	| "client.detached"
	| "client.paste"
	| "buffer.opened"
	| "buffer.saved"
	| "buffer.closed"
	| "view.closed"
	| "view.resized"
	| "pane.opened"
	| "view.scrolled"
	| "mouse"
	| "option.changed"
	| "plugin.loaded"
	| "file.changed"
	| "plugin.unloaded"
	| "editor.started"
	| "editor.quitting"
	| "terminal.output"
	| "terminal.exited"
	| "selection.changed"
	| "view.focused"
	| "ssh_agent.use"

export type Greed = {
	command: (spec: CommandSpec) -> (),
	--- Adds a command line command, `greed NAME ARGS`; see `CliSpec`.
	cli: (spec: CliSpec) -> (),
	--- Runs a command by name, optionally with arguments, `force` and a count.
	--- It returns once the command waits for something (a key, a prompt, a
	--- reply); with `wait`, a command or handler instead waits until it has
	--- finished, without blocking the editor. The command can do only what
	--- this plugin may too, unless it has "commands".
	run: (name: string, opts: { args: { string }?, force: boolean?, count: number?, wait: boolean? }?) -> (),
	--- Runs Luau code in a scratch environment whose globals persist, like a
	--- REPL. Returns true and the values as text (tab-separated), or false
	--- and the error. The code has every capability; calling it needs `eval`
	--- from every plugin involved. With `sandbox`, it runs in a fresh environment that can
	--- read the editor and edit buffers and nothing else: what it would do
	--- beyond that (run programs or commands, change keys, reach files) fails
	--- with an error starting "needs approval:".
	eval: (source: string, opts: { sandbox: boolean? }?) -> (boolean, string),
	--- Calls `handler` every time `event` happens, until `greed.off` removes
	--- it or the plugin unloads.
	on: ((event: "mode.changed", handler: (event: ModeChanged) -> ()) -> ())
		& ((event: "buffer.changed", handler: (event: BufferChanged) -> ()) -> ())
		& ((event: "keys.pending", handler: (event: KeysPending) -> ()) -> ())
		& ((event: "command.run", handler: (event: CommandRun) -> ()) -> ())
		& ((event: "lsp.diagnostics", handler: (event: DiagnosticsChanged) -> ()) -> ())
		& ((event: "control.request", handler: (event: ControlRequest) -> ()) -> ())
		& ((event: "control.closed", handler: (event: ControlClosed) -> ()) -> ())
		& ((event: "client.attached", handler: (event: ClientAttached) -> ()) -> ())
		& ((event: "client.detached", handler: (event: ClientDetached) -> ()) -> ())
		& ((event: "client.paste", handler: (event: ClientPaste) -> ()) -> ())
		& ((event: "buffer.opened", handler: (event: BufferChanged) -> ()) -> ())
		& ((event: "buffer.saved", handler: (event: BufferChanged) -> ()) -> ())
		& ((event: "buffer.closed", handler: (event: BufferClosed) -> ()) -> ())
		& ((event: "view.closed", handler: (event: ViewClosed) -> ()) -> ())
		& ((event: "view.resized", handler: (event: ViewResized) -> ()) -> ())
		& ((event: "pane.opened", handler: (event: PaneOpened) -> ()) -> ())
		& ((event: "view.scrolled", handler: (event: ViewScrolled) -> ()) -> ())
		& ((event: "selection.changed", handler: (event: SelectionChanged) -> ()) -> ())
		& ((event: "view.focused", handler: (event: ViewFocused) -> ()) -> ())
		& ((event: "ssh_agent.use", handler: (event: SshAgentUse) -> ()) -> ())
		& ((event: "mouse", handler: (event: MouseEvent) -> ()) -> ())
		& ((event: "option.changed", handler: (event: OptionChanged) -> ()) -> ())
		& ((event: "plugin.loaded", handler: (event: PluginLoaded) -> ()) -> ())
		& ((event: "file.changed", handler: (event: FileChanged) -> ()) -> ())
		& ((event: "plugin.unloaded", handler: (event: PluginUnloaded) -> ()) -> ())
		& ((event: "editor.started", handler: (event: {}) -> ()) -> ())
		& ((event: "editor.quitting", handler: (event: {}) -> ()) -> ())
		& ((event: "terminal.output", handler: (event: TerminalOutput) -> ()) -> ())
		& ((event: "terminal.exited", handler: (event: TerminalExited) -> ()) -> ()),
	--- Removes `handler`, added by this plugin with `greed.on(event, handler)`.
	--- Does nothing if it's not there.
	off: (event: EventName, handler: (event: any) -> ()) -> (),
	--- Shows a message to the user.
	echo: (...any) -> (),
	--- The last messages shown, oldest first and whole (the status line shows a message's first line).
	messages: () -> { string },
	--- The focused view; with an id (`view:id()`), that view, or nil when it's closed.
	view: (() -> View) & ((id: number) -> View?),
	--- Asks the editor to exit.
	quit: () -> (),
	--- How line numbers count, where buffers show them: each line's own
	--- number, "relative" to the cursor's line (0 on it), or "hybrid", relative
	--- with the cursor's line showing its own.
	line_numbers: (style: "absolute" | "relative" | "hybrid") -> (),
	--- When text hidden by marks whose `reveal` is "auto" shows: "line" (on a cursor's line, the default), "cursor" or "never", as for a mark's own `reveal`. Core sets it as the mode changes (see `core.reveal`).
	reveal: (how: "line" | "cursor" | "never") -> (),
	--- Lets the attached terminal go and keeps the editor running in the
	--- background, for `greed attach` to come back to.
	detach: () -> (),
	--- Waits `ms` milliseconds without blocking the editor. Works in commands
	--- and event handlers.
	sleep: (ms: number) -> (),
	--- Runs `f` on its own, the way a command runs, and returns at once: it can wait (greed.sleep, greed.process.run, ...) while the editor and the code that started it go on. For work in the background, like a status line piece refreshing.
	spawn: (f: (...any) -> ...any, ...any) -> (),
	--- Runs of plugin code that held the editor up (50 ms or more), newest first, for tracing a freeze to its plugin and what it was doing: a command's name, "the status line", "loading". `ms` is how long it took; `time` is when, in seconds since 1970 (as `os.time()` counts, with a fraction).
	stalls: () -> { { ms: number, plugin: string?, what: string, time: number } },
	--- Errors from plugin code that nothing caught (a command, an event handler or a task failing), newest first, up to 100: the plugin, what it ran ("on buffer.opened", a command's name), the message, where in its Luau it failed, and when, in seconds since 1970.
	errors: () -> { { plugin: string?, what: string, message: string, traceback: string, time: number } },
	--- Counting where the editor's time goes: every run of plugin code (each command, event handler, status line) and the editor's own work (handling a key, parsing, drawing), by plugin and what it did. `start` begins, `stop` ends and returns the rows, the most time first; `running` says whether one is being taken.
	profile: { start: () -> (), stop: () -> { ProfileRow }, running: () -> boolean },
	--- Debug lines and their topics, for seeing what the editor and plugins do: `:debug` and `:debug-log` use them.
	debug: Debug,
	--- Milliseconds on the editor's clock, for timing animations. While a
	--- timer wakes code, it reads the time the timer was due.
	now: () -> number,
	--- This machine's name, or nil if the system doesn't say.
	hostname: () -> string?,
	--- Calls `step(t)` about once a frame for `ms` milliseconds, with `t`
	--- going from 0 to 1, e.g. to fade a theme color or move a decoration.
	--- Works in commands and event handlers.
	animate: (ms: number, step: (t: number) -> ()) -> (),
	--- Waits for the next key press and returns its name, e.g. "g" or "ctrl-s".
	--- The key doesn't run anything. Works in commands and event handlers.
	next_key: () -> string,
	keys: Keys,
	process: Process,
	rpc: Rpc,
	http: Http,
	secrets: Secrets,
	terminal: Terminals,
	image: Images,
	scene: Scenes,
	pdf: Pdfs,
	--- A one-shot value that one piece of code waits for and another sends,
	--- e.g. a tool waiting for the user's review. `wait` works in commands and
	--- event handlers; a value sent before anyone waits is kept for them.
	signal: () -> Signal,
	--- Runs `f` with `...` as your plugin's own action: only your capabilities count for what it does, not those of the plugins whose code called you or started what runs. For services that check what they do themselves, like the models plugin sending a key only to its provider. Anything you vouch for, any plugin can make you do: vouch only for narrow, checked operations. It can wait.
	vouch: <A..., R...>(f: (A...) -> R..., A...) -> R...,
	--- Sets the function that builds the status line. It runs for every frame.
	statusline: (build: (ctx: StatusContext) -> StatusParts) -> (),
	--- Sets the function typed commands find an "object" argument with: the object of `kind` the user typed `text` for, or nil and why not. It runs in the command, so it can wait. The core plugin sets it from `core.objects`.
	object_finder: (find: (kind: string, text: string) -> (any, string?)) -> (),
	--- Sets the menus a window shows as its menu bar (on macOS, the system's), replacing those before; each item runs its command. The core plugin keeps them, so add to `require("@core").menus` rather than calling this.
	set_menus: (menus: { { title: string, items: { { label: string, command: string } } } }) -> (),
	--- A new buffer that isn't shown anywhere yet. It goes away when the last
	--- view showing it closes.
	create_buffer: (kind: string, text: string?, opts: { readonly: boolean?, language: string? }?) -> Buffer,
	--- The language of the file at `path`, by its name or extension.
	language_of: (path: string) -> string?,
	--- Makes files with these extensions (without the dot) or exact names, like
	--- "Makefile", be in `language`, replacing whatever it had before.
	filetype: (language: string, spec: { extensions: { string }?, names: { string }? }) -> (),
	--- The languages Greed has a grammar for, built in or loaded, sorted.
	grammars: () -> { string },
	--- Where `program` is on PATH, or nil if it isn't installed.
	which: (program: string) -> string?,
	--- Shows `buffer` in a view floating over the main one, and focuses it.
	float: (buffer: Buffer, spec: FloatSpec?) -> View,
	--- The floating views shown, the one in front last; with `hidden = true`, the hidden ones too.
	floats: (opts: { hidden: boolean? }?) -> { View },
	--- Shows `buffer` in a panel beside the main view, which gives up the
	--- room. Defaults: the left side, 30 cells wide, focused. Close it with
	--- `view:close()`.
	panel: (buffer: Buffer, spec: { side: ("left" | "right")?, width: (number | string)?, title: string?, focus: boolean? }?) -> View,
	--- Every open buffer.
	buffers: () -> { Buffer },
	--- The buffer with id `id` (`buffer:id()`), or nil when it's closed.
	buffer: (id: number) -> Buffer?,
	--- Opens a file in the main view.
	open: (path: string) -> (),
	--- The buffer for the file at `path`, opening it without showing it.
	load: (path: string) -> Buffer,
	--- The open buffer for the file at `path`, or nil when it isn't open; it
	--- doesn't open it. `~`, `.` and `..` are worked out and a relative path
	--- is from the folder Greed started in, so every spelling of a file
	--- finds its buffer.
	buffer_for: (path: string) -> Buffer?,
	--- The changes that turn `old` into `new`, whole lines at a time: each
	--- replaces `from`..`to` (byte offsets into `old`) with `text`. Sorted.
	diff: (old: string, new: string) -> { { from: number, to: number, text: string } },
	--- Every command, sorted by name.
	commands: () -> { CommandInfo },
	--- Every event handler, by event and then the order they were added.
	handlers: () -> { HandlerInfo },
	--- The 1-based indices of `items` that match `query`, best first. `case` says how it minds case: "smart" (the default: only when `query` has a capital letter), "ignore" or "match"; `core.search.case()` gives what the user chose.
	fuzzy: (query: string, items: { string }, opts: { case: ("smart" | "ignore" | "match")? }?) -> { number },
	--- The byte offsets of the characters in `text` that `query` matches,
	--- for highlighting them; empty if it doesn't match. `case` as for `fuzzy`.
	fuzzy_positions: (query: string, text: string, opts: { case: ("smart" | "ignore" | "match")? }?) -> { number },
	--- Files under `dir` (default: the current directory), skipping hidden
	--- and ignored files.
	files: (dir: string?) -> { string },
	keymap: Keymap,
	mode: Mode,
	option: Options,
	history: History,
	clipboard: Clipboard,
	--- Base64, as data goes in JSON, like an image for a model: `encode` takes bytes, `decode` gives them back, or nil for text that isn't base64.
	base64: { encode: (bytes: string) -> string, decode: (text: string) -> string? },
	client: Client,
	lsp: Lsp,
	fs: Fs,
	hash: Hash,
	compare: Compare,
	text: Text,
	control: Control,
	json: Json,
	project: Projects,
	tab: Tabs,
	session: Sessions,
	ssh_agent: SshAgent,
	plugin: Plugins,
	syntax: Syntax,
	theme: Theme,
}

return (nil :: any) :: Greed
