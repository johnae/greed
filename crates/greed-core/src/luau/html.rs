//! `greed.html`: web pages as text to read ([`crate::html`]). Reading runs
//! in the background, so a big page doesn't hold the editor up.

use mlua::{Lua, Table};

use super::jobs::{self, Output};
use super::tasks;
use crate::html::Page;

type LuaResult<T> = mlua::Result<T>;

pub(super) fn module(lua: &Lua) -> LuaResult<Table> {
    let html = lua.create_table()?;
    let read = lua.create_function(|lua, (page, url): (mlua::LuaString, Option<String>)| {
        let page = page.to_string_lossy();
        Ok(jobs::start(lua, "greed.html.read", move || {
            Output::Html(crate::html::read(&page, url.as_deref()))
        }))
    })?;
    html.set("read", jobs::waiting(lua, "greed.html.read", read)?)?;
    Ok(html)
}

pub(super) fn finish(lua: &Lua, token: u64, page: Page) -> LuaResult<()> {
    let t = lua.create_table()?;
    t.set("title", page.title)?;
    t.set("byline", page.byline)?;
    t.set("excerpt", page.excerpt)?;
    t.set("text", page.text)?;
    t.set("article", page.article)?;
    tasks::deliver(lua, token, t)
}
