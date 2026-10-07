--- The test API, for files in a plugin's `test/` directory, through
--- `require("@greed/test")`. Run tests with `greed test PLUGIN_DIR`.
---
--- Buffers are written with markers: `|` at each cursor or selection head,
--- and `^` at the anchor of a selection. "^hello |world" selects "hello ".

export type TestContext = {
	--- Shows a fresh buffer in the main view, in the helix style's normal mode.
	buffer: (self: TestContext, marked: string) -> (),
	--- Presses keys, e.g. "g g" or "i h i esc".
	keys: (self: TestContext, keys: string) -> (),
	--- Runs a command, with arguments as from the command line, and waits
	--- for any background work it starts.
	run: (self: TestContext, command: string, args: { string }?) -> (),
	--- Lets `ms` milliseconds pass for commands waiting on greed.sleep.
	wait: (self: TestContext, ms: number) -> (),
	--- Waits, for real, until `done` returns true, passing on terminal
	--- output as it comes; fails after `ms` milliseconds (default 5000).
	wait_for: (self: TestContext, done: () -> boolean, ms: number?) -> (),
	--- A new, empty directory holding `files` (paths in it, to their text).
	--- Folders in the paths are created.
	tempdir: (self: TestContext, files: { [string]: string }?) -> string,
	--- The buffer with markers.
	marked: (self: TestContext) -> string,
	--- The text of each floating view, bottom first.
	floats: (self: TestContext) -> { string },
	--- The left and right sides of the status line a plugin builds, as text.
	status: (self: TestContext) -> (string?, string?),
	--- Lays the editor out on a `width` by `height` screen, as a client would
	--- draw it, and returns the rows as text, the status line last. Views
	--- drawn at a new size send "view.resized".
	draw: (self: TestContext, width: number, height: number) -> { string },
	--- As `draw`, but the whole screen as a terminal shows it: floats over
	--- the panes, with their borders.
	screen: (self: TestContext, width: number, height: number) -> { string },
	--- Does what a client sends for the mouse at screen cell (`col`, `row`),
	--- against the last `draw`: `kind` is "press", "release", "drag",
	--- "move" or "scroll", `which` a button (default "left") or a scroll
	--- direction, and `mods` the keys held with it.
	mouse: (self: TestContext, kind: string, col: number, row: number, which: string?, mods: { ctrl: boolean?, alt: boolean?, shift: boolean? }?) -> (),
	--- True once something asked the editor to exit.
	quitting: (self: TestContext) -> boolean,
	--- True if something asked to let the client go since the last call.
	detached: (self: TestContext) -> boolean,
	--- Where something asked to send the client since the last call, if
	--- anywhere.
	switched: (self: TestContext) -> { session: string?, path: string? }?,
	--- Messages shown since the last call, oldest first. Notices of code that held the editor up aren't among them, since they depend on how busy the machine is; `greed.stalls()` lists those.
	messages: (self: TestContext) -> { string },
	--- Desktop notifications sent with `greed.client.notify` since the last call, oldest first.
	notices: (self: TestContext) -> { { title: string, body: string } },
	--- Fails unless the buffer, with markers, is `marked`.
	expect: (self: TestContext, marked: string) -> (),
	expect_mode: (self: TestContext, mode: string) -> (),
}

--- Declares a test. Each test runs in a fresh editor.
return (nil :: any) :: (name: string, body: (t: TestContext) -> ()) -> ()
