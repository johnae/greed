//! Greed's mail: keeps mail accounts synced into a store and an index for
//! Greed's mail client, and sends mail. The `greed-mail` binary runs it.

pub mod body;
pub mod config;
pub mod files;
pub mod header;
pub mod html;
pub mod imap;
pub mod indexing;
pub mod invite;
pub mod names;
pub mod pending;
pub mod reader;
pub mod send;
pub mod serve;
pub mod store;
pub mod sync;
