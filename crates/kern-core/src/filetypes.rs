//! Which language a file is in, by its name or extension. The editor starts
//! with the languages it has grammars for, and plugins add the rest.

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

#[derive(Debug, Clone, Default)]
pub struct FileTypes {
    extensions: HashMap<String, Arc<str>>,
    /// Whole file names, like "Makefile", which win over extensions.
    names: HashMap<String, Arc<str>>,
}

impl FileTypes {
    /// The extensions of the languages with bundled grammars.
    pub fn bundled() -> Self {
        let mut types = Self::default();
        for (extension, language) in crate::syntax::EXTENSIONS {
            types
                .extensions
                .insert((*extension).to_owned(), (*language).into());
        }
        types
    }

    /// Makes `extensions` and `names` mean `language`, replacing whatever
    /// the language had before.
    pub fn set(&mut self, language: &str, extensions: &[String], names: &[String]) {
        self.extensions.retain(|_, l| &**l != language);
        self.names.retain(|_, l| &**l != language);
        let language: Arc<str> = language.into();
        for extension in extensions {
            self.extensions.insert(extension.clone(), language.clone());
        }
        for name in names {
            self.names.insert(name.clone(), language.clone());
        }
    }

    pub fn detect(&self, path: &Path) -> Option<Arc<str>> {
        let by_name = path.file_name().and_then(|n| self.names.get(n.to_str()?));
        let by_extension = || {
            path.extension()
                .and_then(|e| self.extensions.get(e.to_str()?))
        };
        by_name.or_else(by_extension).cloned()
    }
}
