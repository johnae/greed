--- The test API, for files in a plugin's `test/` directory, through
--- `require("@kern/test")`. Run tests with `kern test PLUGIN_DIR`.
---
--- Buffers are written with markers: `|` at each cursor or selection head,
--- and `^` at the anchor of a selection. "^hello |world" selects "hello ".

export type TestContext = {
	--- Shows a fresh buffer in the main view, in normal mode.
	buffer: (self: TestContext, marked: string) -> (),
	--- Presses keys, e.g. "g g" or "i h i esc".
	keys: (self: TestContext, keys: string) -> (),
	run: (self: TestContext, command: string) -> (),
	--- Lets `ms` milliseconds pass for commands waiting on kern.sleep.
	wait: (self: TestContext, ms: number) -> (),
	--- The buffer with markers.
	marked: (self: TestContext) -> string,
	--- The text of each floating view, bottom first.
	floats: (self: TestContext) -> { string },
	--- The left and right sides of the status line a plugin builds, as text.
	status: (self: TestContext) -> (string?, string?),
	--- Fails unless the buffer, with markers, is `marked`.
	expect: (self: TestContext, marked: string) -> (),
	expect_mode: (self: TestContext, mode: string) -> (),
}

--- Declares a test. Each test runs in a fresh editor.
return (nil :: any) :: (name: string, body: (t: TestContext) -> ()) -> ()
