//! Buffer history: an append-only log of every applied transaction, plus an
//! undo tree for navigation.
//!
//! The log is the durable record. Undo and redo don't rewrite it; they apply
//! new transactions (with cause `"undo"` / `"redo"`) and move a pointer in
//! the tree.

use std::time::SystemTime;

use greed_text::{Author, ChangeSet, Rope, Selection, Transaction, TxId};

#[derive(Debug)]
pub struct History {
    log: Vec<Transaction>,
    /// The inverse of each transaction in the log, so earlier texts can be
    /// rebuilt.
    inverses: Vec<ChangeSet>,
    /// Undo tree. Node 0 is the root: the buffer as it was loaded.
    nodes: Vec<Node>,
    current: usize,
    /// How many transactions were applied, kept or not.
    applied: usize,
    /// The changes of the latest transaction, kept or not, for mapping
    /// other views' selections through it.
    latest: ChangeSet,
    /// Whether transactions are kept at all; buffers whose edits nobody
    /// undoes, like terminals, don't.
    keep: bool,
}

/// One undo step: one transaction, or several merged by group.
#[derive(Debug)]
struct Node {
    parent: usize,
    /// The last child is the one redo follows.
    children: Vec<usize>,
    changes: ChangeSet,
    inverse: ChangeSet,
    /// The selections undo and redo restore; `None` for an edit made without
    /// a view, which views move along with instead.
    before: Option<Selection>,
    after: Option<Selection>,
    group: Option<u64>,
    /// Who made it; the root, the buffer as loaded, has nobody.
    author: Option<Author>,
    /// When it was last added to: the step's latest transaction. The root,
    /// the buffer as loaded, has none.
    time: Option<SystemTime>,
}

/// A node of the undo tree, as `History::tree` shows it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TreeNode {
    /// Its index; 0 is the root, the buffer as it was loaded, and later
    /// steps have higher ones.
    pub id: usize,
    pub parent: Option<usize>,
    /// Oldest first; redo follows the last.
    pub children: Vec<usize>,
    pub time: Option<SystemTime>,
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

/// A change set to apply for an undo or redo, and the selection to restore,
/// if the step has one.
pub(crate) struct Step {
    pub changes: ChangeSet,
    pub selection: Option<Selection>,
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
                before: None,
                after: None,
                group: None,
                author: None,
                time: None,
            }],
            current: 0,
            applied: 0,
            latest: ChangeSet::default(),
            keep: true,
        }
    }
}

impl History {
    /// How many transactions were applied to the buffer, kept in the log or
    /// not: its version, for caches that follow its edits.
    pub fn applied(&self) -> usize {
        self.applied
    }

    /// The changes of the latest transaction applied, whether it was kept.
    pub fn latest(&self) -> &ChangeSet {
        &self.latest
    }

    /// Stops keeping transactions: the log and undo tree are emptied and stay
    /// empty, while `applied` and `latest` go on following edits.
    pub(crate) fn forget(&mut self) {
        *self = Self {
            applied: self.applied,
            keep: false,
            ..Self::default()
        };
    }

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
        before: Option<Selection>,
        after: Option<Selection>,
    ) {
        if !self.keep {
            self.record(tx, inverse);
            return;
        }
        let group = tx.meta.group;
        let time = Some(tx.meta.time);
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
            node.time = time;
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
                author: Some(tx.meta.author.clone()),
                time,
            });
            self.current = index;
        }
        self.record(tx, inverse);
    }

    /// Who made the step undo would take back, if there is one.
    pub fn undo_author(&self) -> Option<&Author> {
        self.nodes[self.current].author.as_ref()
    }

    /// Who made the step redo would do again, if there is one.
    pub fn redo_author(&self) -> Option<&Author> {
        let &child = self.nodes[self.current].children.last()?;
        self.nodes[child].author.as_ref()
    }

    /// Records an undo or redo transaction in the log without touching the
    /// tree.
    pub(crate) fn record(&mut self, tx: Transaction, inverse: ChangeSet) {
        self.applied += 1;
        if self.keep {
            self.latest = tx.changes.clone();
            self.log.push(tx);
            self.inverses.push(inverse);
        } else {
            self.latest = tx.changes;
        }
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

    /// The undo tree's nodes, by id.
    pub fn tree(&self) -> Vec<TreeNode> {
        self.nodes
            .iter()
            .enumerate()
            .map(|(id, node)| TreeNode {
                id,
                parent: (id != 0).then_some(node.parent),
                children: node.children.clone(),
                time: node.time,
            })
            .collect()
    }

    /// The node the text is at now.
    pub fn current(&self) -> usize {
        self.current
    }

    /// How to get from the current node to `target`: how many undos up to
    /// where their paths meet, then the nodes to redo down to it. `None` if
    /// there's no such node.
    pub fn path_to(&self, target: usize) -> Option<(usize, Vec<usize>)> {
        if target >= self.nodes.len() {
            return None;
        }
        let ancestors = |mut node: usize| {
            let mut chain = vec![node];
            while node != 0 {
                node = self.nodes[node].parent;
                chain.push(node);
            }
            chain
        };
        let from = ancestors(self.current);
        let mut down = Vec::new();
        let mut node = target;
        let up = loop {
            if let Some(up) = from.iter().position(|&n| n == node) {
                break up;
            }
            down.push(node);
            node = self.nodes[node].parent;
        };
        down.reverse();
        Some((up, down))
    }

    /// Makes redo from `child`'s parent follow `child`, as it does after
    /// going down that branch.
    pub(crate) fn prefer(&mut self, child: usize) {
        let parent = self.nodes[child].parent;
        let children = &mut self.nodes[parent].children;
        if let Some(at) = children.iter().position(|&c| c == child) {
            let child = children.remove(at);
            children.push(child);
        }
    }
}
