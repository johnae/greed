//! Greed's mail: keeps mail accounts synced into a store and an index for
//! Greed's mail client, and sends mail. The `greed-mail` binary runs it.

pub mod config;
pub mod header;
pub mod imap;
pub mod names;
pub mod store;
pub mod sync;
