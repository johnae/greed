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
	--- Sets the selection after the edit (of every view showing the buffer,
	--- when the buffer didn't come from a view). Without this, the current
	--- selection is moved along with the text.
	select: (self: Edits, selection: Selection) -> (),
}

--- Open text, backed by a file or not.
export type Buffer = {
	id: (self: Buffer) -> number,
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
	--- The start and end of the sentence around `pos`, without the spaces
	--- after it. Sentences end at blank lines.
	sentence: (self: Buffer, pos: number) -> (number, number),
	--- What the buffer is: "file", "terminal", ...
	kind: (self: Buffer) -> string,
	path: (self: Buffer) -> string?,
	--- True if only plugins can change the text: edits from keys and undo
	--- are refused.
	readonly: (self: Buffer) -> boolean,
	set_readonly: (self: Buffer, readonly: boolean) -> (),
	--- The language the text is highlighted as, e.g. "rust".
	language: (self: Buffer) -> string?,
	--- Sets the language, or with nil goes back to the one the file's
	--- extension implies.
	set_language: (self: Buffer, language: string?) -> (),
	--- Edits the buffer: `f` records edits on `e`, and they are applied
	--- together, as one undoable change, when it returns.
	edit: (self: Buffer, f: (e: Edits) -> ()) -> (),
	--- Writes the buffer to its file, or to `path`, which becomes its file.
	save: (self: Buffer, path: string?) -> (),
	--- True if the text changed since it was opened or last saved.
	modified: (self: Buffer) -> boolean,
}

--- A buffer shown on screen, with its own selection.
export type View = {
	id: (self: View) -> number,
	selection: (self: View) -> Selection,
	set_selection: (self: View, selection: Selection) -> (),
	buffer: (self: View) -> Buffer,
	--- Shows another buffer in this view.
	show: (self: View, buffer: Buffer) -> (),
	--- Focuses this view, so keys go to it.
	focus: (self: View) -> (),
	--- Closes the view. The main view can't be closed; returns false for it.
	close: (self: View) -> boolean,
	--- Changes how a floating view is shown; fields left out stay as they
	--- are. Fails for views that aren't floating.
	configure: (self: View, spec: FloatSpec) -> (),
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
	--- Arguments, e.g. from the command line; empty when a key ran it.
	args: { string },
	--- Go ahead even if the command would normally refuse, like `:q!`
	--- quitting with unsaved changes.
	force: boolean,
}

--- An argument a command takes, for completion and help.
export type ArgSpec = {
	name: string,
	doc: string?,
	--- What completes it, e.g. "file", "command", "option" or "buffer".
	complete: string?,
}

export type CommandSpec = {
	--- Plain words with dashes, e.g. "select-line".
	name: string,
	doc: string?,
	args: { ArgSpec }?,
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
	--- Hides what each key sequence runs in `layer`, e.g. `{ "w", "g g" }`.
	--- Removing (or reloading) the plugin that unbound them brings them back.
	unbind: (layer: string | Layer, keys: { string }) -> (),
	--- Hides everything bound in `layer` so far, to start it over. Bindings
	--- made afterwards, by any plugin, apply as usual.
	clear: (layer: string | Layer) -> (),
	--- The command that handles a single unbound key in `mode`.
	fallback: (mode: string, command: string) -> (),
	--- The keys that can follow `keys` (e.g. "space") in the current mode, and
	--- the command each runs. Keys without a command start longer sequences.
	next: (keys: string?) -> { { key: string, command: string? } },
	--- Every key sequence that runs `command`, and the layer it's bound in
	--- (a mode name, or "global").
	find: (command: string) -> { { layer: string, keys: string } },
	--- What `keys` runs in the current mode: the command, or nil and whether
	--- more keys could still finish a sequence.
	resolve: (keys: string) -> (string?, boolean),
}

export type Mode = {
	get: () -> string,
	--- Switches mode, emitting "mode.changed" if it changed.
	set: (name: string) -> (),
	--- How the cursor looks in `mode`; modes without a shape get a block.
	cursor: (mode: string, shape: "block" | "bar" | "underline") -> (),
}

export type OptionValue = boolean | number | string

export type Options = {
	define: (spec: { name: string, doc: string?, default: OptionValue }) -> (),
	get: (name: string) -> OptionValue?,
	set: (name: string, value: OptionValue) -> (),
	--- Every option, sorted by name.
	list: () -> { { name: string, doc: string, value: OptionValue } },
}

export type History = {
	--- Edits until `end_group` become one undo step.
	start_group: () -> (),
	end_group: () -> (),
}

--- How a floating view looks. Sizes are cells, or a string like "60%";
--- both default to "60%".
export type FloatSpec = {
	title: string?,
	width: (number | string)?,
	height: (number | string)?,
	anchor: ("center" | "top" | "bottom")?,
	--- Whether the view takes focus. Defaults to true.
	focus: boolean?,
}

export type CommandInfo = {
	name: string,
	doc: string,
	args: { ArgSpec },
	--- The plugin that defined it.
	owner: string,
	--- Where it was defined, e.g. "core/motions.luau:120".
	source: string?,
	--- The file and line it was defined on, when that file is on disk.
	path: string?,
	line: number?,
}

export type BufferChanged = {
	buffer: Buffer,
}

export type CommandRun = {
	--- The command about to run.
	name: string,
}

export type KeysPending = {
	--- The unfinished key sequence, e.g. "space"; "" once it's finished.
	keys: string,
}

--- A piece of the status line: plain text, or text with a style.
export type StatusSegment = string | {
	text: string,
	style: ("status" | "mode" | "message")?,
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

--- A position as language servers count it.
export type LspPosition = {
	line: number,
	character: number,
}

--- Language servers. Servers start the first time a file of their language
--- is open.
export type Lsp = {
	--- Sets the server for a language, e.g.
	--- `{ language = "rust", command = { "rust-analyzer" }, root_markers = { "Cargo.toml" } }`.
	server: (spec: { language: string, command: { string }, root_markers: { string }? }) -> (),
	--- Sends a request to the buffer's server and waits for the answer.
	--- Returns the result, or nil and the error. Works in commands and event
	--- handlers.
	request: (buffer: Buffer, method: string, params: any) -> (any, any),
	--- The buffer's file as a URI, for request parameters.
	uri: (buffer: Buffer) -> string,
	--- The file path in a `file://` URI.
	path: (uri: string) -> string?,
	--- Byte offset `pos` as the buffer's server counts positions.
	position: (buffer: Buffer, pos: number) -> LspPosition,
	--- The byte offset of a server position.
	offset: (buffer: Buffer, position: LspPosition) -> number,
	--- The buffer's latest diagnostics.
	diagnostics: (buffer: Buffer) -> { Diagnostic },
}

export type DiagnosticsChanged = {
	buffer: Buffer,
}

export type ModeChanged = {
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
}

--- Reading the file system. Failures return nil and a message.
export type Fs = {
	--- The entries directly in `dir`, folders first, then by name. Hidden
	--- entries and ones `.gitignore` excludes are left out unless asked for.
	list: (dir: string, opts: { hidden: boolean?, ignored: boolean? }?) -> ({ DirEntry }?, string?),
	--- The file's text, or its first `limit` bytes.
	read: (path: string, limit: number?) -> (string?, string?),
	--- What's at `path`, or nil if nothing is.
	stat: (path: string) -> FileInfo?,
}

export type Kern = {
	command: (spec: CommandSpec) -> (),
	--- Runs a command by name, optionally with arguments and `force`.
	run: (name: string, opts: { args: { string }?, force: boolean? }?) -> (),
	--- Runs Luau code in a scratch environment whose globals persist, like a
	--- REPL. Returns true and the values as text (tab-separated), or false
	--- and the error.
	eval: (source: string) -> (boolean, string),
	--- Calls `handler` every time `event` happens.
	on: ((event: "mode.changed", handler: (event: ModeChanged) -> ()) -> ())
		& ((event: "buffer.changed", handler: (event: BufferChanged) -> ()) -> ())
		& ((event: "keys.pending", handler: (event: KeysPending) -> ()) -> ())
		& ((event: "command.run", handler: (event: CommandRun) -> ()) -> ())
		& ((event: "lsp.diagnostics", handler: (event: DiagnosticsChanged) -> ()) -> ())
		& ((event: string, handler: (event: any) -> ()) -> ()),
	--- Shows a message to the user.
	echo: (...any) -> (),
	--- The focused view.
	view: () -> View,
	--- Asks the editor to exit.
	quit: () -> (),
	--- Waits `ms` milliseconds without blocking the editor. Works in commands
	--- and event handlers.
	sleep: (ms: number) -> (),
	--- Waits for the next key press and returns its name, e.g. "g" or "ctrl-s".
	--- The key doesn't run anything. Works in commands and event handlers.
	next_key: () -> string,
	--- Sets the function that builds the status line. It runs for every frame.
	statusline: (build: (ctx: StatusContext) -> StatusParts) -> (),
	--- A new buffer that isn't shown anywhere yet. It goes away when the last
	--- view showing it closes.
	create_buffer: (kind: string, text: string?, opts: { readonly: boolean?, language: string? }?) -> Buffer,
	--- The language of the file at `path`, going by its extension.
	language_of: (path: string) -> string?,
	--- Shows `buffer` in a view floating over the main one, and focuses it.
	float: (buffer: Buffer, spec: FloatSpec?) -> View,
	--- Every open buffer.
	buffers: () -> { Buffer },
	--- Opens a file in the main view.
	open: (path: string) -> (),
	--- Every command, sorted by name.
	commands: () -> { CommandInfo },
	--- The 1-based indices of `items` that match `query`, best first.
	fuzzy: (query: string, items: { string }) -> { number },
	--- Files under `dir` (default: the current directory), skipping hidden
	--- and ignored files.
	files: (dir: string?) -> { string },
	keymap: Keymap,
	mode: Mode,
	option: Options,
	history: History,
	clipboard: Clipboard,
	lsp: Lsp,
	fs: Fs,
}

return (nil :: any) :: Kern
