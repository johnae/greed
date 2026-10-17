//! Buffer history: an append-only log of every applied transaction, plus an
//! undo tree for navigation.
//!
//! The log is the durable record. Undo and redo don't rewrite it; they apply
//! new transactions (with cause `"undo"` / `"redo"`) and move a pointer in
//! the tree. An edit kept out of undo (`skip`) is the exception: the undo
//! steps are rebased over it, and the log starts again after it.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use greed_text::{Assoc, Author, ChangeSet, Operation, Range, Rope, Selection, Transaction, TxId};
use serde::{Deserialize, Serialize};

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
    /// The last stamp handed to a node; see `Node::stamp`.
    stamps: u64,
}

/// One undo step: one transaction, or several merged by group.
#[derive(Debug)]
struct Node {
    /// Different for every text a node has stood for: a new step, one merged
    /// into, and every step after a rebuild get a new one.
    stamp: u64,
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

/// An undo tree as plain data, to keep it across restarts: what
/// `History::saved` gives and `History::restore` takes back. Only the tree:
/// the log of transactions starts again empty.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SavedHistory {
    /// Node 0 is the root, the text before any of them.
    pub nodes: Vec<SavedNode>,
    /// The node the text is at.
    pub current: usize,
}

/// One undo step of a `SavedHistory`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SavedNode {
    pub parent: usize,
    pub children: Vec<usize>,
    pub changes: Vec<SavedOp>,
    pub inverse: Vec<SavedOp>,
    /// Each range as `[anchor, head]`, the primary first.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<Vec<[usize; 2]>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<Vec<[usize; 2]>>,
    /// Seconds since 1970.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub time: Option<f64>,
}

/// An operation of a change set: a count to keep (positive) or delete
/// (negative), or text to insert.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum SavedOp {
    Count(i64),
    Insert(String),
}

fn save_changes(changes: &ChangeSet) -> Vec<SavedOp> {
    changes
        .ops()
        .iter()
        .map(|op| match op {
            Operation::Retain(n) => SavedOp::Count(i64::try_from(*n).unwrap_or(i64::MAX)),
            Operation::Delete(n) => SavedOp::Count(-i64::try_from(*n).unwrap_or(i64::MAX)),
            Operation::Insert(text) => SavedOp::Insert(text.clone()),
        })
        .collect()
}

fn load_changes(ops: &[SavedOp]) -> Result<ChangeSet, String> {
    let mut changes = ChangeSet::default();
    for op in ops {
        match op {
            SavedOp::Count(0) => return Err("an empty operation".into()),
            SavedOp::Count(n) => {
                let count = usize::try_from(n.unsigned_abs()).map_err(|e| e.to_string())?;
                if *n > 0 {
                    changes.retain(count);
                } else {
                    changes.delete(count);
                }
            }
            SavedOp::Insert(text) => changes.insert(text),
        }
    }
    Ok(changes)
}

fn save_selection(selection: &Selection) -> Vec<[usize; 2]> {
    let mut ranges: Vec<[usize; 2]> = selection
        .ranges()
        .iter()
        .map(|r| [r.anchor, r.head])
        .collect();
    let primary = ranges.remove(selection.primary_index());
    ranges.insert(0, primary);
    ranges
}

/// A saved selection, `None` when it doesn't fit a text of `len` bytes.
fn load_selection(ranges: &[[usize; 2]], len: usize) -> Option<Selection> {
    if ranges.iter().flatten().any(|&pos| pos > len) {
        return None;
    }
    Selection::new(
        ranges
            .iter()
            .map(|&[anchor, head]| Range::new(anchor, head)),
        0,
    )
    .ok()
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
                stamp: 0,
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
            stamps: 0,
        }
    }
}

impl History {
    /// Which text the undo tree is at now, to tell later whether undo or
    /// redo came back to it: `None` when nothing is kept.
    pub fn place(&self) -> Option<u64> {
        self.keep.then(|| self.nodes[self.current].stamp)
    }

    fn next_stamp(&mut self) -> u64 {
        self.stamps += 1;
        self.stamps
    }

    /// A history like a new one, but with stamps after this one's.
    fn fresh(&self) -> Self {
        let mut fresh = Self {
            stamps: self.stamps,
            ..Self::default()
        };
        fresh.nodes[0].stamp = fresh.next_stamp();
        fresh
    }

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
            ..self.fresh()
        };
    }

    /// Empties the log and undo tree and goes on keeping what comes after,
    /// so undo can't go back past now.
    pub(crate) fn clear(&mut self) {
        *self = Self {
            applied: self.applied,
            latest: std::mem::take(&mut self.latest),
            keep: self.keep,
            ..self.fresh()
        };
    }

    /// Every transaction applied to the buffer, oldest first, since the
    /// last edit kept out of undo.
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
        let stamp = self.next_stamp();
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
            node.stamp = stamp;
        } else {
            node.children.push(index);
            self.nodes.push(Node {
                stamp,
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

    /// Takes in `changes`, an edit applied to the text without being kept
    /// to undo, like output streaming into a buffer you type in; `text` is
    /// the text with it. Undo skips it: each step from the current one back
    /// to the root is rebased over it, so undoing them takes back only what
    /// they did and leaves the edit. Steps undo would leave nothing to do
    /// for go, and so do the branches off that path, which redo would reach
    /// but which don't fit the text any more.
    ///
    /// The log starts again after it: it holds every transaction since, as
    /// the text before any of them can be rebuilt from it.
    pub(crate) fn skip(&mut self, changes: ChangeSet, text: &Rope) {
        self.applied += 1;
        if self.keep {
            self.log.clear();
            self.inverses.clear();
            // Steps that no longer fit can't be undone; drop them all rather
            // than undo something else.
            let kept = self.rebase(&changes, text).unwrap_or_default();
            self.nodes[0].children.clear();
            self.nodes.truncate(1);
            for (at, mut step) in kept.into_iter().rev().enumerate() {
                step.parent = at;
                self.nodes[at].children.push(at + 1);
                self.nodes.push(step);
            }
            self.current = self.nodes.len() - 1;
            // Each step now stands for a text it never had.
            for at in 0..self.nodes.len() {
                self.nodes[at].stamp = self.next_stamp();
            }
        }
        self.latest = changes;
    }

    /// The steps from the current one back to the root, rebased over
    /// `changes`, made to the text at the current step; `text` is the text
    /// with `changes` applied. Steps left with nothing to undo are left out.
    /// See `skip`.
    fn rebase(&self, changes: &ChangeSet, text: &Rope) -> Result<Vec<Node>, greed_text::Error> {
        // The edit as it would be made to the text at each step, from the
        // current one back, and that text with it.
        let mut edit = changes.clone();
        let mut text = text.clone();
        let mut kept = Vec::new();
        let mut node = self.current;
        while node != 0 {
            let step = &self.nodes[node];
            // Undoing the step inserts at the edit's place after it, so
            // what the edit inserted stays before what undo puts back.
            let inverse = step.inverse.transform(&edit, Assoc::After)?;
            let earlier = edit.transform(&step.inverse, Assoc::Before)?;
            if !inverse.is_empty() {
                let mut before_step = text.clone();
                inverse.apply(&mut before_step)?;
                kept.push(Node {
                    // Stamped once in the tree.
                    stamp: 0,
                    parent: 0,
                    children: Vec::new(),
                    changes: inverse.invert(&text)?,
                    inverse,
                    before: step.before.as_ref().map(|s| s.map(&earlier)),
                    after: step.after.as_ref().map(|s| s.map(&edit)),
                    group: step.group,
                    author: step.author.clone(),
                    time: step.time,
                });
                text = before_step;
            }
            edit = earlier;
            node = step.parent;
        }
        Ok(kept)
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

    /// The undo tree as plain data, to keep it across restarts; `None`
    /// when nothing is kept or nothing was done.
    pub fn saved(&self) -> Option<SavedHistory> {
        if !self.keep || self.nodes.len() < 2 {
            return None;
        }
        let since = |time: SystemTime| time.duration_since(UNIX_EPOCH).ok();
        let nodes = self
            .nodes
            .iter()
            .map(|node| SavedNode {
                parent: node.parent,
                children: node.children.clone(),
                changes: save_changes(&node.changes),
                inverse: save_changes(&node.inverse),
                before: node.before.as_ref().map(save_selection),
                after: node.after.as_ref().map(save_selection),
                time: node.time.and_then(since).map(|d| d.as_secs_f64()),
            })
            .collect();
        Some(SavedHistory {
            nodes,
            current: self.current,
        })
    }

    /// Takes back an undo tree `saved` gave, for a text of `len` bytes, the
    /// text at its current node. Only before anything was done, and only if
    /// its steps fit together: each one's changes fit the text before it,
    /// and its inverse takes them back. Who made each step isn't kept.
    pub(crate) fn restore(&mut self, saved: &SavedHistory, len: usize) -> Result<(), String> {
        if !self.keep {
            return Err("this buffer keeps no undo history".into());
        }
        if self.nodes.len() > 1 {
            return Err("the buffer was edited since it was loaded".into());
        }
        let count = saved.nodes.len();
        if count < 2 || saved.current >= count {
            return Err("there are no undo steps".into());
        }
        let mut changes = Vec::with_capacity(count);
        for (at, node) in saved.nodes.iter().enumerate() {
            // A step's parent comes before it, and lists it as a child.
            if at > 0 && (node.parent >= at || !saved.nodes[node.parent].children.contains(&at)) {
                return Err(format!("step {at} isn't in the tree"));
            }
            if node.children.iter().any(|&child| child >= count) {
                return Err(format!("step {at} has a child that isn't there"));
            }
            changes.push((load_changes(&node.changes)?, load_changes(&node.inverse)?));
        }
        // How long the text is at each step: from the current one up to the
        // root, then down to the others.
        let mut lens: Vec<Option<usize>> = vec![None; count];
        lens[saved.current] = Some(len);
        let mut at = saved.current;
        while at != 0 {
            let (forward, _) = &changes[at];
            if Some(forward.len_after()) != lens[at] {
                return Err(format!("step {at} doesn't fit the text"));
            }
            let parent = saved.nodes[at].parent;
            lens[parent] = Some(forward.len());
            at = parent;
        }
        for at in 1..count {
            let (forward, inverse) = &changes[at];
            let before = lens[saved.nodes[at].parent].ok_or("a step with no text before it")?;
            let after = forward.len_after();
            let fits = forward.len() == before
                && inverse.len() == after
                && inverse.len_after() == before
                && lens[at].is_none_or(|known| known == after);
            if !fits {
                return Err(format!("step {at} doesn't fit the steps around it"));
            }
            lens[at] = Some(after);
        }
        let mut nodes = Vec::with_capacity(count);
        for (at, (node, (forward, inverse))) in saved.nodes.iter().zip(changes).enumerate() {
            let before_len = lens[node.parent].unwrap_or(0);
            let after_len = lens[at].unwrap_or(0);
            nodes.push(Node {
                stamp: self.next_stamp(),
                parent: node.parent,
                children: node.children.clone(),
                changes: forward,
                inverse,
                before: node
                    .before
                    .as_deref()
                    .and_then(|r| load_selection(r, before_len)),
                after: node
                    .after
                    .as_deref()
                    .and_then(|r| load_selection(r, after_len)),
                group: None,
                author: None,
                time: node
                    .time
                    .filter(|t| t.is_finite() && *t >= 0.0)
                    .map(|t| UNIX_EPOCH + Duration::from_secs_f64(t)),
            });
        }
        self.nodes = nodes;
        self.current = saved.current;
        Ok(())
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
