//! Buffer history: an append-only log of every applied transaction, plus an
//! undo tree for navigation.
//!
//! The log is the durable record. Undo and redo don't rewrite it; they apply
//! new transactions (with cause `"undo"` / `"redo"`) and move a pointer in
//! the tree.

use kern_text::{Author, ChangeSet, Selection, Transaction};

#[derive(Debug)]
pub struct History {
    log: Vec<Transaction>,
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

/// A change set to apply for an undo or redo, and the selection to restore.
pub(crate) struct Step {
    pub changes: ChangeSet,
    pub selection: Selection,
}

impl Default for History {
    fn default() -> Self {
        Self {
            log: Vec::new(),
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
                .compose(std::mem::take(&mut node.inverse))
                .expect("inverse applies before this node's inverse");
            node.after = after;
        } else {
            node.children.push(index);
            self.nodes.push(Node {
                parent: self.current,
                children: Vec::new(),
                changes: tx.changes.clone(),
                inverse,
                before,
                after,
                group,
            });
            self.current = index;
        }
        self.log.push(tx);
    }

    /// Records an undo or redo transaction in the log without touching the
    /// tree.
    pub(crate) fn record(&mut self, tx: Transaction) {
        self.log.push(tx);
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
