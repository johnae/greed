//! Nothing a plugin passes the API may panic the editor: every method of
//! every handle is called with nonsense (negative, NaN, huge and past-end
//! positions, bad UTF-8, wrong types, closed handles) and must answer with
//! a value or an error. The screen is then drawn at odd sizes, since bad
//! input that got stored shows up there.

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::time::Duration;

use greed_core::Editor;
use greed_core::luau::Host;
use greed_core::render::{CellWidth, Plain, Renderer, Size, Status};
use greed_text::ClientId;

/// Text with multi-byte characters, so most small offsets fall inside one.
const TEXT: &str = "fn héllo() {\n\t日本語 = 1;\n}\n\nwörld 🎉 end";

fn types() -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../runtime/types/greed/init.luau");
    std::fs::read_to_string(path).unwrap()
}

/// Field names declared in `export type <name> = { ... }`.
fn declared(types: &str, name: &str) -> Vec<String> {
    let start = format!("export type {name} = {{");
    types
        .lines()
        .skip_while(|line| *line != start)
        .skip(1)
        .take_while(|line| *line != "}")
        .filter_map(|line| {
            let field = line.trim().split_once(':')?.0;
            field
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_')
                .then(|| field.to_owned())
        })
        .collect()
}

fn host() -> Host {
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", TEXT, None);
    let host = Host::new(editor).unwrap();
    host.set_budget(Duration::from_secs(600));
    host
}

/// Values and argument lists the fuzzer draws from, and `fuzz(label,
/// make, names)`, which calls each method in `names` of a fresh object from
/// `make` with each argument list. `LAST` says which call ran last.
const FUZZ: &str = r#"
greed = require("@greed")
local TEXT = ...
MADE = {}
local nums = { 0, 1, 2, 3, 5, -1, -2, 1e9, -1e9, 0 / 0, math.huge, -math.huge, 2 ^ 53, 2 ^ 63, -2 ^ 63, 0.5, 4294967296, 65536 }
local function closer(): nil
	for _, b in greed.buffers() do pcall(b.close, b) end
	for _, b in MADE do pcall(b.close, b) end
	table.clear(MADE)
	for _, f in greed.floats() do pcall(f.close, f) end
	return nil
end
local others = {
	"", "x", "\255\254", "é", "日本", "a\0b", string.rep("x", 300), "rust", "line", "(", true, false, {},
	{ anchor = 900, head = -1 }, { anchor = 0 / 0, head = 1e9 },
	{ ranges = {}, primary = 1 }, { ranges = { { anchor = 1e9, head = 0 } }, primary = 7 },
	{ ranges = { { anchor = 3, head = 2 }, { anchor = 2, head = 3 } }, primary = 0 },
	{ from = -1, to = 1e9 }, { from = 5, to = 2 }, { 1, 2 }, function() end,
	-- Tables that run plugin code when read: it calls back into the API,
	-- and closes what the call was given while the call reads its arguments.
	setmetatable({}, { __index = function() greed.echo("re-entered") return nil end }),
	setmetatable({}, { __index = closer }),
}
local values = {}
for _, v in nums do table.insert(values, v) end
for _, v in others do table.insert(values, v) end

local seed = 12345
local function random(n: number): number
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed % n + 1
end
local function pick(): any
	return values[random(#values)]
end

local mark_fields = { MARK }
local float_fields = { FLOAT }
local function spec(fields: { string }): { [string]: any }
	local t = {}
	for _ = 1, random(6) do
		t[fields[random(#fields)]] = pick()
	end
	if random(4) == 1 then
		setmetatable(t, { __index = closer })
	end
	return t
end

local lists = { {} }
for _, v in values do table.insert(lists, { v }) end
for _, a in nums do
	for _, b in nums do table.insert(lists, { a, b }) end
	table.insert(lists, { a, "x" })
	table.insert(lists, { a, a, "é" })
	table.insert(lists, { a, "\255" })
end
for _ = 1, 150 do
	local list = {}
	for i = 1, random(4) do list[i] = pick() end
	table.insert(lists, list)
end
for _ = 1, 40 do
	table.insert(lists, { "fuzz", { spec(mark_fields), spec(mark_fields) }, pick() })
	table.insert(lists, { spec(mark_fields) })
	table.insert(lists, { spec(float_fields) })
end

local function show(v: any): string
	if type(v) == "string" then
		return string.format("%q", if #v > 20 then v:sub(1, 20) .. "..." else v)
	elseif type(v) == "table" then
		local parts = {}
		for k, x in v do table.insert(parts, tostring(k) .. "=" .. show(x)) end
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	return tostring(v)
end

function fuzz(label: string, make: () -> any, names: { string })
	for _, name in names do
		-- What was made before can leave nothing to make this from.
		local made, object = pcall(make)
		if not made then
			continue
		end
		-- Handles too, some closed while the call reads what comes after.
		local handles = {}
		for _ = 1, 4 do
			local b = buffer()
			local v = greed.float(buffer())
			table.insert(handles, { b })
			table.insert(handles, { b, spec(float_fields) })
			table.insert(handles, { b, setmetatable({}, { __index = closer }) })
			table.insert(handles, { "x", { spec(mark_fields) }, setmetatable({}, { __index = closer }) })
			table.insert(handles, { v, b })
			table.insert(handles, { b, 0, setmetatable({}, { __index = closer }) })
		end
		for _, list in table.move(handles, 1, #handles, #lists + 1, table.clone(lists)) do
			LAST = label .. "." .. name .. "(" .. show(list) .. ")"
			local f = object[name]
			if type(f) == "function" then
				if label:sub(1, 1) == ":" then
					pcall(f, object, table.unpack(list, 1, 4))
				else
					pcall(f, table.unpack(list, 1, 4))
				end
			end
		end
	end
end

function buffer(): any
	local b = greed.create_buffer("fuzz", TEXT, { language = "rust" })
	table.insert(MADE, b)
	return b
end
"#;

thread_local! {
    /// Where this thread last panicked, caught or not.
    static PANICKED: std::cell::RefCell<Option<String>> = const { std::cell::RefCell::new(None) };
}

/// Notes each panic, even one Luau's `pcall` catches, so a test sees it.
fn watch_panics() {
    static HOOK: std::sync::Once = std::sync::Once::new();
    HOOK.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            PANICKED.with(|p| *p.borrow_mut() = Some(info.to_string()));
            previous(info);
        }));
    });
}

/// Runs `script` and fails with the panic, if anything panicked, and the
/// call that ran last.
fn run(host: &Host, script: &str) {
    watch_panics();
    let ran = catch_unwind(AssertUnwindSafe(|| host.eval(script)));
    let last = || host.eval("LAST").unwrap_or_default();
    if let Some(panic) = PANICKED.with(|p| p.borrow_mut().take()) {
        panic!("{panic}\nthe last call: {}", last());
    }
    match ran {
        Ok(Ok(_)) => {}
        Ok(Err(err)) => panic!("{} failed: {err}", last()),
        Err(panic) => std::panic::resume_unwind(panic),
    }
}

fn names(types: &str, name: &str) -> String {
    declared(types, name)
        .iter()
        .map(|n| format!("{n:?}"))
        .collect::<Vec<_>>()
        .join(", ")
}

fn prepared() -> (Host, String) {
    let types = types();
    let h = host();
    let script = FUZZ
        .replace("MARK", &names(&types, "Mark"))
        .replace("FLOAT", &names(&types, "FloatSpec"));
    h.eval(&format!("(function(...) {script} end)({TEXT:?})"))
        .unwrap();
    (h, types)
}

/// Draws the screen at sizes from none to huge.
fn draw(host: &Host) {
    for (width, height) in [(0, 0), (1, 1), (2, 1), (5, 3), (80, 24), (300, 2), (7, 200)] {
        let size = Size { width, height };
        let drawn = catch_unwind(AssertUnwindSafe(|| {
            host.with_editor_mut(|ed| {
                Renderer::new(CellWidth).frame(ed, size, &Status::Default { message: None }, &Plain)
            })
        }));
        assert!(drawn.is_ok(), "drawing at {width}x{height} panicked");
    }
}

fn fuzz(label: &str, make: &str, type_name: &str, skip: &[&str]) {
    let (h, types) = prepared();
    for name in declared(&types, type_name) {
        if skip.contains(&name.as_str()) {
            continue;
        }
        run(
            &h,
            &format!("fuzz({label:?}, function() {make} end, {{ {name:?} }})"),
        );
        draw(&h);
    }
}

#[test]
fn buffer_methods_survive_nonsense() {
    // Saving and reloading touch files.
    fuzz(":buffer", "return buffer()", "Buffer", &["save", "reload"]);
}

#[test]
fn methods_of_a_buffer_shown_in_the_main_view_survive_nonsense() {
    fuzz(
        ":main buffer",
        "local b = buffer() greed.view():show(b) return b",
        "Buffer",
        &["save", "reload"],
    );
}

#[test]
fn view_methods_survive_nonsense() {
    fuzz(":float", "return greed.float(buffer())", "View", &[]);
    fuzz(":main view", "return greed.view()", "View", &[]);
    fuzz(
        ":pane",
        "return greed.view():split('right', buffer())",
        "View",
        &[],
    );
}

#[test]
fn edits_survive_nonsense() {
    let (h, types) = prepared();
    for name in declared(&types, "Edits") {
        run(
            &h,
            &format!(
                "local b = buffer() pcall(b.edit, b, function(e) fuzz(':edits', function() return e end, {{ {name:?} }}) end)"
            ),
        );
    }
    draw(&h);
}

#[test]
fn anchors_tracked_ranges_and_nodes_survive_nonsense() {
    fuzz(":anchor", "return buffer():track(3)", "Anchor", &[]);
    fuzz(
        ":tracked",
        "return buffer():track_range(1, 9)",
        "Tracked",
        &[],
    );
    fuzz(":node", "return buffer():node_at(3)", "Node", &[]);
    fuzz(
        ":old node",
        "local b = buffer() local n = b:node_at(3) b:edit(function(e) e:delete(0, b:len()) end) return n",
        "Node",
        &[],
    );
}

#[test]
fn closed_handles_survive_nonsense() {
    fuzz(
        ":closed buffer",
        "local b = buffer() b:close() return b",
        "Buffer",
        &["save", "reload"],
    );
    fuzz(
        ":closed view",
        "local v = greed.float(buffer()) v:close() return v",
        "View",
        &[],
    );
    fuzz(
        ":closed anchor",
        "local b = buffer() local a = b:track(3) b:close() return a",
        "Anchor",
        &[],
    );
}

#[test]
fn api_tables_survive_nonsense() {
    for (label, make, type_name) in [
        ("keymap", "greed.keymap", "Keymap"),
        ("mode", "greed.mode", "Mode"),
        ("option", "greed.option", "Options"),
        ("history", "greed.history", "History"),
        ("tab", "greed.tab", "Tabs"),
        ("syntax", "greed.syntax", "Syntax"),
        ("theme", "greed.theme", "Theme"),
        ("image", "greed.image", "Images"),
        ("json", "greed.json", "Json"),
    ] {
        fuzz(label, &format!("return {make}"), type_name, &[]);
    }
}

#[test]
fn module_functions_survive_nonsense() {
    let (h, _) = prepared();
    let names = [
        "line_numbers",
        "reveal",
        "create_buffer",
        "language_of",
        "float",
        "floats",
        "panel",
        "buffers",
        "buffer_for",
        "diff",
        "fuzzy",
        "fuzzy_positions",
        "set_menus",
        "filetype",
    ];
    for name in names {
        run(
            &h,
            &format!("fuzz('greed', function() return greed end, {{ {name:?} }})"),
        );
        draw(&h);
    }
}

#[test]
fn closing_the_only_pane_of_a_split_a_plugin_made() {
    let (h, _) = prepared();
    run(
        &h,
        "local v = greed.view() local p = v:split('right', buffer()) \
         greed.tab.set_layout({ split = 'row', children = { { split = 'column', children = { p } }, v } }) \
         p:close()",
    );
    draw(&h);
}

#[test]
fn handles_closed_while_a_call_reads_its_arguments() {
    let (h, _) = prepared();
    for call in [
        "local b = buffer() greed.panel(b, setmetatable({}, { __index = function() pcall(b.close, b) return nil end }))",
        "local b = buffer() b:decorate('ns', { setmetatable({}, { __index = function(_, k) pcall(b.close, b) return if k == 'style' then 'x' else 0 end }) })",
        "local b = buffer() b:query('(_) @x', setmetatable({}, { __index = function() greed.echo('re-entered') return nil end }))",
    ] {
        let wrapped = format!("LAST = {call:?} pcall(function() {call} end)");
        run(&h, &wrapped);
        h.eval("greed.view():buffer():edit(function(e) e:insert(0, 'x') end)")
            .unwrap();
        draw(&h);
    }
}

#[test]
fn resizing_panes_with_no_room_to_give() {
    let (h, _) = prepared();
    run(
        &h,
        "local v = greed.view() P = v:split('right', buffer()) Q = P:split('right', buffer()) \
         greed.tab.set_layout({ split = 'row', children = { v, P, Q }, sizes = { 1, 1, 1e6 } })",
    );
    draw(&h);
    run(
        &h,
        "for _, d in { 'left', 'right', 'up', 'down' } do \
           for _, n in { 1, -1, 2147483647, -2147483648 } do \
             greed.view():resize(d, n) P:resize(d, n) Q:resize(d, n) \
           end \
         end",
    );
    draw(&h);
}

#[test]
fn waits_too_long_to_count_or_less_than_none() {
    let (h, _) = prepared();
    run(
        &h,
        "for _, ms in { 1e300, 1e20, math.huge, -math.huge, 0 / 0, -1 } do \
           greed.spawn(function() greed.sleep(ms) end) \
         end",
    );
}
