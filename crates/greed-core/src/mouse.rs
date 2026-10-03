//! Mouse input: what a client saw the mouse do, and where on the screen.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Button {
    Left,
    Middle,
    Right,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MouseKind {
    Press(Button),
    Release(Button),
    /// Moved with the button held.
    Drag(Button),
    /// Moved with no button held.
    Move,
    ScrollUp,
    ScrollDown,
    ScrollLeft,
    ScrollRight,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Mouse {
    pub kind: MouseKind,
    /// The screen cell, from the top left.
    pub col: u16,
    pub row: u16,
    #[serde(default)]
    pub ctrl: bool,
    #[serde(default)]
    pub alt: bool,
    #[serde(default)]
    pub shift: bool,
}

impl MouseKind {
    /// The event Luau names `kind`, with a button (default left) or a
    /// scroll direction as `which`.
    pub fn parse(kind: &str, which: Option<&str>) -> Option<Self> {
        let button = || Button::parse(which.unwrap_or("left"));
        Some(match kind {
            "press" => MouseKind::Press(button()?),
            "release" => MouseKind::Release(button()?),
            "drag" => MouseKind::Drag(button()?),
            "move" => MouseKind::Move,
            "scroll" => match which? {
                "up" => MouseKind::ScrollUp,
                "down" => MouseKind::ScrollDown,
                "left" => MouseKind::ScrollLeft,
                "right" => MouseKind::ScrollRight,
                _ => return None,
            },
            _ => return None,
        })
    }

    /// What Luau calls it: "press", "release", "drag", "move" or "scroll".
    pub fn name(self) -> &'static str {
        match self {
            MouseKind::Press(_) => "press",
            MouseKind::Release(_) => "release",
            MouseKind::Drag(_) => "drag",
            MouseKind::Move => "move",
            MouseKind::ScrollUp
            | MouseKind::ScrollDown
            | MouseKind::ScrollLeft
            | MouseKind::ScrollRight => "scroll",
        }
    }

    pub fn button(self) -> Option<Button> {
        match self {
            MouseKind::Press(b) | MouseKind::Release(b) | MouseKind::Drag(b) => Some(b),
            _ => None,
        }
    }

    /// Which way a scroll goes: "up", "down", "left" or "right".
    pub fn direction(self) -> Option<&'static str> {
        Some(match self {
            MouseKind::ScrollUp => "up",
            MouseKind::ScrollDown => "down",
            MouseKind::ScrollLeft => "left",
            MouseKind::ScrollRight => "right",
            _ => return None,
        })
    }
}

impl Button {
    pub fn name(self) -> &'static str {
        match self {
            Button::Left => "left",
            Button::Middle => "middle",
            Button::Right => "right",
        }
    }

    pub fn parse(name: &str) -> Option<Self> {
        Some(match name {
            "left" => Button::Left,
            "middle" => Button::Middle,
            "right" => Button::Right,
            _ => return None,
        })
    }
}
