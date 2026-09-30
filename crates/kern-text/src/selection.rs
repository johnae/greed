//! Ranges and selections.
//!
//! A [`Range`] has an anchor (where it started) and a head (where the cursor
//! is). A [`Selection`] is a sorted set of non-overlapping ranges, one of
//! which is primary. A cursor is an empty range.

use smallvec::SmallVec;

use crate::{Assoc, ChangeSet, Error};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Range {
    pub anchor: usize,
    pub head: usize,
}

impl Range {
    pub fn new(anchor: usize, head: usize) -> Self {
        Self { anchor, head }
    }

    pub fn point(pos: usize) -> Self {
        Self::new(pos, pos)
    }

    pub fn from(&self) -> usize {
        self.anchor.min(self.head)
    }

    pub fn to(&self) -> usize {
        self.anchor.max(self.head)
    }

    pub fn len(&self) -> usize {
        self.to() - self.from()
    }

    pub fn is_empty(&self) -> bool {
        self.anchor == self.head
    }

    /// True if the head is before the anchor.
    pub fn is_backward(&self) -> bool {
        self.head < self.anchor
    }

    #[must_use]
    pub fn flip(&self) -> Self {
        Self::new(self.head, self.anchor)
    }

    /// Maps the range through a change.
    ///
    /// A cursor moves along with text inserted at it. A range doesn't grow
    /// to include text inserted at its edges. If the change replaces all of
    /// the range's text, the range selects the replacement.
    #[must_use]
    pub fn map(&self, changes: &ChangeSet) -> Self {
        if self.is_empty() {
            return Self::point(changes.map_pos(self.head, Assoc::After));
        }
        let mut from = changes.map_pos(self.from(), Assoc::After);
        let mut to = changes.map_pos(self.to(), Assoc::Before);
        if from >= to {
            from = changes.map_pos(self.from(), Assoc::Before);
            to = changes.map_pos(self.to(), Assoc::After);
        }
        self.with_bounds(from, to)
    }

    /// A range over `from..to` pointing the same way as `self`.
    fn with_bounds(self, from: usize, to: usize) -> Self {
        if self.is_backward() {
            Self::new(to, from)
        } else {
            Self::new(from, to)
        }
    }

    /// True if the two ranges must be merged in a selection: they share
    /// text, or they are cursors at the same position. Ranges that only
    /// touch stay separate.
    fn overlaps(&self, other: &Self) -> bool {
        (self.from() < other.to() && other.from() < self.to())
            || (self.is_empty() && other.is_empty() && self.head == other.head)
    }
}

/// One or more ranges, sorted by position and never overlapping. Exactly one
/// range is primary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Selection {
    ranges: SmallVec<[Range; 1]>,
    primary: usize,
}

#[expect(
    clippy::len_without_is_empty,
    reason = "a selection always has a range"
)]
impl Selection {
    /// Builds a selection, sorting the ranges and merging any that overlap.
    /// `primary` indexes into `ranges` as given, and is clamped to the last
    /// range if out of bounds.
    pub fn new(ranges: impl IntoIterator<Item = Range>, primary: usize) -> Result<Self, Error> {
        let mut ranges: SmallVec<[(Range, bool); 1]> = ranges
            .into_iter()
            .enumerate()
            .map(|(i, r)| (r, i == primary))
            .collect();
        if ranges.is_empty() {
            return Err(Error::EmptySelection);
        }
        if !ranges.iter().any(|(_, p)| *p) {
            ranges.last_mut().expect("not empty").1 = true;
        }
        Ok(Self::normalize(ranges))
    }

    pub fn single(anchor: usize, head: usize) -> Self {
        Self {
            ranges: SmallVec::from_buf([Range::new(anchor, head)]),
            primary: 0,
        }
    }

    pub fn point(pos: usize) -> Self {
        Self::single(pos, pos)
    }

    pub fn ranges(&self) -> &[Range] {
        &self.ranges
    }

    pub fn primary(&self) -> Range {
        self.ranges[self.primary]
    }

    pub fn primary_index(&self) -> usize {
        self.primary
    }

    pub fn len(&self) -> usize {
        self.ranges.len()
    }

    /// Adds a range and makes it primary.
    #[must_use]
    pub fn push(self, range: Range) -> Self {
        let ranges = self
            .ranges
            .into_iter()
            .map(|r| (r, false))
            .chain([(range, true)])
            .collect();
        Self::normalize(ranges)
    }

    /// Maps every range through a change. Ranges that end up overlapping are
    /// merged.
    #[must_use]
    pub fn map(&self, changes: &ChangeSet) -> Self {
        let ranges = self
            .ranges
            .iter()
            .enumerate()
            .map(|(i, r)| (r.map(changes), i == self.primary))
            .collect();
        Self::normalize(ranges)
    }

    /// Sorts and merges `(range, is_primary)` pairs. Exactly one pair must be
    /// marked primary.
    fn normalize(mut ranges: SmallVec<[(Range, bool); 1]>) -> Self {
        ranges.sort_by_key(|(r, _)| (r.from(), r.to()));
        let mut merged: SmallVec<[(Range, bool); 1]> = SmallVec::with_capacity(ranges.len());
        for (range, is_primary) in ranges {
            match merged.last_mut() {
                Some((last, last_primary)) if last.overlaps(&range) => {
                    *last = last.with_bounds(last.from(), last.to().max(range.to()));
                    *last_primary |= is_primary;
                }
                _ => merged.push((range, is_primary)),
            }
        }
        let primary = merged.iter().position(|(_, p)| *p).expect("one primary");
        Self {
            ranges: merged.into_iter().map(|(r, _)| r).collect(),
            primary,
        }
    }
}
