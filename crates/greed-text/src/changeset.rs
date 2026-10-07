//! Change sets: the only way text in a buffer changes.
//!
//! A [`ChangeSet`] walks a document from start to end as a sequence of
//! retain/delete/insert operations. All lengths and positions are byte
//! offsets; operations must land on char boundaries when applied to text.

use ropey::Rope;

use crate::Error;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Operation {
    /// Keep the next `n` bytes.
    Retain(usize),
    /// Remove the next `n` bytes.
    Delete(usize),
    /// Insert text at the current position.
    Insert(String),
}

/// Which side of an insertion a position sticks to when mapped through a
/// change at that exact position.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Assoc {
    /// Stay before text inserted at the position.
    Before,
    /// Move after text inserted at the position.
    After,
}

/// A sequence of operations over a document of [`len`](Self::len) bytes.
///
/// Change sets are kept in canonical form: no empty operations, adjacent
/// operations of the same kind are merged, and an insert always comes
/// before a delete at the same position. Two change sets with the same
/// effect therefore compare equal.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ChangeSet {
    ops: Vec<Operation>,
    len: usize,
    len_after: usize,
}

impl ChangeSet {
    /// A change set that leaves a document of `len` bytes unchanged.
    pub fn identity(len: usize) -> Self {
        let mut cs = Self::default();
        cs.retain(len);
        cs
    }

    /// Builds a change set from `(from, to, replacement)` byte ranges over a
    /// document of `len` bytes. Ranges must be sorted and must not overlap;
    /// touching ranges are fine.
    pub fn from_changes<I, S>(len: usize, changes: I) -> Result<Self, Error>
    where
        I: IntoIterator<Item = (usize, usize, Option<S>)>,
        S: AsRef<str>,
    {
        let mut cs = Self::default();
        let mut pos = 0;
        for (from, to, text) in changes {
            if from < pos || to < from {
                return Err(Error::OverlappingChanges { at: from.min(to) });
            }
            if to > len {
                return Err(Error::OutOfBounds { pos: to, len });
            }
            cs.retain(from - pos);
            if let Some(text) = text {
                cs.insert(text.as_ref());
            }
            cs.delete(to - from);
            pos = to;
        }
        cs.retain(len - pos);
        Ok(cs)
    }

    pub fn ops(&self) -> &[Operation] {
        &self.ops
    }

    /// Length in bytes of the document this change set applies to.
    pub fn len(&self) -> usize {
        self.len
    }

    /// Length in bytes of the document after applying this change set.
    pub fn len_after(&self) -> usize {
        self.len_after
    }

    /// True if applying this change set leaves the document unchanged.
    pub fn is_empty(&self) -> bool {
        self.ops.iter().all(|op| matches!(op, Operation::Retain(_)))
    }

    /// The bytes of the document after applying this change set that it
    /// inserted, from the first change to the end of the last one: empty
    /// where it only deleted, `None` when it changes nothing.
    pub fn changed_range(&self) -> Option<std::ops::Range<usize>> {
        let mut new = 0;
        let mut first = None;
        for op in &self.ops {
            let start = new;
            match op {
                Operation::Retain(n) => {
                    new += n;
                    continue;
                }
                Operation::Delete(_) => {}
                Operation::Insert(text) => new += text.len(),
            }
            first.get_or_insert(start);
        }
        // Trailing retains don't count: the range ends after the last change.
        let mut end = new;
        if let Some(Operation::Retain(n)) = self.ops.last() {
            end -= n;
        }
        first.map(|start| start..end)
    }

    pub fn retain(&mut self, n: usize) {
        if n == 0 {
            return;
        }
        self.len += n;
        self.len_after += n;
        if let Some(Operation::Retain(last)) = self.ops.last_mut() {
            *last += n;
        } else {
            self.ops.push(Operation::Retain(n));
        }
    }

    pub fn delete(&mut self, n: usize) {
        if n == 0 {
            return;
        }
        self.len += n;
        if let Some(Operation::Delete(last)) = self.ops.last_mut() {
            *last += n;
        } else {
            self.ops.push(Operation::Delete(n));
        }
    }

    pub fn insert(&mut self, text: &str) {
        if text.is_empty() {
            return;
        }
        self.len_after += text.len();
        match self.ops.as_mut_slice() {
            [.., Operation::Insert(last)] | [.., Operation::Insert(last), Operation::Delete(_)] => {
                last.push_str(text);
            }
            [.., Operation::Delete(_)] => {
                let delete = self.ops.pop().expect("matched a delete");
                self.ops.push(Operation::Insert(text.to_owned()));
                self.ops.push(delete);
            }
            _ => self.ops.push(Operation::Insert(text.to_owned())),
        }
    }

    /// Applies the change set to `rope`. The rope is left untouched if the
    /// change set doesn't fit it.
    pub fn apply(&self, rope: &mut Rope) -> Result<(), Error> {
        self.check_fits(rope)?;
        let mut pos = 0;
        for op in &self.ops {
            match op {
                Operation::Retain(n) => pos += n,
                Operation::Delete(n) => {
                    let from = rope.byte_to_char(pos);
                    let to = rope.byte_to_char(pos + n);
                    rope.remove(from..to);
                }
                Operation::Insert(text) => {
                    rope.insert(rope.byte_to_char(pos), text);
                    pos += text.len();
                }
            }
        }
        Ok(())
    }

    /// Returns the change set that undoes this one. `original` is the
    /// document as it was before this change set was applied.
    pub fn invert(&self, original: &Rope) -> Result<Self, Error> {
        self.check_fits(original)?;
        let mut inverse = Self::default();
        let mut pos = 0;
        for op in &self.ops {
            match op {
                Operation::Retain(n) => {
                    inverse.retain(*n);
                    pos += n;
                }
                Operation::Delete(n) => {
                    let from = original.byte_to_char(pos);
                    let to = original.byte_to_char(pos + n);
                    inverse.insert(&original.slice(from..to).to_string());
                    pos += n;
                }
                Operation::Insert(text) => inverse.delete(text.len()),
            }
        }
        Ok(inverse)
    }

    /// Combines `self` followed by `other` into a single change set.
    pub fn compose(self, other: Self) -> Result<Self, Error> {
        if self.len_after != other.len {
            return Err(Error::LengthMismatch {
                expected: self.len_after,
                actual: other.len,
            });
        }

        let mut out = Self::default();
        let mut a_ops = self.ops.into_iter();
        let mut b_ops = other.ops.into_iter();
        let mut a = a_ops.next();
        let mut b = b_ops.next();
        // Byte position in the intermediate document, for error reporting.
        let mut mid = 0;

        loop {
            match (a, b) {
                (None, None) => break,
                (Some(Operation::Delete(n)), rest) => {
                    out.delete(n);
                    a = a_ops.next();
                    b = rest;
                }
                (rest, Some(Operation::Insert(text))) => {
                    out.insert(&text);
                    a = rest;
                    b = b_ops.next();
                }
                (Some(Operation::Retain(i)), Some(Operation::Retain(j))) => {
                    let n = i.min(j);
                    out.retain(n);
                    mid += n;
                    a = remainder(Operation::Retain(i - n), &mut a_ops);
                    b = remainder(Operation::Retain(j - n), &mut b_ops);
                }
                (Some(Operation::Retain(i)), Some(Operation::Delete(j))) => {
                    let n = i.min(j);
                    out.delete(n);
                    mid += n;
                    a = remainder(Operation::Retain(i - n), &mut a_ops);
                    b = remainder(Operation::Delete(j - n), &mut b_ops);
                }
                (Some(Operation::Insert(text)), Some(Operation::Retain(j))) => {
                    let (kept, rest) = split_insert(text, j, mid)?;
                    out.insert(&kept);
                    mid += kept.len();
                    a = remainder(Operation::Insert(rest), &mut a_ops);
                    b = remainder(Operation::Retain(j - kept.len()), &mut b_ops);
                }
                (Some(Operation::Insert(text)), Some(Operation::Delete(j))) => {
                    let (deleted, rest) = split_insert(text, j, mid)?;
                    mid += deleted.len();
                    a = remainder(Operation::Insert(rest), &mut a_ops);
                    b = remainder(Operation::Delete(j - deleted.len()), &mut b_ops);
                }
                // Lengths were checked up front, so both sides run out together.
                (None, Some(_)) | (Some(_), None) => unreachable!("change set lengths disagree"),
            }
        }
        Ok(out)
    }

    /// Maps a byte position in the original document to the corresponding
    /// position after the change. A position at the start of or inside
    /// deleted or replaced text maps to the start of the replacement for
    /// [`Assoc::Before`] and to its end for [`Assoc::After`]; a position at
    /// its end stays after the replacement.
    ///
    /// Mapping through a composed change set matches mapping through its
    /// parts one after another, except for positions touching deleted text:
    /// canonical form can't tell "insert, then delete what follows" from
    /// "delete, then insert", which map those positions differently.
    pub fn map_pos(&self, pos: usize, assoc: Assoc) -> usize {
        let mut old = 0;
        let mut new = 0;
        let mut ops = self.ops.iter().peekable();
        while let Some(op) = ops.next() {
            match op {
                Operation::Retain(n) => {
                    if pos < old + n {
                        return new + (pos - old);
                    }
                    old += n;
                    new += n;
                }
                Operation::Delete(n) => {
                    if pos < old + n {
                        return new;
                    }
                    old += n;
                }
                Operation::Insert(text) => {
                    let replaced = match ops.peek() {
                        Some(Operation::Delete(n)) => *n,
                        _ => 0,
                    };
                    let touches = (old..old + replaced.max(1)).contains(&pos);
                    if touches && assoc == Assoc::Before {
                        return new;
                    }
                    new += text.len();
                }
            }
        }
        new
    }

    /// Checks that the change set's length matches `rope` and that every
    /// operation boundary falls on a char boundary.
    fn check_fits(&self, rope: &Rope) -> Result<(), Error> {
        if self.len != rope.len_bytes() {
            return Err(Error::LengthMismatch {
                expected: self.len,
                actual: rope.len_bytes(),
            });
        }
        let mut pos = 0;
        for op in &self.ops {
            if !is_char_boundary(rope, pos) {
                return Err(Error::NotCharBoundary { pos });
            }
            if let Operation::Retain(n) | Operation::Delete(n) = op {
                pos += n;
            }
        }
        Ok(())
    }
}

pub(crate) fn is_char_boundary(rope: &Rope, byte: usize) -> bool {
    rope.char_to_byte(rope.byte_to_char(byte)) == byte
}

/// Returns `op` if it still has length left, otherwise the next operation.
fn remainder(op: Operation, ops: &mut impl Iterator<Item = Operation>) -> Option<Operation> {
    match op {
        Operation::Retain(0) | Operation::Delete(0) => ops.next(),
        Operation::Insert(text) if text.is_empty() => ops.next(),
        op => Some(op),
    }
}

/// Splits inserted text at byte `at`, returning the part before and whatever
/// is left after (empty if `at` is past the end). `mid` is the text's
/// position in the intermediate document.
fn split_insert(mut text: String, at: usize, mid: usize) -> Result<(String, String), Error> {
    if at >= text.len() {
        return Ok((text, String::new()));
    }
    if !text.is_char_boundary(at) {
        return Err(Error::NotCharBoundary { pos: mid + at });
    }
    let rest = text.split_off(at);
    Ok((text, rest))
}
