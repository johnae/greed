--- The Kern API, as seen by plugins through `require("@kern")`.
---
--- This file only describes types, for `luau-analyze` and `luau-lsp`; the
--- editor provides the real module. Positions are 0-based byte offsets and
--- lines are 0-based, like LSP.

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
	--- Sets the selection after the edit. Without this, the current
	--- selection is moved along with the text.
	select: (self: Edits, selection: Selection) -> (),
}

--- Open text, backed by a file or not.
export type Buffer = {
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
	--- The character at `pos`, or nil at the end of the buffer.
	char_at: (self: Buffer, pos: number) -> string?,
	next_char: (self: Buffer, pos: number) -> number,
	prev_char: (self: Buffer, pos: number) -> number,
	--- What the buffer is: "file", "terminal", ...
	kind: (self: Buffer) -> string,
	path: (self: Buffer) -> string?,
	--- Edits the buffer: `f` records edits on `e`, and they are applied
	--- together, as one undoable change, when it returns.
	edit: (self: Buffer, f: (e: Edits) -> ()) -> (),
	--- Writes the buffer to its file.
	save: (self: Buffer) -> (),
}

--- A buffer shown on screen, with its own selection.
export type View = {
	id: (self: View) -> number,
	selection: (self: View) -> Selection,
	set_selection: (self: View, selection: Selection) -> (),
	buffer: (self: View) -> Buffer,
	--- Undoes the last change. Returns false if there was nothing to undo.
	undo: (self: View) -> boolean,
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
}

export type CommandSpec = {
	--- Plain words with dashes, e.g. "select-line".
	name: string,
	doc: string?,
	run: (ctx: Context) -> (),
}

--- A keymap layer. Leave `mode` or `kind` out to match any.
export type Layer = {
	mode: string?,
	kind: string?,
}

export type Keymap = {
	--- Binds key sequences to command names, e.g. `{ ["g g"] = "goto-start" }`.
	--- `layer` is a mode name or a `Layer`.
	bind: (layer: string | Layer, bindings: { [string]: string }) -> (),
	--- The command that handles a single unbound key in `mode`.
	fallback: (mode: string, command: string) -> (),
}

export type Mode = {
	get: () -> string,
	--- Switches mode, emitting "mode.changed" if it changed.
	set: (name: string) -> (),
}

export type OptionValue = boolean | number | string

export type Options = {
	define: (spec: { name: string, doc: string?, default: OptionValue }) -> (),
	get: (name: string) -> OptionValue?,
	set: (name: string, value: OptionValue) -> (),
}

export type History = {
	--- Edits until `end_group` become one undo step.
	start_group: () -> (),
	end_group: () -> (),
}

export type ModeChanged = {
	from: string,
	to: string,
}

export type Kern = {
	command: (spec: CommandSpec) -> (),
	--- Runs a command by name.
	run: (name: string) -> (),
	--- Calls `handler` every time `event` happens.
	on: ((event: "mode.changed", handler: (event: ModeChanged) -> ()) -> ())
		& ((event: string, handler: (event: any) -> ()) -> ()),
	--- Shows a message to the user.
	echo: (...any) -> (),
	--- The focused view.
	view: () -> View,
	--- Asks the editor to exit.
	quit: () -> (),
	keymap: Keymap,
	mode: Mode,
	option: Options,
	history: History,
}

return (nil :: any) :: Kern
