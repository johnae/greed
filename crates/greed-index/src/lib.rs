//! Running Greed's queries: comparing values the way every filter does, and
//! matching a query against rows, in memory and in indexes. Queries are
//! parsed and checked in Luau (`core.query`); this crate runs them.

pub mod compare;
pub mod query;

pub mod index;
