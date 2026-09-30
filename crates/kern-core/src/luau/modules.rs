//! Plugin environments and `require`, resolved the way Luau's own tools
//! resolve them so `luau-analyze` and `luau-lsp` see what runs:
//!
//! - `require("@kern")` is the editor API; `require("@kern/test")` is the
//!   test API, available in test files.
//! - `require("./x")` loads `x.luau` (or `x/init.luau`) next to the file
//!   doing the require. From an `init.luau`, siblings are `@self/x`.
//!
//! A plugin's files share its globals, and can't require anything outside
//! the plugin's directory.

use std::path::{Component, Path, PathBuf};

use mlua::{Function, Lua, Table, Value};

use super::api;
use crate::registry::PluginId;

type LuaResult<T> = mlua::Result<T>;

/// Everything needed to run one plugin's code.
#[derive(Clone)]
pub(super) struct Modules {
    owner: PluginId,
    /// The plugin's globals, over the read-only standard library.
    globals: Table,
    kern: Table,
    test: Option<Function>,
    /// The plugin's directory; `None` for inline code, which can only
    /// require `@kern`.
    root: Option<PathBuf>,
    /// Loaded modules, by path.
    loaded: Table,
}

impl Modules {
    pub fn new(
        lua: &Lua,
        owner: &str,
        root: Option<PathBuf>,
        test: Option<Function>,
    ) -> LuaResult<Self> {
        let globals = lua.create_table()?;
        let meta = lua.create_table()?;
        meta.set("__index", lua.globals())?;
        globals.set_metatable(Some(meta))?;
        let owner: PluginId = owner.into();
        Ok(Self {
            kern: api::kern_module(lua, &owner)?,
            owner,
            globals,
            test,
            root,
            loaded: lua.create_table()?,
        })
    }

    /// Runs a file of this plugin for its effects.
    pub fn run_file(&self, lua: &Lua, file: &Path) -> LuaResult<()> {
        self.load_file(lua, file).map(drop)
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
        lua.load(source)
            .set_name(format!("@{}/{}", self.owner, relative.display()))
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
        Ok(env)
    }

    fn require(&self, lua: &Lua, from: Option<&Path>, name: &str) -> LuaResult<Value> {
        match name {
            "@kern" => return Ok(Value::Table(self.kern.clone())),
            "@kern/test" => {
                return self.test.clone().map(Value::Function).ok_or_else(|| {
                    mlua::Error::runtime("@kern/test is only available in test files")
                });
            }
            _ => {}
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
            return Err(fail("only @kern can be required here"));
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
                "use \"@kern\", \"./file\", or \"@self/file\" from init.luau",
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
