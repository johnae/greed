//! Panes: how a tab's area is split between views, as a tree. Each split
//! lays its children side by side or one above another, sharing the room by
//! weight, with a one-cell line between neighbors.

use crate::ViewId;
use crate::render::Rect;

/// Which way a split lays out its children.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Axis {
    /// Side by side, with lines down between them.
    Across,
    /// One above another, with lines across between them.
    Down,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Left,
    Right,
    Up,
    Down,
}

impl Direction {
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "left" => Direction::Left,
            "right" => Direction::Right,
            "up" => Direction::Up,
            "down" => Direction::Down,
            _ => return None,
        })
    }

    pub fn axis(self) -> Axis {
        match self {
            Direction::Left | Direction::Right => Axis::Across,
            Direction::Up | Direction::Down => Axis::Down,
        }
    }

    /// Whether it points to the right or down, where later children are.
    fn forward(self) -> bool {
        matches!(self, Direction::Right | Direction::Down)
    }
}

/// A line drawn between two panes: down from (`x`, `y`) when `down`,
/// across otherwise, `len` cells long.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Line {
    pub x: u16,
    pub y: u16,
    pub len: u16,
    pub down: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Node {
    Pane(ViewId),
    Split {
        axis: Axis,
        /// Children and their weights.
        children: Vec<(Node, u32)>,
    },
}

/// The weight a new split's children start with, big enough to halve many
/// times.
const WEIGHT: u32 = 1024;

impl Node {
    /// The panes, left to right and top to bottom.
    pub fn panes(&self) -> Vec<ViewId> {
        let mut panes = Vec::new();
        self.collect(&mut panes);
        panes
    }

    fn collect(&self, panes: &mut Vec<ViewId>) {
        match self {
            Node::Pane(view) => panes.push(*view),
            Node::Split { children, .. } => {
                for (child, _) in children {
                    child.collect(panes);
                }
            }
        }
    }

    /// Whether every split has children, with weights.
    pub fn is_whole(&self) -> bool {
        match self {
            Node::Pane(_) => true,
            Node::Split { children, .. } => {
                !children.is_empty() && children.iter().all(|(c, w)| *w > 0 && c.is_whole())
            }
        }
    }

    pub fn contains(&self, view: ViewId) -> bool {
        match self {
            Node::Pane(v) => *v == view,
            Node::Split { children, .. } => children.iter().any(|(c, _)| c.contains(view)),
        }
    }

    /// Puts `new` beside `target`, on its `dir` side, in half of its room.
    /// Returns false if `target` isn't here.
    pub fn insert(&mut self, target: ViewId, new: ViewId, dir: Direction) -> bool {
        match self {
            Node::Pane(view) if *view == target => {
                let (old, new) = (Node::Pane(target), Node::Pane(new));
                let (first, second) = if dir.forward() {
                    (old, new)
                } else {
                    (new, old)
                };
                *self = Node::Split {
                    axis: dir.axis(),
                    children: vec![(first, WEIGHT), (second, WEIGHT)],
                };
                true
            }
            Node::Pane(_) => false,
            Node::Split { axis, children } => {
                let direct = children.iter().position(|(c, _)| *c == Node::Pane(target));
                if let Some(i) = direct
                    && *axis == dir.axis()
                {
                    let half = children[i].1 / 2;
                    children[i].1 -= half;
                    let at = if dir.forward() { i + 1 } else { i };
                    children.insert(at, (Node::Pane(new), half.max(1)));
                    return true;
                }
                children.iter_mut().any(|(c, _)| c.insert(target, new, dir))
            }
        }
    }

    /// Takes `view` out, giving its room to a neighbor. A split left with
    /// one child becomes that child. Returns false if `view` isn't in a
    /// split here.
    pub fn remove(&mut self, view: ViewId) -> bool {
        let Node::Split { children, .. } = self else {
            return false;
        };
        if let Some(i) = children.iter().position(|(c, _)| *c == Node::Pane(view)) {
            let (_, weight) = children.remove(i);
            let neighbor = i.min(children.len().saturating_sub(1));
            if let Some((_, w)) = children.get_mut(neighbor) {
                *w = w.saturating_add(weight);
            }
            if children.len() == 1
                && let Some((only, _)) = children.pop()
            {
                *self = only;
            }
            return true;
        }
        children.iter_mut().any(|(c, _)| c.remove(view))
    }

    /// Where each pane goes in `rect`, and the lines between them.
    pub fn place(&self, rect: Rect, panes: &mut Vec<(ViewId, Rect)>, lines: &mut Vec<Line>) {
        match self {
            Node::Pane(view) => panes.push((*view, rect)),
            Node::Split { axis, children } => {
                let rects = child_rects(*axis, children, rect);
                for (i, ((child, _), r)) in children.iter().zip(&rects).enumerate() {
                    child.place(*r, panes, lines);
                    if i + 1 < rects.len() {
                        lines.push(match axis {
                            Axis::Across => Line {
                                x: r.x.saturating_add(r.width),
                                y: rect.y,
                                len: rect.height,
                                down: true,
                            },
                            Axis::Down => Line {
                                x: rect.x,
                                y: r.y.saturating_add(r.height),
                                len: rect.width,
                                down: false,
                            },
                        });
                    }
                }
            }
        }
    }

    /// Moves the edge of `view` on its `dir` side by `cells`, growing it
    /// (or shrinking it, for negative `cells`) at the neighbor's expense.
    /// The innermost split with a neighbor on that side gives. Returns
    /// false when there's nothing on that side.
    pub fn resize(&mut self, view: ViewId, dir: Direction, cells: i32, rect: Rect) -> bool {
        let Node::Split { axis, children } = self else {
            return false;
        };
        let rects = child_rects(*axis, children, rect);
        let Some(i) = children.iter().position(|(c, _)| c.contains(view)) else {
            return false;
        };
        if children[i].0.resize(view, dir, cells, rects[i]) {
            return true;
        }
        if *axis != dir.axis() {
            return false;
        }
        let j = if dir.forward() {
            Some(i + 1)
        } else {
            i.checked_sub(1)
        };
        let Some(j) = j.filter(|j| *j < children.len()) else {
            return false;
        };
        let mut sizes: Vec<i32> = rects.iter().map(|r| i32::from(length(*axis, *r))).collect();
        // Each keeps a cell, if the two have one each to keep.
        let (least, most) = (-(sizes[i] - 1), sizes[j] - 1);
        let change = if least <= most {
            cells.clamp(least, most)
        } else {
            0
        };
        sizes[i] += change;
        sizes[j] -= change;
        for ((_, weight), size) in children.iter_mut().zip(sizes) {
            *weight = u32::try_from(size.max(1)).unwrap_or(1);
        }
        true
    }
}

fn length(axis: Axis, rect: Rect) -> u16 {
    match axis {
        Axis::Across => rect.width,
        Axis::Down => rect.height,
    }
}

/// Shares `rect` between `children` by weight, less a cell between each.
fn child_rects(axis: Axis, children: &[(Node, u32)], rect: Rect) -> Vec<Rect> {
    let n = u16::try_from(children.len()).unwrap_or(u16::MAX);
    let room = u64::from(length(axis, rect).saturating_sub(n.saturating_sub(1)));
    let total: u64 = children
        .iter()
        .map(|(_, w)| u64::from(*w))
        .sum::<u64>()
        .max(1);
    let mut start = match axis {
        Axis::Across => rect.x,
        Axis::Down => rect.y,
    };
    let mut given = 0;
    let mut rects = Vec::with_capacity(children.len());
    for (i, (_, weight)) in children.iter().enumerate() {
        let size = if i + 1 == children.len() {
            room - given
        } else {
            (room * u64::from(*weight) / total).min(room - given)
        };
        given += size;
        let size = u16::try_from(size).unwrap_or(u16::MAX);
        rects.push(match axis {
            Axis::Across => Rect {
                x: start,
                width: size,
                ..rect
            },
            Axis::Down => Rect {
                y: start,
                height: size,
                ..rect
            },
        });
        start = start.saturating_add(size).saturating_add(1);
    }
    rects
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: ViewId = ViewId(1);
    const B: ViewId = ViewId(2);
    const C: ViewId = ViewId(3);

    fn rect(width: u16, height: u16) -> Rect {
        Rect {
            x: 0,
            y: 0,
            width,
            height,
        }
    }

    fn placed(node: &Node, width: u16, height: u16) -> (Vec<(ViewId, Rect)>, Vec<Line>) {
        let (mut panes, mut lines) = (Vec::new(), Vec::new());
        node.place(rect(width, height), &mut panes, &mut lines);
        (panes, lines)
    }

    fn at(x: u16, y: u16, width: u16, height: u16) -> Rect {
        Rect {
            x,
            y,
            width,
            height,
        }
    }

    #[test]
    fn splitting_shares_the_room_with_a_line_between() {
        let mut node = Node::Pane(A);
        assert!(node.insert(A, B, Direction::Right));
        let (panes, lines) = placed(&node, 21, 10);
        assert_eq!(panes, [(A, at(0, 0, 10, 10)), (B, at(11, 0, 10, 10))]);
        assert_eq!(
            lines,
            [Line {
                x: 10,
                y: 0,
                len: 10,
                down: true
            }]
        );
        // Splitting B the same way halves B's room; across, it nests.
        assert!(node.insert(B, C, Direction::Down));
        let (panes, _) = placed(&node, 21, 11);
        assert_eq!(
            panes,
            [
                (A, at(0, 0, 10, 11)),
                (B, at(11, 0, 10, 5)),
                (C, at(11, 6, 10, 5))
            ]
        );
        assert_eq!(node.panes(), [A, B, C]);
    }

    #[test]
    fn splitting_left_or_up_puts_the_new_pane_first() {
        let mut node = Node::Pane(A);
        node.insert(A, B, Direction::Left);
        node.insert(A, C, Direction::Left);
        assert_eq!(node.panes(), [B, C, A]);
    }

    #[test]
    fn removing_a_pane_gives_its_room_away_and_collapses_splits() {
        let mut node = Node::Pane(A);
        node.insert(A, B, Direction::Right);
        node.insert(B, C, Direction::Down);
        assert!(node.remove(C));
        assert_eq!(placed(&node, 21, 10).0[1], (B, at(11, 0, 10, 10)));
        assert!(node.remove(A));
        assert_eq!(node, Node::Pane(B));
        assert!(!node.remove(B), "the last pane stays");
    }

    #[test]
    fn resizing_moves_the_edge_between_neighbors() {
        let mut node = Node::Pane(A);
        node.insert(A, B, Direction::Right);
        node.insert(B, C, Direction::Down);
        assert!(node.resize(A, Direction::Right, 4, rect(21, 11)));
        assert_eq!(placed(&node, 21, 11).0[0], (A, at(0, 0, 14, 11)));
        // B's right has nothing, but its left does: the same edge.
        assert!(!node.resize(B, Direction::Right, 1, rect(21, 11)));
        assert!(node.resize(B, Direction::Left, 2, rect(21, 11)));
        assert_eq!(placed(&node, 21, 11).0[0], (A, at(0, 0, 12, 11)));
        // Down from B moves the line between B and C, not anything outside.
        assert!(node.resize(B, Direction::Down, 2, rect(21, 11)));
        assert_eq!(placed(&node, 21, 11).0[1], (B, at(13, 0, 8, 7)));
        // No pane shrinks away.
        assert!(node.resize(A, Direction::Right, 100, rect(21, 11)));
        assert_eq!(placed(&node, 21, 11).0[1].1.width, 1);
    }
}
