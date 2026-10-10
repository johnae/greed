--- The test API, for files in a plugin's `test/` directory, through
--- `require("@greed/test")`. Run tests with `greed test PLUGIN_DIR`.
---
--- Buffers are written with markers: `|` at each cursor or selection head,
--- and `^` at the anchor of a selection. "^hello |world" selects "hello ".

--- Another client, from `t:client`: what it does and sees, as `t`'s
--- methods of the same names do for the first client.
export type TestClient = {
	--- Its id, as `greed.client.current().id` gives it to code running as it.
	id: (self: TestClient) -> number,
	keys: (self: TestClient, keys: string) -> (),
	--- Types `text` as keys, a character at a time, newlines as enter.
	type: (self: TestClient, text: string) -> (),
	run: (self: TestClient, command: string, args: { string }?) -> (),
	mouse: (self: TestClient, kind: string, col: number, row: number, which: string?, mods: { ctrl: boolean?, alt: boolean?, shift: boolean? }?) -> (),
	draw: (self: TestClient, width: number, height: number) -> { string },
	screen: (self: TestClient, width: number, height: number) -> { string },
	status: (self: TestClient) -> (string?, string?),
	marked: (self: TestClient) -> string,
	expect: (self: TestClient, marked: string) -> (),
	expect_mode: (self: TestClient, mode: string) -> (),
}

export type TestContext = {
	--- Shows a fresh buffer in the main view, in the helix style's normal mode.
	buffer: (self: TestContext, marked: string) -> (),
	--- Another client, as if one attached, seeing what the first one does: the same views, selections and mode. `t`'s own methods act as the first client. `name` defaults to "test N", and `kind`, what `greed.client.current().kind` says, to "test" ("gui" for a window).
	client: (self: TestContext, name: string?, kind: string?) -> TestClient,
	--- Presses keys, e.g. "g g" or "i h i esc".
	keys: (self: TestContext, keys: string) -> (),
	--- Types `text` as keys, a character at a time, newlines as enter: `t:keys("i")` then `t:type("hello world")`.
	type: (self: TestContext, text: string) -> (),
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
	--- Opens a file in a tempdir, as greed.open does (firing "buffer.opened"),
	--- without the plugin needing the fs.read capability for it.
	open: (self: TestContext, path: string) -> (),
	--- A new jj or git repository in a tempdir, with `files` committed as
	--- "first" if given, and a way to run jj or git there as a made-up user:
	--- it returns what the command printed and fails the test if it fails.
	repo: (self: TestContext, kind: "jj" | "git", files: { [string]: string }?) -> (string, (...string) -> string),
	--- Runs jj or git in `dir` as `repo`'s function does, for repositories
	--- laid out some other way.
	vcs: (self: TestContext, kind: "jj" | "git", dir: string) -> (...string) -> string,
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
	switched: (self: TestContext) -> { session: string?, path: string?, host: string? }?,
	--- Messages shown since the last call, oldest first. Notices of code that held the editor up aren't among them, since they depend on how busy the machine is; `greed.stalls()` lists those.
	messages: (self: TestContext) -> { string },
	--- Desktop notifications sent with `greed.client.notify` since the last call, oldest first.
	notices: (self: TestContext) -> { { title: string, body: string } },
	--- Makes `greed.clipboard.image()` give `png` from now on, as if a client read it from its clipboard; nil says there's none.
	clipboard_image: (self: TestContext, png: string?) -> (),
	--- Fails unless the buffer, with markers, is `marked`.
	expect: (self: TestContext, marked: string) -> (),
	expect_mode: (self: TestContext, mode: string) -> (),
}

--- Declares a test. Each test runs in a fresh editor.
return (nil :: any) :: (name: string, body: (t: TestContext) -> ()) -> ()
