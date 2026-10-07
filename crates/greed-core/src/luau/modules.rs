//! Plugin environments and `require`, resolved the way Luau's own tools
//! resolve them so `luau-analyze` and `luau-lsp` see what runs:
//!
//! - `require("@greed")` is the editor API; `require("@greed/test")` is the
//!   test API, available in test files.
//! - `require("./x")` loads `x.luau` (or `x/init.luau`) next to the file
//!   doing the require. From an `init.luau`, siblings are `@self/x`.
//!
//! A plugin's files share its globals, and can't require anything outside
//! the plugin's directory.

use std::path::{Component, Path, PathBuf};

use mlua::{Function, Lua, Table, Value};

use super::capabilities::{self, Grant};
use super::{api, state, state_mut};
use crate::registry::PluginId;

type LuaResult<T> = mlua::Result<T>;

/// Everything needed to run one plugin's code.
#[derive(Clone)]
pub(super) struct Modules {
    owner: PluginId,
    /// The plugin's globals, over the read-only standard library.
    globals: Table,
    greed: Table,
    test: Option<Function>,
    /// The plugin's directory; `None` for inline code, which can only
    /// require `@greed`.
    root: Option<PathBuf>,
    /// Loaded modules, by path.
    loaded: Table,
    /// Sandboxed code, which can require nothing but `@greed`.
    sandboxed: bool,
    /// Config, tests and the REPL, which may change other plugins' modules;
    /// plugins get them read-only.
    trusted: bool,
}

impl Modules {
    pub fn new(
        lua: &Lua,
        owner: &str,
        root: Option<PathBuf>,
        test: Option<Function>,
        grant: &Grant,
    ) -> LuaResult<Self> {
        let globals = lua.create_table()?;
        let meta = lua.create_table()?;
        meta.set("__index", lua.globals())?;
        globals.set_metatable(Some(meta))?;
        globals.set("coroutine", capabilities::coroutine_module(lua)?)?;
        let owner: PluginId = owner.into();
        own_code_only(lua, &globals)?;
        let greed = api::greed_module(lua, &owner)?;
        capabilities::gate(lua, &greed, &owner, grant)?;
        Ok(Self {
            greed,
            owner,
            globals,
            test,
            root,
            loaded: lua.create_table()?,
            sandboxed: false,
            trusted: *grant == Grant::All,
        })
    }

    /// Fresh modules for sandboxed code: no capabilities, none of the parts
    /// of `@greed` that act beyond the buffers' text, and no other plugin to
    /// require, since a plugin's code runs with its own capabilities.
    pub fn sandbox(lua: &Lua) -> LuaResult<Self> {
        let mut modules = Self::new(
            lua,
            capabilities::SANDBOX,
            None,
            None,
            &capabilities::sandbox_grant(),
        )?;
        capabilities::sandbox(lua, &modules.greed)?;
        modules.sandboxed = true;
        Ok(modules)
    }

    /// Runs a file of this plugin, returning what it returns.
    pub fn run_file(&self, lua: &Lua, file: &Path) -> LuaResult<Value> {
        self.load_file(lua, file)
    }

    /// Evaluates inline source, returning its values.
    pub fn eval(&self, lua: &Lua, source: &str, chunk_name: &str) -> LuaResult<mlua::MultiValue> {
        lua.load(source)
            .set_name(chunk_name)
            .set_environment(self.file_env(lua, None)?)
            .eval()
    }

    fn load_file(&self, lua: &Lua, file: &Path) -> LuaResult<Value> {
        let source = std::fs::read_to_string(file)
            .map_err(|err| mlua::Error::runtime(format!("can't read {}: {err}", file.display())))?;
        let relative = self
            .root
            .as_deref()
            .and_then(|root| file.strip_prefix(root).ok())
            .unwrap_or(file);
        let name = format!("{}/{}", self.owner, relative.display());
        state_mut(lua).sources.insert(name.clone(), file.to_owned());
        lua.load(source)
            .set_name(format!("@{name}"))
            .set_environment(self.file_env(lua, Some(file))?)
            .eval()
    }

    /// The environment for one file: the plugin's globals, plus a `require`
    /// that resolves relative to that file.
    fn file_env(&self, lua: &Lua, file: Option<&Path>) -> LuaResult<Table> {
        let env = lua.create_table()?;
        let meta = lua.create_table()?;
        meta.set("__index", &self.globals)?;
        meta.set("__newindex", &self.globals)?;
        env.set_metatable(Some(meta))?;

        let modules = self.clone();
        let file = file.map(Path::to_owned);
        env.raw_set(
            "require",
            lua.create_function(move |lua, name: String| {
                modules.require(lua, file.as_deref(), &name)
            })?,
        )?;
        // Code the plugin loads at runtime is named after it and shares this
        // environment, so capabilities, which go by whose code runs, count
        // it as the plugin's whatever name the caller gave.
        let loaded_env = env.clone();
        let name = format!("@{}/loadstring", self.owner);
        env.raw_set(
            "loadstring",
            lua.create_function(move |lua, (source, _): (mlua::LuaString, Value)| {
                let loaded = lua
                    .load(source.as_bytes().to_vec())
                    .set_name(&name)
                    .set_mode(mlua::chunk::ChunkMode::Text)
                    .set_environment(loaded_env.clone())
                    .into_function();
                Ok(match loaded {
                    Ok(f) => (Some(f), None),
                    Err(err) => (None, Some(err.to_string())),
                })
            })?,
        )?;
        Ok(env)
    }

    fn require(&self, lua: &Lua, from: Option<&Path>, name: &str) -> LuaResult<Value> {
        match name {
            "@greed" => return Ok(Value::Table(self.greed.clone())),
            _ if self.sandboxed => {
                return Err(capabilities::needs_approval(&format!(
                    "require {name}, whose code has capabilities of its own"
                )));
            }
            "@greed/test" => {
                return self.test.clone().map(Value::Function).ok_or_else(|| {
                    mlua::Error::runtime("@greed/test is only available in test files")
                });
            }
            _ => {}
        }
        if let Some(plugin) = name.strip_prefix('@').filter(|n| !n.starts_with("self/")) {
            let module = state(lua).exports.get(plugin).cloned().ok_or_else(|| {
                mlua::Error::runtime(format!(
                    "can't require {name:?}: add {plugin:?} to `requires` in plugin.toml"
                ))
            })?;
            if self.trusted || *self.owner == *plugin {
                return Ok(module);
            }
            return read_only(lua, module, plugin);
        }
        let path = self.resolve(from, name)?;
        let key = path.to_string_lossy();
        if let Some(module) = self.loaded.get::<Option<Value>>(&*key)? {
            return Ok(module);
        }
        let module = self.load_file(lua, &path)?;
        self.loaded.set(&*key, module.clone())?;
        Ok(module)
    }

    /// The file `name` refers to when required from `from`.
    fn resolve(&self, from: Option<&Path>, name: &str) -> LuaResult<PathBuf> {
        let fail = |why: &str| mlua::Error::runtime(format!("can't require {name:?}: {why}"));
        let (Some(root), Some(from)) = (&self.root, from) else {
            return Err(fail("only @greed can be required here"));
        };
        let dir = from.parent().unwrap_or(root);
        let is_init = from.file_name().is_some_and(|f| f == "init.luau");
        let base = if let Some(rest) = name.strip_prefix("@self/") {
            if !is_init {
                return Err(fail("@self is for init.luau; use \"./\" in other files"));
            }
            dir.join(rest)
        } else if name.starts_with("./") || name.starts_with("../") {
            // An init.luau stands for its directory, so "./" means that
            // directory's siblings.
            let dir = if is_init {
                dir.parent().unwrap_or(dir)
            } else {
                dir
            };
            dir.join(name)
        } else {
            return Err(fail(
                "use \"@greed\", \"./file\", or \"@self/file\" from init.luau",
            ));
        };
        let base = normalize(&base);
        if !base.starts_with(root) {
            return Err(fail("it is outside the plugin"));
        }
        let mut file = base.clone().into_os_string();
        file.push(".luau");
        [PathBuf::from(file), base.join("init.luau")]
            .into_iter()
            .find(|p| p.is_file())
            .ok_or_else(|| fail("no such file"))
    }
}

/// Takes away `getfenv`/`setfenv`, which reach into another plugin's
/// environment to borrow its `require` and capabilities. `loadstring` is
/// kept, but each file's [`file_env`](Modules::file_env) names what it
/// loads after the plugin, so loaded code can't shed its plugin either.
fn own_code_only(lua: &Lua, globals: &Table) -> LuaResult<()> {
    for name in ["getfenv", "setfenv"] {
        globals.set(
            name,
            lua.create_function(move |_, _: mlua::MultiValue| -> LuaResult<()> {
                Err(mlua::Error::runtime(format!(
                    "{name} isn't available to plugins"
                )))
            })?,
        )?;
    }
    Ok(())
}

/// Resolves `.` and `..` without touching the file system.
fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other),
        }
    }
    out
}

/// Luau returning `view(t, name)`, which makes the read-only view of `t`
/// for `read_only`.
const READ_ONLY_VIEW: &str = r#"
local views = setmetatable({}, { __mode = "kv" })
local function view(t, name)
    local seen = views[t]
    if seen then
        return seen
    end
    local function wrap(value)
        return if type(value) == "table" then view(value, name) else value
    end
    local made = setmetatable({}, {
        __index = function(_, key)
            return wrap(t[key])
        end,
        __newindex = function(_, key, value)
            -- A frozen table takes no writes but through its own
            -- __newindex, like a list only added to.
            if table.isfrozen(t) then
                t[key] = value
                return
            end
            error(`{name}'s module is read-only for other plugins: can't set {tostring(key)}; use the functions it offers`, 2)
        end,
        __iter = function()
            local pairs = {}
            for key, value in t do
                table.insert(pairs, { key, value })
            end
            local i = 0
            return function()
                i += 1
                local pair = pairs[i]
                if pair then
                    return pair[1], wrap(pair[2])
                end
                return nil
            end
        end,
        __len = function()
            return #t
        end,
        __tostring = function()
            return `{name}'s module`
        end,
        __metatable = false,
    })
    views[t] = made
    return made
end
return view
"#;

/// What `require("@name")` gives other plugins: a read-only view of the
/// module. Reads pass through, nested tables as views too, and writes
/// fail. Each table has one view.
fn read_only(lua: &Lua, module: Value, name: &str) -> LuaResult<Value> {
    const KEY: &str = "greed.read_only";
    if !module.is_table() {
        return Ok(module);
    }
    let cached = lua.named_registry_value::<Option<Function>>(KEY)?;
    let view = if let Some(view) = cached {
        view
    } else {
        let view: Function = lua
            .load(READ_ONLY_VIEW)
            .set_name("=greed.read_only")
            .eval()?;
        lua.set_named_registry_value(KEY, &view)?;
        view
    };
    view.call((module, name))
}
