//! Buffer history: an append-only log of every applied transaction, plus an
//! undo tree for navigation.
//!
//! The log is the durable record. Undo and redo don't rewrite it; they apply
//! new transactions (with cause `"undo"` / `"redo"`) and move a pointer in
//! the tree.

use kern_text::{Author, ChangeSet, Rope, Selection, Transaction, TxId};

#[derive(Debug)]
pub struct History {
    log: Vec<Transaction>,
    /// The inverse of each transaction in the log, so earlier texts can be
    /// rebuilt.
    inverses: Vec<ChangeSet>,
    /// Undo tree. Node 0 is the root: the buffer as it was loaded.
    nodes: Vec<Node>,
    current: usize,
}

/// One undo step: one transaction, or several merged by group.
#[derive(Debug)]
struct Node {
    parent: usize,
    /// The last child is the one redo follows.
    children: Vec<usize>,
    changes: ChangeSet,
    inverse: ChangeSet,
    before: Selection,
    after: Selection,
    group: Option<u64>,
}

/// Where a group stands in a buffer's undo tree.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GroupState {
    /// Nothing in the buffer was done in the group.
    Absent,
    /// The group is the latest undo step, so undo would take it back.
    Current,
    /// The group is in the text, but something else was done on top of it.
    Buried,
    /// The group was undone.
    Undone,
}

/// A change set to apply for an undo or redo, and the selection to restore.
pub(crate) struct Step {
    pub changes: ChangeSet,
    pub selection: Selection,
}

impl Default for History {
    fn default() -> Self {
        Self {
            log: Vec::new(),
            inverses: Vec::new(),
            nodes: vec![Node {
                parent: 0,
                children: Vec::new(),
                changes: ChangeSet::default(),
                inverse: ChangeSet::default(),
                before: Selection::point(0),
                after: Selection::point(0),
                group: None,
            }],
            current: 0,
        }
    }
}

impl History {
    /// Every transaction applied to the buffer, oldest first.
    pub fn log(&self) -> &[Transaction] {
        &self.log
    }

    pub fn by_author<'a>(&'a self, author: &'a Author) -> impl Iterator<Item = &'a Transaction> {
        self.log.iter().filter(move |tx| &tx.meta.author == author)
    }

    /// The text as it was before transaction `id`, given the text now; `None`
    /// if `id` isn't in the log.
    pub fn text_before(&self, now: &Rope, id: TxId) -> Option<Rope> {
        let index = self.log.iter().rposition(|tx| tx.meta.id == id)?;
        let mut text = now.clone();
        for inverse in self.inverses[index..].iter().rev() {
            inverse
                .apply(&mut text)
                .expect("each inverse fits the text after its transaction");
        }
        Some(text)
    }

    /// Where `group` stands: whether undo would take it back now.
    pub fn group_state(&self, group: u64) -> GroupState {
        let group = Some(group);
        if self.current != 0 && self.nodes[self.current].group == group {
            return GroupState::Current;
        }
        let mut node = self.current;
        while node != 0 {
            node = self.nodes[node].parent;
            if node != 0 && self.nodes[node].group == group {
                return GroupState::Buried;
            }
        }
        if self.nodes.iter().skip(1).any(|n| n.group == group) {
            GroupState::Undone
        } else {
            GroupState::Absent
        }
    }

    pub fn can_undo(&self) -> bool {
        self.current != 0
    }

    pub fn can_redo(&self) -> bool {
        !self.nodes[self.current].children.is_empty()
    }

    /// Records a transaction as a new undo step, or merges it into the
    /// current step if both share a group and nothing was undone since.
    pub(crate) fn commit(
        &mut self,
        tx: Transaction,
        inverse: ChangeSet,
        before: Selection,
        after: Selection,
    ) {
        let group = tx.meta.group;
        let index = self.nodes.len();
        let node = &mut self.nodes[self.current];
        let merge =
            self.current != 0 && group.is_some() && node.group == group && node.children.is_empty();
        if merge {
            node.changes = std::mem::take(&mut node.changes)
                .compose(tx.changes.clone())
                .expect("transaction applied on top of this node");
            node.inverse = inverse
                .clone()
                .compose(std::mem::take(&mut node.inverse))
                .expect("inverse applies before this node's inverse");
            node.after = after;
        } else {
            node.children.push(index);
            self.nodes.push(Node {
                parent: self.current,
                children: Vec::new(),
                changes: tx.changes.clone(),
                inverse: inverse.clone(),
                before,
                after,
                group,
            });
            self.current = index;
        }
        self.record(tx, inverse);
    }

    /// Records an undo or redo transaction in the log without touching the
    /// tree.
    pub(crate) fn record(&mut self, tx: Transaction, inverse: ChangeSet) {
        self.log.push(tx);
        self.inverses.push(inverse);
    }

    pub(crate) fn undo_step(&self) -> Option<Step> {
        self.can_undo().then(|| {
            let node = &self.nodes[self.current];
            Step {
                changes: node.inverse.clone(),
                selection: node.before.clone(),
            }
        })
    }

    pub(crate) fn redo_step(&self) -> Option<Step> {
        let &child = self.nodes[self.current].children.last()?;
        let node = &self.nodes[child];
        Some(Step {
            changes: node.changes.clone(),
            selection: node.after.clone(),
        })
    }

    pub(crate) fn move_up(&mut self) {
        self.current = self.nodes[self.current].parent;
    }

    pub(crate) fn move_down(&mut self) {
        if let Some(&child) = self.nodes[self.current].children.last() {
            self.current = child;
        }
    }
}
