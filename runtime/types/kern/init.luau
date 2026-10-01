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
	--- The id of the project it was opened in.
	project: (self: Buffer) -> number?,
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
	--- Replaces the marks in namespace `ns` (pick one per plugin feature,
	--- e.g. "search"). Marks move with edits; `{}` clears them.
	decorate: (self: Buffer, ns: string, marks: { Mark }) -> (),
	--- The marks in namespace `ns`, where they are now.
	decorations: (self: Buffer, ns: string) -> { Mark },
	--- The first match of the regex `pattern` starting at or after `from`
	--- (default 0), or with `backward` the last one starting before it; `wrap`
	--- goes round the other end. Returns its start and end, nil when nothing
	--- matches, or nil and the error for a bad pattern.
	find: (self: Buffer, pattern: string, from: number?, opts: { backward: boolean?, wrap: boolean? }?) -> (number?, any),
	--- Every match of the regex `pattern` between `from` and `to` (default:
	--- the whole buffer), or nil and the error for a bad pattern.
	find_all: (self: Buffer, pattern: string, from: number?, to: number?) -> ({ { from: number, to: number } }?, string?),
}

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
	--- Draw over selections and cursors rather than under them.
	above: boolean?,
	--- Draw `text` over the characters from `from` instead of inserting it,
	--- like a jump label. The text doesn't move.
	overlay: boolean?,
}

--- A buffer shown on screen, with its own selection.
export type View = {
	id: (self: View) -> number,
	selection: (self: View) -> Selection,
	set_selection: (self: View, selection: Selection) -> (),
	--- The start and end of the text on screen when the view was last
	--- drawn, or of the whole buffer before that.
	visible: (self: View) -> (number, number),
	--- The 0-based line at the top of the view.
	scroll: (self: View) -> number,
	--- Scrolls so `line` is at the top. Drawing scrolls again if the primary
	--- cursor would be off screen, so move it first.
	set_scroll: (self: View, line: number) -> (),
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
	--- The number typed before the keys, in modes with counts on.
	count: number?,
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
	--- Makes digits typed before a key sequence in `mode` a count, which the
	--- command gets as `ctx.count`. A leading 0 stays a key.
	counts: (mode: string) -> (),
	--- Makes `mode` fall back to `parent`'s keys for sequences starting with
	--- one of `prefixes` (e.g. `{ "space", ":" }`), or for every key without
	--- them. Keys bound in `mode` itself come first.
	inherit: (mode: string, parent: string, prefixes: { string }?) -> (),
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
	--- Where the outside of the border goes, from the screen's left and top
	--- edges, in cells or like "50%". Left out, the float centers across and
	--- follows `anchor` up and down. It's always kept on screen.
	x: (number | string)?,
	y: (number | string)?,
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

--- A request from the session socket, e.g. from `kern ctl` or an agent.
--- Answer it with `kern.control.reply`.
export type ControlRequest = {
	id: number,
	--- "socket" for the session socket (kern ctl, kern mcp), "ide" for Claude
	--- Code's IDE connection.
	client: string,
	method: string,
	params: any,
}

export type Signal = {
	--- Waits until a value is sent, and returns it.
	wait: () -> any,
	--- Sends `value` to whoever waits. Only the first send counts.
	send: (value: any) -> (),
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

--- A session running on this machine: an editor process of its own.
export type SessionInfo = {
	name: string,
	--- The project it was started for.
	root: string?,
	--- Whether it's this session.
	current: boolean,
}

export type Sessions = {
	--- The sessions running on this machine, by name.
	list: () -> { SessionInfo },
	--- This session's name, when the editor runs as one.
	current: () -> string?,
	--- Sends the attached client to the session `name`, or to the session for
	--- the project `path` is in (opening it there), starting it if it isn't
	--- running. This session goes on without the client.
	switch: (to: { name: string?, path: string? }) -> (),
}

--- JSON. Tables with keys 1..n become arrays, other tables objects; an
--- empty table is an object unless it came from `array`.
export type Json = {
	encode: (value: any) -> string,
	--- The value, or nil and why the text isn't JSON. `null` becomes nil.
	decode: (text: string) -> (any, string?),
	--- Marks `items` (or a new table) to encode as an array even when empty.
	array: <T>(items: { T }?) -> { T },
}

export type Control = {
	--- Answers request `id` with `result`, or with an error `message`. Every
	--- request needs exactly one answer.
	reply: (id: number, result: any, message: string?) -> (),
	--- Lets Claude Code find this editor with /ide: listens on a localhost
	--- WebSocket and writes a lock file naming `folders` as open, in `lock_dir`
	--- (default ~/.claude/ide). Its requests come with client "ide". Returns
	--- the port; calling it again replaces the connection.
	serve_ide: (folders: { string }, lock_dir: string?) -> number,
	--- Sends a notification, e.g. "selection_changed", to Claude Code.
	notify: (method: string, params: any) -> (),
}

--- A client attached, e.g. `kern FILE` in a session that was running.
export type ClientAttached = {
	--- The file or folder it asked to open, if any.
	path: string?,
}

--- A view was closed. Its handle no longer works, but its id can be
--- compared with `view:id()`.
export type ViewClosed = {
	view: number,
}

--- An option was set, with `kern.option.set` or `:set`.
export type OptionChanged = {
	name: string,
	value: OptionValue,
}

--- A plugin was unloaded, and everything it registered removed.
export type PluginUnloaded = {
	name: string,
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
	read text: string,
	--- A style name, e.g. "ui.statusline.mode", drawn over "ui.statusline".
	read style: string?,
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
	--- With `commands`, the first one whose program is installed runs, when
	--- a file of the language first opens; with none installed, nothing does.
	server: (spec: { language: string, command: { string }?, commands: { { string } }?, root_markers: { string }? }) -> (),
	--- Stops starting a server for a language; one running keeps running.
	remove: (language: string) -> (),
	--- The commands set for each language's server, by language.
	servers: () -> { [string]: { { string } } },
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
	--- Replaces the file's contents with `text`, creating it and its folders
	--- if needed.
	write: (path: string, text: string) -> (boolean?, string?),
	--- The directory Kern was started in.
	cwd: () -> string,
	--- Your home folder, Kern's config folder (where init.luau and plugins/
	--- were read from) and its cache folder.
	dirs: () -> { home: string?, config: string?, cache: string? },
	--- The lines matching the regex `pattern` in the text files under `dir`
	--- (default: the current directory), sorted by path and line. In a
	--- command it searches in the background and waits, like kern.sleep.
	--- Hidden and ignored files are skipped unless asked for; `limit`
	--- (default 10000) caps the lines returned. A bad pattern gives nil and
	--- why.
	grep: (
		pattern: string,
		dir: string?,
		opts: { hidden: boolean?, ignored: boolean?, limit: number? }?
	) -> ({ GrepLine }?, string?),
}

--- A line `kern.fs.grep` found.
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

--- What `kern.plugin.check` found. `types.skipped` says why types weren't
--- checked; `tests.error` why the tests couldn't run.
export type PluginCheck = {
	types: { ok: boolean?, output: string?, skipped: string? },
	tests: { passed: number?, failed: { { file: string, name: string, message: string } }?, error: string? },
}

export type Plugins = {
	--- The names of the loaded plugins, sorted.
	list: () -> { string },
	--- Removes a plugin and everything it registered: commands, keys,
	--- options and event handlers. Fails while another loaded plugin
	--- requires it. To turn off a default plugin, call this from your config.
	unload: (name: string) -> (),
	--- Loads (or reloads) the plugin in `dir` and returns its name.
	load: (dir: string) -> string,
	--- The folder of each plugin loaded from one, by name.
	dirs: () -> { [string]: string },
	--- Checks the plugin in `dir` without loading it: strict types against
	--- Kern's API (if luau-analyze is installed), then its tests with the
	--- loaded plugins. Waits, like kern.sleep, while it runs.
	check: (dir: string) -> PluginCheck,
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
}

--- A theme entry: a style for every surface, with changes for the terminal
--- (`tui`) or a graphical client (`gui`).
export type ThemeEntry = Style & {
	tui: Style?,
	gui: Style?,
}

--- What style names look like. Everything on screen has one: "ui.text",
--- "ui.selection", "ui.statusline.mode", "ui.float.border", "keyword",
--- "diagnostic.error", or a name a plugin made up. Names fall back to their
--- parent, so "markup.heading.1" uses "markup.heading" if it has no entry.
export type Theme = {
	--- Sets entries by name, replacing any with the same name.
	set: (entries: { [string]: ThemeEntry }) -> (),
	--- The entry for exactly `name`, if there is one.
	get: (name: string) -> ThemeEntry?,
}

export type Kern = {
	command: (spec: CommandSpec) -> (),
	--- Runs a command by name, optionally with arguments, `force` and a count.
	run: (name: string, opts: { args: { string }?, force: boolean?, count: number? }?) -> (),
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
		& ((event: "control.request", handler: (event: ControlRequest) -> ()) -> ())
		& ((event: "client.attached", handler: (event: ClientAttached) -> ()) -> ())
		& ((event: "view.closed", handler: (event: ViewClosed) -> ()) -> ())
		& ((event: "option.changed", handler: (event: OptionChanged) -> ()) -> ())
		& ((event: "plugin.unloaded", handler: (event: PluginUnloaded) -> ()) -> ())
		& ((event: string, handler: (event: any) -> ()) -> ()),
	--- Shows a message to the user.
	echo: (...any) -> (),
	--- The focused view.
	view: () -> View,
	--- Asks the editor to exit.
	quit: () -> (),
	--- Lets the attached terminal go and keeps the editor running in the
	--- background, for `kern attach` to come back to.
	detach: () -> (),
	--- Waits `ms` milliseconds without blocking the editor. Works in commands
	--- and event handlers.
	sleep: (ms: number) -> (),
	--- Milliseconds on the editor's clock, for timing animations. While a
	--- timer wakes code, it reads the time the timer was due.
	now: () -> number,
	--- Calls `step(t)` about once a frame for `ms` milliseconds, with `t`
	--- going from 0 to 1, e.g. to fade a theme color or move a decoration.
	--- Works in commands and event handlers.
	animate: (ms: number, step: (t: number) -> ()) -> (),
	--- Waits for the next key press and returns its name, e.g. "g" or "ctrl-s".
	--- The key doesn't run anything. Works in commands and event handlers.
	next_key: () -> string,
	--- A one-shot value that one piece of code waits for and another sends,
	--- e.g. a tool waiting for the user's review. `wait` works in commands and
	--- event handlers; a value sent before anyone waits is kept for them.
	signal: () -> Signal,
	--- Sets the function that builds the status line. It runs for every frame.
	statusline: (build: (ctx: StatusContext) -> StatusParts) -> (),
	--- A new buffer that isn't shown anywhere yet. It goes away when the last
	--- view showing it closes.
	create_buffer: (kind: string, text: string?, opts: { readonly: boolean?, language: string? }?) -> Buffer,
	--- The language of the file at `path`, by its name or extension.
	language_of: (path: string) -> string?,
	--- Makes files with these extensions (without the dot) or exact names, like
	--- "Makefile", be in `language`, replacing whatever it had before.
	filetype: (language: string, spec: { extensions: { string }?, names: { string }? }) -> (),
	--- The languages Kern has syntax highlighting for, sorted.
	grammars: () -> { string },
	--- Where `program` is on PATH, or nil if it isn't installed.
	which: (program: string) -> string?,
	--- Shows `buffer` in a view floating over the main one, and focuses it.
	float: (buffer: Buffer, spec: FloatSpec?) -> View,
	--- Shows `buffer` in a panel beside the main view, which gives up the
	--- room. Defaults: the left side, 30 cells wide, focused. Close it with
	--- `view:close()`.
	panel: (buffer: Buffer, spec: { side: ("left" | "right")?, width: (number | string)?, title: string?, focus: boolean? }?) -> View,
	--- Every open buffer.
	buffers: () -> { Buffer },
	--- Opens a file in the main view.
	open: (path: string) -> (),
	--- The buffer for the file at `path`, opening it without showing it.
	load: (path: string) -> Buffer,
	--- The changes that turn `old` into `new`, whole lines at a time: each
	--- replaces `from`..`to` (byte offsets into `old`) with `text`. Sorted.
	diff: (old: string, new: string) -> { { from: number, to: number, text: string } },
	--- Every command, sorted by name.
	commands: () -> { CommandInfo },
	--- The 1-based indices of `items` that match `query`, best first.
	fuzzy: (query: string, items: { string }) -> { number },
	--- The byte offsets of the characters in `text` that `query` matches,
	--- for highlighting them; empty if it doesn't match.
	fuzzy_positions: (query: string, text: string) -> { number },
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
	control: Control,
	json: Json,
	project: Projects,
	session: Sessions,
	plugin: Plugins,
	theme: Theme,
}

return (nil :: any) :: Kern
