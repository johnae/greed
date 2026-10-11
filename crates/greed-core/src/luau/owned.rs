//! What plugins make that outlives the call making it, beyond what the
//! registry and the keymap keep: marks, tracked places, images, floating
//! views and panels, file types and language servers. Each is noted with
//! the plugin that made it, so it goes when that plugin is unloaded or
//! reloaded.

use std::collections::HashMap;
use std::sync::Arc;

use crate::image::ImageId;
use crate::lsp::{Lsp, ServerConfig};
use crate::registry::PluginId;
use crate::{BufferId, Editor, TrackId, ViewId};

/// A file type a plugin set: the language, its extensions and file names.
type FileType = (String, Vec<String>, Vec<String>);

#[derive(Default)]
pub(crate) struct Owned {
    /// The plugin that last set each buffer's marks in each namespace.
    marks: HashMap<(BufferId, Arc<str>), PluginId>,
    tracked: HashMap<(BufferId, TrackId), PluginId>,
    images: HashMap<ImageId, PluginId>,
    scenes: HashMap<crate::scene::SceneId, PluginId>,
    /// Floating views and panels.
    views: HashMap<ViewId, PluginId>,
    /// Oldest first, so what a plugin overrode comes back when it goes.
    file_types: Vec<(PluginId, FileType)>,
    /// Oldest first, as file types.
    servers: Vec<(PluginId, ServerConfig)>,
}

impl Owned {
    /// Notes that `by` set `buffer`'s marks in `ns`, or cleared them when
    /// `cleared`. The last plugin to set a namespace's marks owns them.
    pub fn marked(&mut self, buffer: BufferId, ns: &str, by: Option<PluginId>, cleared: bool) {
        let key = (buffer, Arc::from(ns));
        match by {
            Some(by) if !cleared => {
                self.marks.insert(key, by);
            }
            _ => {
                self.marks.remove(&key);
            }
        }
    }

    pub fn tracked(&mut self, buffer: BufferId, id: TrackId, by: PluginId) {
        self.tracked.insert((buffer, id), by);
    }

    pub fn forget_tracked(&mut self, buffer: BufferId, id: TrackId) {
        self.tracked.remove(&(buffer, id));
    }

    pub fn image(&mut self, id: ImageId, by: PluginId) {
        self.images.insert(id, by);
    }

    pub fn forget_image(&mut self, id: ImageId) {
        self.images.remove(&id);
    }

    pub fn scene(&mut self, id: crate::scene::SceneId, by: PluginId) {
        self.scenes.insert(id, by);
    }

    pub fn forget_scene(&mut self, id: crate::scene::SceneId) {
        self.scenes.remove(&id);
    }

    pub fn view(&mut self, id: ViewId, by: PluginId) {
        self.views.insert(id, by);
    }

    /// Notes that `copy` belongs to whoever `original` does, if anyone.
    pub fn copied_view(&mut self, original: ViewId, copy: ViewId) {
        if let Some(by) = self.views.get(&original).cloned() {
            self.views.insert(copy, by);
        }
    }

    pub fn file_type(
        &mut self,
        by: PluginId,
        language: &str,
        extensions: &[String],
        names: &[String],
    ) {
        self.file_types
            .retain(|(owner, (l, _, _))| !(*owner == by && l == language));
        self.file_types.push((
            by,
            (language.to_owned(), extensions.to_vec(), names.to_vec()),
        ));
    }

    pub fn server(&mut self, by: PluginId, config: ServerConfig) {
        self.servers
            .retain(|(owner, c)| !(*owner == by && c.language == config.language));
        self.servers.push((by, config));
    }

    /// Forgets the servers set for `language`, which was removed.
    pub fn remove_server(&mut self, language: &str) {
        self.servers.retain(|(_, c)| c.language != language);
    }

    /// Takes away what `owner` made: clears its marks, forgets its tracked
    /// places, images and scenes, closes its views, and puts back the file
    /// types and servers it replaced. Returns the views it closed.
    pub fn remove_owned_by(
        &mut self,
        owner: &str,
        editor: &mut Editor,
        lsp: &mut Lsp,
    ) -> Vec<ViewId> {
        let mine = |by: &PluginId| &**by == owner;
        let mut closed = Vec::new();
        self.marks.retain(|(buffer, ns), by| {
            if mine(by) {
                editor.decorate(*buffer, ns, Vec::new());
            }
            !mine(by) && editor.find_buffer(*buffer).is_some()
        });
        self.tracked.retain(|(buffer, id), by| {
            if mine(by) {
                editor.forget_tracked(*buffer, *id);
            }
            !mine(by) && editor.find_buffer(*buffer).is_some()
        });
        self.images.retain(|id, by| {
            if mine(by) {
                editor.images_mut().remove(*id);
            }
            !mine(by)
        });
        self.scenes.retain(|id, by| {
            if mine(by) {
                editor.scenes_mut().remove(*id);
            }
            !mine(by)
        });
        self.views.retain(|view, by| {
            if mine(by) && editor.close(*view) {
                closed.push(*view);
            }
            !mine(by) && editor.find_view(*view).is_some()
        });
        if self.file_types.iter().any(|(by, _)| mine(by)) {
            self.file_types.retain(|(by, _)| !mine(by));
            editor.reset_file_types(self.file_types.iter().map(|(_, (language, ext, names))| {
                (language.as_str(), ext.as_slice(), names.as_slice())
            }));
        }
        let languages: Vec<String> = self
            .servers
            .iter()
            .filter(|(by, _)| mine(by))
            .map(|(_, c)| c.language.clone())
            .collect();
        self.servers.retain(|(by, _)| !mine(by));
        for language in languages {
            match self.servers.iter().rfind(|(_, c)| c.language == language) {
                Some((_, config)) => lsp.configure(config.clone()),
                None => lsp.remove(&language),
            }
        }
        closed
    }
}
