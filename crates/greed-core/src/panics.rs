//! The last line against bugs in the editor: a panic while running plugin
//! code or handling a client's input becomes an error, reported like any
//! other, and the editor carries on. Nothing a plugin, client, agent,
//! language server or file does should panic; this is for when something
//! does anyway.

use std::any::Any;
use std::cell::{Cell, RefCell};
use std::fmt;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Once;

thread_local! {
    /// How many [`catching`] calls this thread is inside.
    static CATCHING: Cell<usize> = const { Cell::new(0) };
    /// What the last panic caught on this thread said, and where.
    static LAST: RefCell<Option<String>> = const { RefCell::new(None) };
}

/// A panic that was caught.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Panic {
    /// What it said, and where in the editor's code.
    pub message: String,
}

impl fmt::Display for Panic {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "internal error, a bug in Greed: {}", self.message)
    }
}

impl std::error::Error for Panic {}

/// Runs `f`, turning a panic in it into an error. The panic isn't printed:
/// whoever catches it reports it.
pub fn catching<R>(f: impl FnOnce() -> R) -> Result<R, Panic> {
    install_hook();
    CATCHING.set(CATCHING.get() + 1);
    let result = catch_unwind(AssertUnwindSafe(f));
    CATCHING.set(CATCHING.get() - 1);
    result.map_err(|payload| Panic {
        message: LAST.take().unwrap_or_else(|| said(payload.as_ref())),
    })
}

/// Whether a panic on this thread now would be caught by [`catching`], so
/// a panic hook knows to leave the screen alone.
pub fn caught_here() -> bool {
    CATCHING.get() > 0
}

/// What a panic's payload says.
fn said(payload: &(dyn Any + Send)) -> String {
    payload
        .downcast_ref::<&str>()
        .map(|s| (*s).to_owned())
        .or_else(|| payload.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "a panic".to_owned())
}

/// Keeps what a panic [`catching`] will catch says, with where it was,
/// instead of printing it; other panics go to the hook there was before.
fn install_hook() {
    static HOOK: Once = Once::new();
    HOOK.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            if caught_here() {
                let message = match info.location() {
                    Some(at) => format!("{} at {at}", said(info.payload())),
                    None => said(info.payload()),
                };
                LAST.set(Some(message));
            } else {
                previous(info);
            }
        }));
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_panic_becomes_an_error_saying_where_it_was() {
        let caught = catching(|| -> u8 { panic!("broken {}", 7) }).unwrap_err();
        assert!(caught.message.starts_with("broken 7 at "), "{caught}");
        assert!(caught.message.contains("panics.rs"), "{caught}");
        assert!(caught.to_string().contains("a bug in Greed"), "{caught}");
        assert_eq!(catching(|| 3), Ok(3));
        assert!(!caught_here());
    }

    #[test]
    fn catching_nests() {
        let outer = catching(|| {
            assert!(caught_here());
            let inner = catching(|| panic!("inner"));
            assert!(caught_here());
            inner.map_err(|p| p.message)
        });
        assert!(outer.unwrap().unwrap_err().starts_with("inner at "));
    }
}
