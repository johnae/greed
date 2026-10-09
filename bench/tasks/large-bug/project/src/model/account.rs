/// An account's name, like "assets:bank" or "expenses:food".
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Account(pub String);

impl Account {
    /// The part before the first ':', like "assets".
    pub fn top(&self) -> &str {
        self.0.split(':').next().unwrap_or(&self.0)
    }
}
