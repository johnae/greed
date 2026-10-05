//! `greed.pdf`: PDF documents, their pages as images for marks to show and
//! the text on them. Reading, drawing and taking the text out of a page all
//! run in the background, so a big page doesn't hold the editor up.

use std::sync::Arc;

use mlua::{IntoLuaMulti, Lua, Table, Value};

use super::jobs::{self, Output};
use super::{state_mut, tasks};
use crate::pdf::Document;

type LuaResult<T> = mlua::Result<T>;

/// What a PDF job produced.
pub enum Done {
    Opened(Result<Document, String>),
    Rendered(Result<crate::image::Image, String>),
    Text(Result<String, String>),
}

pub(super) fn module(lua: &Lua) -> LuaResult<Table> {
    let pdf = lua.create_table()?;
    let open = lua.create_function(|lua, path: String| {
        super::secrets::guard(lua, std::path::Path::new(&path))?;
        Ok(jobs::start(lua, move || {
            Output::Pdf(Done::Opened(
                std::fs::read(&path)
                    .map_err(|err| format!("can't read {path}: {err}"))
                    .and_then(Document::new),
            ))
        }))
    })?;
    pdf.set("open", jobs::waiting(lua, "greed.pdf.open", open)?)?;
    Ok(pdf)
}

/// Page `page` of `doc` counting from 1 as Luau does, from 0 as Rust does.
fn page_index(doc: &Document, page: usize) -> LuaResult<usize> {
    page.checked_sub(1)
        .filter(|&i| i < doc.pages())
        .ok_or_else(|| {
            mlua::Error::runtime(format!("there is no page {page}; it has {}", doc.pages()))
        })
}

/// A document as Luau sees it: its page count and functions on its pages.
fn document(lua: &Lua, doc: Document) -> LuaResult<Table> {
    let doc = Arc::new(doc);
    let t = lua.create_table()?;
    t.set("pages", doc.pages())?;
    t.set(
        "size",
        lua.create_function({
            let doc = doc.clone();
            move |_, page: usize| Ok(doc.size(page_index(&doc, page)?).unzip())
        })?,
    )?;
    let render = lua.create_function({
        let doc = doc.clone();
        move |lua, (page, scale): (usize, Option<f32>)| {
            let (doc, page) = (doc.clone(), page_index(&doc, page)?);
            let scale = scale.unwrap_or(1.0);
            Ok(jobs::start(lua, move || {
                Output::Pdf(Done::Rendered(doc.render(page, scale)))
            }))
        }
    })?;
    t.set("render", jobs::waiting(lua, "render", render)?)?;
    let text = lua.create_function(move |lua, page: usize| {
        let (doc, page) = (doc.clone(), page_index(&doc, page)?);
        Ok(jobs::start(lua, move || {
            Output::Pdf(Done::Text(doc.text(page)))
        }))
    })?;
    t.set("text", jobs::waiting(lua, "text", text)?)?;
    Ok(t)
}

/// Wakes the command waiting on PDF job `token` with what it produced, or
/// nil and why not.
pub(super) fn finish(lua: &Lua, token: u64, done: Done) -> LuaResult<()> {
    let value = match done {
        Done::Opened(Ok(doc)) => document(lua, doc)?.into_lua_multi(lua)?,
        Done::Rendered(Ok(image)) => {
            let id = state_mut(lua).editor.images_mut().insert(Arc::new(image));
            id.0.into_lua_multi(lua)?
        }
        Done::Text(Ok(text)) => text.into_lua_multi(lua)?,
        Done::Opened(Err(err)) | Done::Rendered(Err(err)) | Done::Text(Err(err)) => {
            (Value::Nil, err).into_lua_multi(lua)?
        }
    };
    tasks::deliver(lua, token, value)
}
