//! Transactions: a change set plus who made it, when, and against what.
//!
//! Every transaction has a globally unique [`TxId`] and records the
//! transaction(s) it was made against as `parents`, so history forms a graph
//! that a sync layer can replay later.

use std::sync::Arc;
use std::time::SystemTime;

use smallvec::SmallVec;

use crate::changeset::is_char_boundary;
use crate::{ChangeSet, Error, Rope, Selection};

/// A transaction id, unique across replicas: `seq` counts up per replica.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct TxId {
    pub replica: u32,
    pub seq: u64,
}

/// Hands out transaction ids for one replica (one server, one session).
#[derive(Debug)]
pub struct Replica {
    id: u32,
    next_seq: u64,
}

impl Replica {
    pub fn new(id: u32) -> Self {
        Self { id, next_seq: 0 }
    }

    pub fn next_id(&mut self) -> TxId {
        let id = TxId {
            replica: self.id,
            seq: self.next_seq,
        };
        self.next_seq += 1;
        id
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ClientId(pub u32);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct AgentId(pub u32);

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Author {
    User(ClientId),
    Plugin(Arc<str>),
    Agent(AgentId),
    /// A change made outside the editor, picked up from disk.
    External,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TxMeta {
    pub id: TxId,
    /// The transactions this one was made against. Usually exactly one;
    /// empty for the first transaction on a buffer.
    pub parents: SmallVec<[TxId; 1]>,
    pub author: Author,
    /// Free-form label for why the change happened: a command name, an
    /// agent tool call id, and so on.
    pub cause: Option<Arc<str>>,
    pub time: SystemTime,
    /// Transactions sharing a group are undone together.
    pub group: Option<u64>,
}

impl TxMeta {
    pub fn new(id: TxId, parents: &[TxId], author: Author) -> Self {
        Self {
            id,
            parents: SmallVec::from_slice(parents),
            author,
            cause: None,
            time: SystemTime::now(),
            group: None,
        }
    }

    #[must_use]
    pub fn with_cause(mut self, cause: impl Into<Arc<str>>) -> Self {
        self.cause = Some(cause.into());
        self
    }

    #[must_use]
    pub fn with_group(mut self, group: u64) -> Self {
        self.group = Some(group);
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Transaction {
    pub changes: ChangeSet,
    /// The selection after the change. When `None`, the current selection is
    /// mapped through the change instead.
    pub selection: Option<Selection>,
    pub meta: TxMeta,
}

impl Transaction {
    pub fn new(changes: ChangeSet, meta: TxMeta) -> Self {
        Self {
            changes,
            selection: None,
            meta,
        }
    }

    /// Applies the change to `rope` and returns the selection that follows
    /// it. Nothing changes if the change set or the resulting selection
    /// doesn't fit the text.
    pub fn apply(&self, rope: &mut Rope, current: &Selection) -> Result<Selection, Error> {
        let mut next = rope.clone();
        self.changes.apply(&mut next)?;
        let selection = match &self.selection {
            Some(selection) => selection.clone(),
            None => current.map(&self.changes),
        };
        check_selection(&selection, &next)?;
        *rope = next;
        Ok(selection)
    }

    /// Returns a transaction that undoes this one. `original` and `before`
    /// are the text and selection from before this transaction was applied.
    pub fn invert(&self, original: &Rope, before: &Selection, meta: TxMeta) -> Result<Self, Error> {
        Ok(Self {
            changes: self.changes.invert(original)?,
            selection: Some(before.clone()),
            meta,
        })
    }
}

fn check_selection(selection: &Selection, rope: &Rope) -> Result<(), Error> {
    let len = rope.len_bytes();
    for pos in selection.ranges().iter().flat_map(|r| [r.anchor, r.head]) {
        if pos > len {
            return Err(Error::OutOfBounds { pos, len });
        }
        if !is_char_boundary(rope, pos) {
            return Err(Error::NotCharBoundary { pos });
        }
    }
    Ok(())
}
