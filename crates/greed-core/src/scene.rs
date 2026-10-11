//! Scenes: small vector drawings a plugin places over a block of cells, as
//! charts are. The server keeps each one by id, with a version that goes up
//! as it changes, and sends it to the clients that place it; each client
//! draws it as well as it can (an image in a terminal with kitty graphics,
//! vectors in a window). The cells under a scene hold it drawn in
//! characters by Luau, which a client that can't draw it shows instead.
//!
//! Coordinates are in cells, with fractions: (0, 0) is the top left of the
//! block it's placed over, y going down. Styles are theme names.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use serde::{Deserialize, Serialize};

#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize,
)]
pub struct SceneId(pub u64);

impl SceneId {
    /// A new id, unique in this process.
    pub fn next() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        SceneId(NEXT.fetch_add(1, Ordering::Relaxed))
    }
}

/// A point, x then y, in cells.
pub type Point = [f32; 2];

/// What a scene draws, and a line saying what it shows.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Spec {
    pub alt: String,
    #[serde(default)]
    pub items: Vec<Item>,
}

/// Something drawn, later ones over earlier ones. Kinds a client doesn't
/// know are left out, so new ones can come without breaking old clients.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Item {
    Line {
        #[serde(default)]
        points: Vec<Point>,
        #[serde(default)]
        style: Option<String>,
        #[serde(default)]
        weight: Option<f32>,
    },
    /// The area between the line through `points` and the y `base`.
    Area {
        #[serde(default)]
        points: Vec<Point>,
        #[serde(default)]
        base: Option<f32>,
        #[serde(default)]
        fill: Option<String>,
        #[serde(default)]
        opacity: Option<f32>,
    },
    /// A box, filled and or with its edge drawn.
    Rect {
        #[serde(default)]
        at: Point,
        #[serde(default)]
        size: Point,
        #[serde(default)]
        fill: Option<String>,
        #[serde(default)]
        style: Option<String>,
        #[serde(default)]
        opacity: Option<f32>,
    },
    Dots {
        #[serde(default)]
        points: Vec<Point>,
        #[serde(default)]
        style: Option<String>,
        #[serde(default)]
        weight: Option<f32>,
    },
    /// Text, which the cells show as text however the scene is drawn.
    Text {
        #[serde(default)]
        at: Point,
        #[serde(default)]
        text: String,
        #[serde(default)]
        style: Option<String>,
        #[serde(default)]
        align: Option<String>,
    },
    /// Items clipped to `clip`, x0 y0 x1 y1.
    Group {
        #[serde(default)]
        clip: Option<[f32; 4]>,
        #[serde(default)]
        items: Vec<Item>,
    },
    #[serde(other)]
    Unknown,
}

impl Item {
    /// The cells `text` is in, as the Luau cell drawing puts them: from
    /// column `floor(x + 0.5)` once moved by its `align`, on row `floor(y)`.
    pub fn text_cells(at: Point, text: &str, align: Option<&str>) -> (i32, i32, i32) {
        let width = text.chars().count();
        let width_f = f32::from(u16::try_from(width).unwrap_or(u16::MAX));
        let x = match align {
            Some("middle") => at[0] - width_f / 2.0,
            Some("end") => at[0] - width_f,
            _ => at[0],
        };
        #[allow(clippy::cast_possible_truncation)]
        let column = (x + 0.5).floor() as i32;
        #[allow(clippy::cast_possible_truncation)]
        let row = at[1].floor() as i32;
        (column, row, i32::try_from(width).unwrap_or(i32::MAX))
    }
}

/// A scene as it is now: its spec and which version that is.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Scene {
    pub id: SceneId,
    pub version: u64,
    pub spec: Spec,
}

/// The scenes the editor knows, by id.
#[derive(Debug, Default)]
pub struct Scenes {
    scenes: HashMap<SceneId, Arc<Scene>>,
}

impl Scenes {
    /// Keeps `spec` as a new scene, at version 1.
    pub fn insert(&mut self, spec: Spec) -> SceneId {
        let id = SceneId::next();
        self.scenes.insert(
            id,
            Arc::new(Scene {
                id,
                version: 1,
                spec,
            }),
        );
        id
    }

    /// Makes `spec` what scene `id` shows, a version on. False when there's
    /// no such scene.
    pub fn set(&mut self, id: SceneId, spec: Spec) -> bool {
        let Some(scene) = self.scenes.get_mut(&id) else {
            return false;
        };
        let version = scene.version + 1;
        *scene = Arc::new(Scene { id, version, spec });
        true
    }

    pub fn get(&self, id: SceneId) -> Option<&Arc<Scene>> {
        self.scenes.get(&id)
    }

    pub fn remove(&mut self, id: SceneId) {
        self.scenes.remove(&id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_spec_reads_known_kinds_and_leaves_others_out() {
        let spec: Spec = serde_json::from_value(serde_json::json!({
            "alt": "cpu",
            "items": [
                { "kind": "line", "points": [[0, 1], [2, 3]], "style": "chart.series.1" },
                { "kind": "rect", "at": [1, 1], "size": [2, 1], "fill": "x" },
                { "kind": "sparkle", "at": [0, 0] },
                { "kind": "group", "clip": [0, 0, 4, 4], "items": [{ "kind": "dots", "points": [[1, 1]] }] },
            ],
        }))
        .unwrap();
        assert_eq!(spec.items.len(), 4);
        assert!(matches!(spec.items[2], Item::Unknown));
        assert!(matches!(&spec.items[3], Item::Group { items, .. } if items.len() == 1));
    }

    #[test]
    fn setting_a_scene_moves_its_version_on() {
        let mut scenes = Scenes::default();
        let id = scenes.insert(Spec::default());
        assert_eq!(scenes.get(id).unwrap().version, 1);
        assert!(scenes.set(id, Spec::default()));
        assert_eq!(scenes.get(id).unwrap().version, 2);
        scenes.remove(id);
        assert!(!scenes.set(id, Spec::default()));
    }

    #[test]
    fn text_is_in_the_cells_the_luau_drawing_puts_it() {
        assert_eq!(Item::text_cells([5.0, 2.7], "ab", Some("end")), (3, 2, 2));
        assert_eq!(
            Item::text_cells([2.5, 0.0], "abc", Some("middle")),
            (1, 0, 3)
        );
        assert_eq!(Item::text_cells([1.0, 0.0], "ab", None), (1, 0, 2));
    }
}
